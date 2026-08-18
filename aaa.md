# 変更履歴

パフォーマンスチューニング課題に対する変更内容を記録する。
新しい変更は本ファイルの末尾に追記していく。

---

## 2026-08-17: N+1クエリの解消・recommendedフィードの高速化・COUNT(*)重複の削減

### 背景

SRE視点でのコードレビュー（`/posts` API が10万ダミーデータで約35秒かかり可用性を喪失する問題の調査）で洗い出した項目のうち、以下3点をアプリケーションコードの変更のみ（DBインデックス追加・接続プール設定変更なし）で対応した。

- N+1クエリ（`fetchPost` / `fetchUser` を1件ずつループでDB問い合わせ）
- `recommended` フィードの集計クエリが極端に遅い
- 一覧系エンドポイントでページングのたびに毎回 `COUNT(*)` を実行している

対象外（別途対応予定）:
- DBコネクションプールが `SetMaxOpenConns(1)` に固定されている問題
- マイグレーションにインデックスが一切ない問題
- インフラ（Terraformのサーバー/DBスペック、冗長化・監視）

### 変更1: N+1クエリの解消（`internal/handler/handler.go` ほか）

**問題点**: `fetchPost` / `fetchUser` は1件取得するたびに8〜9クエリ（著者情報4クエリ・いいね数・リポスト数・返信数・自分の反応の有無など）を発行していた。一覧系エンドポイント（`GET /posts` 等）はこれをページ内の件数分（最大50件）ループで呼び出すため、1リクエストで数百〜1000クエリ規模になっていた。

**対応**:
- `fetchUsersByIDs(ids []int64)` / `fetchPostsByIDs(ids []int64)` を新設。複数IDを `WHERE id IN (...)` でまとめて取得し、フォロワー数・いいね数などの集計も `GROUP BY` で一括取得することで、**取得件数によらず一定本数のクエリ**で済むようにした。
- 既存の単体取得関数 `fetchPost` / `fetchUser` は、上記バッチ関数を要素数1で呼び出す薄いラッパーに変更（内部実装を一本化し、単体取得・一覧取得のどちらでも同じロジックを使う）。
- 返信数のカウント（`countReplies`）は、投稿ごとに再帰的にDBへ問い合わせる実装だったが、`countRepliesBatch` として **スレッドの深さ1段につき1クエリ**（対象投稿の件数によらない）でまとめて計算するように変更。深さ方向にBFSで辿りながら、どの祖先に属する返信かを追跡して集計する。
- `GET /posts/{id}/thread` のスレッド取得（祖先チェーン・返信ツリー）も同様に、まず id と親子関係だけを安いクエリで辿り、最後に対象ノード全件をバッチ取得する方式に変更。
- 上記のバッチ化を、次の一覧系エンドポイントすべてに適用: `GetTimeline`、`GetUserPosts`、`searchPosts`/`searchUsers`、`GetTrending`、`GetNotifications`（通知の相手ユーザー・対象投稿の抜粋）、`GetFootprints`、`GetFollowers`/`GetFollowing`、`GetLikes`、`GetThread`。

**効果**: 1ページ50件のタイムライン取得が「50件 × 8〜9クエリ」から「一定本数（10クエリ前後）」に削減された。

### 変更2: `recommended` フィードの高速化（`internal/handler/handler.go`）

**問題点**: 元のクエリは `posts LEFT JOIN likes ... GROUP BY p.id ORDER BY COUNT(...) DESC` という形で、全投稿×直近24時間のいいねを結合してから並び替えていた。`likes.post_id` を絞り込めるインデックスが無いため、MariaDB が Block Nested Loop（総当たり結合）を選択し、`EXPLAIN` で確認したところ投稿1万件・いいね10万件程度のデータでも **約37秒** かかっていた（実測）。

