## データベース設計

### テーブル一覧

| テーブル | 説明 |
|---|---|
| `users` | ユーザー情報 |
| `sessions` | セッション管理 |
| `posts` | 投稿（リポスト・返信を含む。返信は `parent_post_id` で返信先を指す） |
| `follows` | フォロー関係 |
| `likes` | いいね |
| `reposts` | リポスト |
| `footprints` | プロフィール訪問履歴 |
| `notifications` | 通知（いいね・フォロー・リポスト・返信・足跡） |

### DDL

初期スキーマは [`../migrations/001_init.sql`](../migrations/001_init.sql) を参照。

以降の変更は連番のファイルで追加する。

| ファイル | 内容 |
|---|---|
| [`002_repost_unique.sql`](../migrations/002_repost_unique.sql) | `posts` に `(user_id, original_post_id)` の一意制約を追加し、リポストの重複行を防ぐ |
| [`003_notifications_index.sql`](../migrations/003_notifications_index.sql) | `notifications` に `(user_id, id)` の索引を追加 |
