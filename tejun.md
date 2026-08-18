# DBクエリ改善の効果測定手順

## 目的

`17-experiment`（改善前）と `16-performance`（改善後、共通祖先 `d2a50a4`）の間で
バックエンドの DB クエリ実装がどう変わり、その結果どのエンドポイントが
どの程度速くなったかを定量的に比較する。

## 改善内容のまとめ（コード差分から）

計測対象を選ぶ前提として、実際に何が変わったかを把握しておく。

| 種別 | 内容 | 対象ファイル |
|---|---|---|
| N+1解消 | `fetchUser` → `fetchUsersBatch`（IN句1本でフォロワー数/フォロー数/投稿数/フォロー中判定をまとめて取得） | `handler.go` |
| N+1解消 | `fetchPost` → `fetchPostsBatch`（著者・いいね数・リポスト数・返信数・自分の反応・返信先・リポスト元を1件ずつではなくバッチで取得） | `handler.go` |
| N+1解消 | `countReplies` の再帰クエリ（子孫を1階層ずつ都度クエリ）→ 再帰CTE 1本に集約 | `handler.go` |
| N+1解消 | スレッド取得（祖先チェーン・返信ツリー）を1件ずつ辿る実装 → 再帰CTEで一括取得してからバッチ取得 | `reply.go` |
| クエリ本数削減 | 一覧系（タイムライン・検索・ユーザー投稿）で「一覧取得」と「COUNT(*)」を別クエリにしていたのを `COUNT(*) OVER()` で1クエリに統合 | `post.go`, `search.go`, `notification.go`, `footprint.go` |
| 集計キャッシュ | `recommended` フィード（直近24時間いいね数順）はソートに集計が必須で重いため、上位500件のランキングを30秒 TTL でプロセス内キャッシュ | `handler.go` |
| インデックス追加 | `posts(parent_post_id, created_at, id)` など8本追加 | `migrations/002_add_indexes.sql` |
| コネクションプール | `MaxOpenConns` を `1` → `20` に変更（改善前は実質同時1接続でリクエストが直列化していた） | `db/db.go` |

上記から、**特にN+1が顕著だったエンドポイント**（投稿1件あたり付随クエリが多い・一覧系）が
改善効果を最も測りやすい。

## 計測対象エンドポイント

優先度順。上ほど改善前後の差が大きく出るはず。

| # | エンドポイント | 認証 | 改善前の問題 |
|---|---|---|---|
| 1 | `GET /posts?feed=following` | 要 | 一覧のN+1（`fetchPost`を件数分呼ぶ）＋ COUNT別クエリ |
| 2 | `GET /posts?feed=latest` | 要 | 同上 |
| 3 | `GET /posts?feed=recommended` | 要 | 同上 ＋ 重い集計クエリを毎回実行（キャッシュなし） |
| 4 | `GET /users/{user_id}/posts` | 不要 | 一覧のN+1 |
| 5 | `GET /posts/{id}/thread`（返信が多いスレッド） | 不要 | 祖先・返信ツリーを1件ずつ逐次クエリ、`countReplies`が再帰的に都度クエリ |
| 6 | `GET /search?type=posts` | 不要 | 一覧のN+1 ＋ COUNT別クエリ |
| 7 | `GET /notifications` | 要 | 通知ごとに投稿本文取得の逐次クエリ ＋ actor取得がN+1 |
| 8 | `GET /me/footprints` | 要 | 訪問者ごとに `fetchUser` のN+1 |
| 9 | `GET /trending` | 不要 | 投稿ごとの `fetchPost` N+1 |
| 10 | `GET /users/{user_id}/followers` / `/following` | 不要 | ユーザーごとの `fetchUser` N+1 |
| 11 | `GET /profile/{user_id}` | 不要 | `fetchUser` 単体（バッチ化の効果はほぼ無い。ベースライン比較用） |

`per_page` はドキュメント上の上限である `50` を指定して負荷を最大化する
（`?per_page=50`。51以上を指定すると仕様上20に丸められる点に注意）。

## 計測環境の準備

### 1. 両ブランチで同一条件のDBを用意する

改善前後でクエリ内容だけが変数になるよう、**シードデータの内容を完全に揃える**。

```bash
# 改善前（17-experiment）
git checkout 17-experiment
cd app/backend
docker compose down -v          # 前回のDBを消してクリーンな状態にする
docker compose up -d db
go run ./seed -scale 5          # scale値は好きに調整可（既定 scale=1 で users=500, posts=10000）
docker compose up -d api
```

計測が終わったら同じ手順で `16-performance` に切り替え、
**同じ `-scale` 値・同じシード（乱数シードが固定なら再現される。main.goのrand実装を確認し、
固定シードでなければシード生成後にDBダンプを取って両ブランチで使い回す）** で揃える。