**対応**:
1. **結合方向の変更**: `likes` を起点にして `JOIN posts ON posts.id = likes.post_id` とすることで、`posts.id` の既存 `PRIMARY KEY` を使った `eq_ref` 結合になり、新規インデックスを追加せずに Block Nested Loop を回避した。`EXPLAIN` で結合方式が `ALL × ALL(BNL)` から `ALL × eq_ref(PRIMARY)` に変わったことを確認し、同条件で **約37秒 → 約0.15〜0.2秒** に短縮した。
2. **上位ランキングのキャッシュ**: `recommended` は「ORDER BY COUNT(...) DESC」という集計ソートの性質上、インデックスだけでは根本解決できない（母集団を集計しないと順位が決まらない）。そのため、算出した上位500件のランキングを **30秒間だけプロセス内メモリにキャッシュ**し、TTL内の全リクエストで使い回すようにした（`sync.Mutex` で保護し、キャッシュ切れ時の再計算が同時に何度も走らないようにしている）。
3. いいねが少なく上位500件に満たない場合は、残り枠を最新投稿（`created_at DESC`）で埋め、元の `LEFT JOIN` 版と同じ「常にページが埋まる」挙動を維持した。

**既知の制約**:
- キャッシュは上位500件（`per_page` 最大50件 × 10ページ分）のみ保持する。それより深いページを要求された場合は空配列を返す（`total` は正しい総投稿数のまま）。実運用でこれ以上深いページングが必要な場合は `recommendedCacheSize` の見直しが必要。
- 30秒間はランキングが更新されない。リアルタイム性より安定性を優先したトレードオフ。
- 「①結合方向の変更」は既存の `posts.id` PRIMARY KEY を使っているため新規インデックス無しで効果が出ているが、`likes.created_at` にインデックスが無いため `likes` 側のフルスキャンは残っている。データ量がさらに増えた場合はここがボトルネックになり得る（インデックス追加は別対応）。

### 変更3: ページングのたびに毎回 `COUNT(*)` していた問題の解消

**問題点**: `GetTimeline`、`GetUserPosts`、`searchPosts`/`searchUsers`、`GetNotifications`、`GetFootprints` は、一覧取得クエリとは別に、ページングの `total` 表示のためだけに `SELECT COUNT(*) ...` を毎回追加で実行していた（＝同じ条件を2回スキャンしていた）。

**対応**:
- 一覧取得クエリに `COUNT(*) OVER()`（ウィンドウ関数）を含め、**一覧データと総件数を1回のクエリで同時に取得**するように変更（`queryIDsWithTotal` ヘルパーを新設し、`GetTimeline`／`GetUserPosts`／`searchPosts`／`searchUsers` で共通利用）。`GetNotifications`／`GetFootprints` も同様にウィンドウ関数を使う形に変更。
- ウィンドウ関数は「返ってきた行に対して」総件数を付与する性質上、`OFFSET` がページ末尾を超えて0件になるケース（存在しないページを指定した場合）だけ総件数が取得できない。この場合のみフォールバックとして従来通りの `COUNT(*)` を実行する（`page=1000` のような境界値でも `total` が正しく返ることを確認済み）。
- `GetNotifications` の `unread_count`（未読バッジ用、`total` とは別の値）はそのまま個別クエリとして残した。ページングとは独立した値であり、重複クエリではないため対象外。

### 検証

- `go build ./...` / `go vet ./...` / `gofmt -l .` がすべてクリーンであることを確認。
- Docker Compose環境で `seed/main.go`（デフォルトスケール: users 500 / posts 10,000 / likes 100,000 など）を投入し、全エンドポイントを実際に呼び出して動作確認:
  - `GET /posts?feed=latest|following|recommended`: いずれも約30〜150msで応答（`recommended`初回のみ約140ms、キャッシュヒット時は約30ms。変更前は約37秒）。
  - `GET /users/{id}/posts`、`GET /search`、`GET /trending`、`GET /notifications`、`GET /me/footprints`、`GET /users/{id}/followers|following`、`GET /posts/{id}/likes`、`GET /posts/{id}/thread` を実行し、いずれも正常応答・妥当なレスポンス内容であることを確認。
  - リポスト（`original_post` のネスト解決）・返信（`reply_to_username` 解決・スレッドの祖先チェーン・ネストした返信数のカウント）が、バッチ化後も元の挙動と同じ結果になることを確認。
  - 存在しないページ（`page=1000` など）を指定した際に `total` が正しくフォールバック計算されることを確認。
  - 30並列リクエストを `GET /posts?feed=latest` に投げても約2秒で全件完了することを確認（DB接続プールが1本のままのため完全な並列処理にはならないが、1リクエストあたりの処理が軽くなったことでキュー詰まりが大幅に緩和されている）。

