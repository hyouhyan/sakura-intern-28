# 28卒エンジニアインターン用インフラ

- [初回デプロイ手順](FIRST_DEPLOY.md)
- [コンテナイメージ更新・再デプロイ手順](IMAGE_UPDATE.md)

構築や更新の際は、上記の該当手順書に従ってください。クレデンシャルは
1Passwordに保管されています。

zoneとcluster名は `terraform/environment.auto.tfvars` に保存します。このファイルは
git管理外です。新しい環境では `environment.auto.tfvars.example` をコピーしてください。

## 構成

```
Browser ──https──> AppRun LB :443 ──http──> frontend コンテナ :3000
         (Host: frontend_host)

Browser ──https──> AppRun LB :443 ──http──> backend コンテナ :8080 ──> MariaDB :3306
         (Host: backend_host)                                          (プライベート網)
```

TLS 終端は **AppRun 専有型ロードバランサ**が行います（`use_lets_encrypt`）。
nginx などのリバースプロキシは挟んでいません。
LB は Host ヘッダで L7 ルーティングするため、FQDN さえ分けておけば
frontend と backend で同じ 443 ポートを共有できます。

frontend と backend をあえて別 FQDN にしているのは、アプリが
「別オリジン + CORS + Cookie」の前提で書かれているためです
（`app/backend/internal/handler/handler.go` の `CookieSecure` を参照）。
`enable_tls = true` のとき、backend には自動的に
`COOKIE_SECURE=true`（`Secure` + `SameSite=None`）と
`ALLOWED_ORIGIN=https://<frontend_host>` が入ります。

## 構成上の前提

LB のポートは**クラスタ作成時にしか設定できず、後から追加できません**。
`cluster.tf` の `ports` に `80/http` と `443/https` の両方が必要です
（80 番は Let's Encrypt の HTTP-01 チャレンジ用。アプリ側の
`exposed_ports` に 80 番のエントリを足す必要はありません）。

各version resourceは `create_before_destroy` で新versionを先に作成します。作成後の
provisionerが新versionをAppRun APIからactiveに切り替え、旧versionの
`activeNodeCount` が0になるまで待ってから、Terraformが旧versionを削除します。

## versionだけを手動で有効化する

Terraform で作成済みの version のうち、最大の version 番号を AppRun 専有型 API で有効化できます。
API キーには AppRun の操作権限を付与してください。

```sh
cd infra/terraform
./activate-latest-version.sh "<application-id>"
```

`<application-id>` は AppRun 専有型のアプリケーション ID（UUID）です。接続先を差し替える場合は
`APPRUN_DEDICATED_API_URL`、一覧のページサイズを変える場合は `APPRUN_VERSION_PAGE_SIZE` を設定します。