> `app/backend/seed/main.go` の乱数生成が `rand.New(rand.NewSource(...))` で固定シードか、
> 時刻ベースかを確認すること。時刻ベースの場合は一度シードしたDBを
> `mysqldump` してファイルに保存し、両ブランチで同じダンプを読み込む方が確実。

```bash
# 固定シードでない場合の代替: シード済みDBをダンプして使い回す
docker compose exec db mysqldump -u sakuravel -ppassword sakuravel > seed_fixture.sql
# 別ブランチに切り替えた後
docker compose exec -T db mysql -u sakuravel -ppassword sakuravel < seed_fixture.sql
```

### 2. 認証が必要なエンドポイント用のセッションを用意する

シードで作られるユーザー（`user00334` 等）はパスワードが共有されていない＝ログインできないため、
**計測用アカウントを `/register` で別途新規作成する**。

```bash
curl -i -c cookies.txt -X POST http://localhost:8080/register \
  -H 'Content-Type: application/json' \
  -d '{"username":"bench_user","display_name":"bench","email":"bench@example.com","password":"benchpass123"}'
```

登録と同時に `session_id` が発行され `cookies.txt` に保存されるので、以降の認証必須エンドポイントは
`curl -b cookies.txt ...` で叩ける。

`GET /posts?feed=following` はフォロー中ユーザーの投稿を返す仕様なので、新規登録直後はフォロー0件＝
常に空レスポンスになり負荷計測にならない。計測前に既存ユーザーを何人かフォローしておく。

```bash
for uid in 1 2 3 4 5 6 7 8 9 10; do
  curl -s -b cookies.txt -X POST "http://localhost:8080/users/$uid/follow" -o /dev/null
done
```

（`following` フィードで十分な件数のタイムラインを再現したい場合は、フォロー数をもっと増やす。
seedは `numUsers = 500 * scale` 人作るので、id 1〜N を範囲でフォローすればよい。）

### 3. `recommended` フィード計測時の注意

改善後はランキングを30秒キャッシュする。フェアな比較にするため、

- **初回リクエスト（キャッシュミス）** と **2回目以降（キャッシュヒット）** を分けて計測する
- 改善前と比較する場合は「初回」同士・「定常状態」同士で比較する（初回は改善後でも重い集計が走るため、改善前と大差ない可能性がある。ここでの主な効果は**同時アクセス時の実行回数削減**であり、単発レイテンシではなくスループット/DB負荷で見るべき）

### 4. `trending` / `recommended` はシード直後のみ有効

`likes.created_at` がシード実行時刻で入るため、`trending`（直近1時間）は1時間、
`recommended`（直近24時間）は24時間で対象データが空になり、実質的に時系列順へ退化する。
**シード投入後、なるべく早いタイミングで計測すること。**

## 計測方法

追加ツールのインストールが要らないよう、`curl` だけで完結させる。
1エンドポイントにつき、性質の異なる **3つの指標** を測る。1回だけ叩いて終わりではない。

| # | 指標 | 何がわかるか | 使うスクリプト |
|---|---|---|---|
| 1 | レイテンシ分布（avg / p50 / p95 / p99） | 1リクエストあたりの応答速度そのものの改善 | `bench.sh`（直列でN回実行） |
| 2 | スループット（RPS） | 同時アクセス時の捌ける量。特にコネクションプール拡大（`MaxOpenConns` 1→20）の効果はここに出る | `bench_concurrent.sh`（並列でN回実行） |
| 3 | 1リクエストあたりのDBクエリ本数 | なぜ速くなったか（N+1解消）の直接的な裏付け | general query log |

以下、1→2→3の順に測り方を示す。すべて `curl` の `-w` オプションで
レスポンスタイム（`%{time_total}`、秒）を取り出すのが基本になる。

```bash
# 動作確認用に1回だけ叩いてみる例（本計測ではない）
curl -s -o /dev/null -w '%{http_code} %{time_total}\n' \
  "http://localhost:8080/users/1/posts?per_page=50"
```

### 1. レイテンシ分布：N回連続実行してp50/p95を出すスクリプト（直列＝ `-c 1` 相当）

```bash
#!/usr/bin/env bash
# bench.sh <URL> [追加のcurlオプション...]
url="$1"; shift
n=100
for i in $(seq 1 "$n"); do
  curl -s -o /dev/null -w '%{time_total}\n' "$url" "$@"
done | sort -n | awk -v n="$n" '
  { a[NR]=$1; sum+=$1 }
  END {
    printf "count=%d avg=%.4f p50=%.4f p95=%.4f p99=%.4f max=%.4f\n",
      n, sum/n, a[int(n*0.50)+1], a[int(n*0.95)+1], a[int(n*0.99)+1], a[n]
  }'
```

```bash
chmod +x bench.sh
./bench.sh "http://localhost:8080/users/1/posts?per_page=50"
./bench.sh "http://localhost:8080/posts?feed=following&per_page=50" -b cookies.txt
```

### 2. スループット：同時実行（`-c 10` 相当）をcurlの並列起動で再現する