### 変更ファイル

- `app/backend/internal/handler/handler.go`（バッチ取得ヘルパー・recommendedキャッシュを新設）
- `app/backend/internal/handler/post.go`
- `app/backend/internal/handler/search.go`
- `app/backend/internal/handler/trending.go`
- `app/backend/internal/handler/notification.go`
- `app/backend/internal/handler/footprint.go`
- `app/backend/internal/handler/user.go`
- `app/backend/internal/handler/like.go`
- `app/backend/internal/handler/reply.go`

### 今後の課題（今回のスコープ外）

- DBコネクションプール `SetMaxOpenConns(1)` の撤廃。今回の変更で1リクエストあたりの処理は大幅に軽くなったが、根本的な並列度の制約は残っている。
- インデックスの追加（`posts(parent_post_id, created_at)`、`likes.created_at` など）。`recommended` フィードや `latest`/`following`/`search` のソート・絞り込みは、依然としてフルスキャンに依存している箇所が残る。
- インフラ（アプリサーバー1コア/1GB、DBの冗長化なし等）のサイジング見直し。

---

## 2026-08-18: DBコネクションプールの拡張・インデックス追加

前回の対応（N+1解消・recommendedフィード高速化・COUNT(*)重複削減）のスコープ外としていた項目1・2に対応した。

### 変更1: DBコネクションプールの拡張（`internal/db/db.go`）

**問題点**: `db.SetMaxOpenConns(1)` により、DBへの同時接続が1本に固定されていた。1リクエストあたりの処理は前回の対応で大幅に軽くなったものの、全リクエストが1本の接続を奪い合って直列化される構造そのものは残っており、同時アクセスが増えるとキューが詰まって可用性を失うリスクがあった。

**対応**:
- `SetMaxOpenConns` / `SetMaxIdleConns` を `1` → `20` に変更した。
  - MariaDB のデフォルト `max_connections`（実機で151であることを確認済み）に対して十分小さく、かつ現行のVMスペック（1コア/1GBメモリ、DBもAPIも同居）でも無理のない値として20を選定した。VM・DBのスペックを見直すタイミングで併せて再チューニングする想定。
- `SetConnMaxLifetime` を `0`（無期限）→ `5分` に変更した。接続を定期的に張り直すことで、長時間張りっぱなしの古い接続が残り続けるのを防ぐ（一般的なベストプラクティスに合わせた）。

**効果（実測）**: `GET /posts?feed=latest` に対して50並列リクエストを投げた場合の全体所要時間が、変更前（`SetMaxOpenConns(1)`、前回対応時点のコード）の**30並列で約2秒**から、変更後は**50並列で約0.19秒**に短縮した（1リクエストあたりの処理時間自体は前回対応で既に軽量化済みのため、この差は「直列化が解消され真に並列処理されるようになった」効果によるもの）。

### 変更2: インデックスの追加（`migrations/002_add_indexes.sql`）

**問題点**: `001_init.sql` は各テーブルの `PRIMARY KEY` 以外のインデックスを一切定義していなかった。前回の対応（N+1解消・クエリのバッチ化）でクエリの発行回数自体は大幅に削減したが、個々のクエリが依然としてフルテーブルスキャンに依存している箇所が多数残っていた。

**対応**: 以下のインデックスを追加する新規マイグレーション `002_add_indexes.sql` を作成した。

