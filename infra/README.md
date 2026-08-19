# 28卒エンジニアインターン用インフラ

構築前に tfvars をコピーして編集します：

```
cp secret.auto.tfvars.example secret.auto.tfvars
cp tls.auto.tfvars.example tls.auto.tfvars
```

クレデンシャルなどは1Passwordに入ってます。

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

## TLS を有効にする手順

1. `tls.auto.tfvars` に FQDN を 2 つ書く（`frontend_host` / `backend_host`）。
2. LB の VIP を確認する。

   ```
   terraform output -raw lb_vip
   ```

3. **DNS の A レコードを手動で 2 本登録する**。どちらも VIP を指します。

   ```
   terraform output dns_records
   ```

   CDN のプロキシは経由させないこと。Let's Encrypt の HTTP-01 チャレンジが
   80 番に到達できず、証明書を取得できません。

4. apply する（バージョンの有効化を含むので `redeploy.sh` を使う）。

   ```
   ./redeploy.sh
   ```

5. 証明書の発行に数分かかります。反映を確認する。

   ```
   ./check-lb.sh
   ```

`enable_tls = false` にすると LB から切り離され（`lb_port = null`）、
ワーカーノードのグローバル IP に平文 HTTP で直接ぶら下がる形に戻ります。

### 前提（変更できないもの）

LB のポートは**クラスタ作成時にしか設定できず、後から追加できません**。
`cluster.tf` の `ports` に `80/http` と `443/https` の両方が必要です
（80 番は Let's Encrypt の HTTP-01 チャレンジ用。アプリ側の
`exposed_ports` に 80 番のエントリを足す必要はありません）。

## デプロイ（バージョンの作り直し）

AppRun の version は不変リソースで、アクティブなものは削除できません。
イメージや環境変数を変えたときは 3 段階の apply が必要になるため、
`./redeploy.sh` を使ってください（無効化 → 再作成 → 有効化を自動でやります）。

素の `terraform apply` で済むのは、version の中身を変えないときだけです。

## AppRun 専有型の最新 version を有効化する

Terraform で作成済みの version のうち、最大の version 番号を AppRun 専有型 API で有効化できます。
API キーには AppRun の操作権限を付与してください。

```sh
cd infra/terraform
SAKURA_ACCESS_TOKEN="..." \
SAKURA_ACCESS_TOKEN_SECRET="..." \
./activate-latest-version.sh "<application-id>"
```

`<application-id>` は AppRun 専有型のアプリケーション ID（UUID）です。接続先を差し替える場合は
`APPRUN_DEDICATED_API_URL`、一覧のページサイズを変える場合は `APPRUN_VERSION_PAGE_SIZE` を設定します。