`xargs -P` でcurlを並列に起動し、全体の所要時間からRPSを逆算する。

```bash
#!/usr/bin/env bash
# bench_concurrent.sh <URL> [追加のcurlオプション...]
url="$1"; shift
n=200      # 総リクエスト数
c=10       # 同時実行数
start=$(date +%s.%N)
seq 1 "$n" | xargs -P "$c" -I{} \
  curl -s -o /dev/null -w '%{http_code} %{time_total}\n' "$url" "$@" \
  > /tmp/bench_results.txt
end=$(date +%s.%N)
total=$(echo "$end - $start" | bc)
awk -v total="$total" -v n="$n" '
  { split($0,a," "); t[NR]=a[2]; sum+=a[2] }
  END {
    asorta_n=asort(t)
    printf "n=%d total=%.2fs rps=%.2f avg=%.4f p50=%.4f p95=%.4f\n",
      n, total, n/total, sum/n, t[int(n*0.50)+1], t[int(n*0.95)+1]
  }' /tmp/bench_results.txt
```

（`asort` が無い環境では `sort -n /tmp/bench_results.txt` してから `awk` に渡す2段構成にする。
GNU awk が無ければ Python3 の1行スクリプトで代用してもよい。）

```bash
chmod +x bench_concurrent.sh
./bench_concurrent.sh "http://localhost:8080/posts?feed=following&per_page=50" -b cookies.txt
```

- `n`: 総リクエスト数（目安200〜500。DBが小さいVM環境なので過大な同時実行はDB側がボトルネックになりすぎて比較にならない点に注意）
- `c`: 同時実行数（改善前は `MaxOpenConns=1` のため `c` を上げても改善前はほぼ直列化する。この差自体も測定対象なので `c=1`（`bench.sh`）と `c=10`（`bench_concurrent.sh`）の両方を計測し比較する）

全11エンドポイントに対して `bench.sh`（直列）と `bench_concurrent.sh`（並列10）の
2パターンを両ブランチで実行し、以下を記録する。

| 記録する指標 | 取得元 |
|---|---|
| avg / p50 / p95 レイテンシ | 各スクリプトの出力 |
| RPS（1秒あたり処理数） | `bench_concurrent.sh` の `rps` |
| HTTPステータス異常の有無 | `%{http_code}` が200系以外の行がないか目視確認 |

### 3. DBの実行クエリ本数を確認する（N+1解消の直接的な裏付け）

指標1・2の前後比較だけでは「なぜ速くなったか」の説明にならないため、
1リクエストあたりの発行クエリ数を general query log から数える。

```bash
docker compose exec db mysql -u root -ppassword -e \
  "SET GLOBAL general_log = 'ON'; SET GLOBAL log_output = 'TABLE';"

# 対象エンドポイントに単発リクエストを1回投げる
curl -s "http://localhost:8080/users/1/posts?per_page=50" -o /dev/null

docker compose exec db mysql -u root -ppassword -e \
  "SELECT COUNT(*) FROM mysql.general_log WHERE command_type='Query' AND event_time > NOW() - INTERVAL 10 SECOND;"

docker compose exec db mysql -u root -ppassword -e \
  "SET GLOBAL general_log = 'OFF';"
```

`per_page=50` の一覧系エンドポイントであれば、改善前は「50件 × 付随クエリ数(概ね5〜9本)」＝
数百クエリ、改善後は定数本（10〜15本程度）になるはずなので、この本数の差が最も分かりやすい定量指標になる。

## 結果のまとめ方

各エンドポイントについて以下の表を埋め、Before/Afterを並べる。

| エンドポイント | 条件 | クエリ本数(before→after) | p50(before→after) | p95(before→after) | RPS(before→after) |
|---|---|---|---|---|---|
| GET /posts?feed=following | per_page=50, bench.sh (c=1) | | | | |
| GET /posts?feed=following | per_page=50, bench_concurrent.sh (c=10) | | | | |
| ... | | | | | |

`recommended` フィードのみ「初回（キャッシュミス）」「定常状態（キャッシュヒット）」を分けて別行にする。

## 実施手順まとめ（チェックリスト）

1. `17-experiment` で `docker compose down -v` → シード投入（`-scale` を記録） → シードDBをダンプ
2. `/register` で計測用アカウントを新規作成し、既存ユーザーをフォローしてセッションCookieを取得
3. 上記11エンドポイントに対し `bench.sh`（直列）と `bench_concurrent.sh`（並列10）を実行し記録
4. general query log でクエリ本数を1リクエストずつ計測（軽い一覧系エンドポイントのみでよい）
5. `16-performance` に切り替え、ダンプしたDB（シード分のみ。計測用アカウントは含まれない）を復元
6. 手順2〜4を再実行（同じユーザー名・同じフォロー対象idで登録し直し、条件を完全一致させる）
7. Before/Afterを表にまとめる