| テーブル | インデックス | 主な用途 |
|---|---|---|
| `posts` | `(parent_post_id, created_at, id)` | タイムライン（`latest`/`recommended`の穴埋め）、返信ツリー・返信数カウント（`parent_post_id IN (...)`） |
| `posts` | `(user_id, parent_post_id, created_at, id)` | ユーザーの投稿一覧、ユーザーごとの投稿数集計 |
| `likes` | `(post_id)` | 投稿ごとのいいね数集計、いいねしたユーザー一覧 |
| `likes` | `(created_at)` | `recommended`/`trending` フィードの「直近N時間」絞り込み |
| `reposts` | `(post_id)` | 投稿ごとのリポスト数集計 |
| `follows` | `(followee_id)` | フォロワー数集計・フォロワー一覧（`follower_id` 起点は複合PRIMARY KEYで足りるため対象外） |
| `notifications` | `(user_id, created_at, id)` | ユーザーごとの通知一覧・件数取得 |
| `footprints` | `(user_id)` | ユーザーごとの足跡一覧取得 |

**既存環境への適用について**: `docker-entrypoint-initdb.d` によるマイグレーション実行は **DBボリュームの初回作成時のみ**行われる（`README.md` にも明記の通り）。そのため、既にダミーデータを投入済みの環境では `002_add_indexes.sql` は自動実行されない。検証時は実行中の開発用DBに対して手動で（`docker exec -i <dbコンテナ> mysql -u ... < migrations/002_add_indexes.sql`）適用して確認した。本番適用時も同様に、既存DBに対しては手動（またはマイグレーションツール導入後はそれ経由）での適用が必要になる。

**対象外にした項目**: `posts.content` に対する `LIKE '%q%'` 検索（`GET /search`）は、前方一致でないワイルドカード検索のためB-treeインデックスを追加しても効果がない。高速化するには `FULLTEXT` インデックス＋クエリ側の `MATCH ... AGAINST` への書き換えが必要で、検索のマッチング挙動・スコアリングが変わる（純粋なインデックス追加では済まない）ため、今回は対象外とした。

### 検証

- `go build ./...` / `go vet ./...` / `gofmt -l .` がすべてクリーンであることを確認。
- `EXPLAIN` で主要クエリの実行計画がフルスキャン（`type: ALL`）からインデックスを使った `ref` アクセスに変わったことを確認:
  - タイムライン（`latest`）: `ALL` → `idx_posts_parent_created` を使った `ref`
  - ユーザー投稿一覧: `ALL` → `idx_posts_user_parent_created` を使った `ref`
  - 返信ツリー・返信数カウント（`parent_post_id IN (...)`）: `ALL` → `idx_posts_parent_created` を使った `ref`
  - `recommended` フィード: 両テーブルとも `ref` アクセス（インデックスなしの状態では `likes` 側が `ALL`＝全件スキャンだった）
- 実測レスポンスタイムの改善（同一の開発用DB、投稿1万件・いいね10万件程度のデータで比較）:
  - `GET /posts?feed=latest`: 約35ms → 約12ms
  - `GET /posts?feed=following`: 約43ms → 約10ms
  - `GET /posts?feed=recommended`（キャッシュ切れ時の再計算）: 約140ms → 約120ms（結合方式自体は前回対応で改善済みのため、今回のインデックス追加による伸びしろは小さい。データ量がさらに増えた場合に効果が顕在化する）
- 全エンドポイント（タイムライン3種・検索・トレンド・通知・足跡・フォロワー一覧・スレッド取得・投稿作成・いいね等）を実際に呼び出し、インデックス追加前と同じレスポンス内容が返ることを確認（機能的な回帰なし）。

### 変更ファイル

- `app/backend/internal/db/db.go`
- `app/backend/migrations/002_add_indexes.sql`（新規）

### 今後の課題（今回のスコープ外）

- `posts.content` の全文検索対応（`FULLTEXT` インデックス化 + クエリ書き換え）。
- DBコネクションプールの値（20）は現行の小さいVMスペックを前提にした暫定値。インフラのサイジング見直し（`teian.md` 参照）に合わせて再チューニングが必要。
- マイグレーションの自動適用の仕組み（現状は `docker-entrypoint-initdb.d` によるボリューム初回作成時のみの実行に依存しており、稼働中DBへの追加マイグレーション適用は手動）。CI/CD整備時にマイグレーションツール（`golang-migrate` 等）の導入も合わせて検討する。
