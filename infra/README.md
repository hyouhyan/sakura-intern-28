# 28卒エンジニアインターン用インフラ

構築前に tfvars をコピーして編集します：

```
cp secret.auto.tfvars.example secret.auto.tfvars
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

## 初回構築手順

以下はすべてリポジトリルートで実行します。最初に `.env` を作成し、
APIトークンを設定します。

```sh
cp .env.example .env
```

```dotenv
SAKURA_ACCESS_TOKEN="..."
SAKURA_ACCESS_TOKEN_SECRET="..."
ENABLE_TLS=false
```

`terraform_apply.sh` と `deploy.sh` はリポジトリルートの `.env` を自動で読み、
APIトークンをTerraformの入力変数へ変換します。
公開ドメインは `secret.auto.tfvars` の `frontend_host` と `backend_host` に設定します。
TLSの有効・無効だけは、各デプロイ時に `ENABLE_TLS` で指定します。

既存の `secret.auto.tfvars` に `sakura_access_token`、
`sakura_access_token_secret`、`enable_tls` がある場合は削除してください。
`.auto.tfvars` の値は環境変数より優先されるためです。

### 1. コンテナレジストリを作成（初回のみ）

```sh
./terraform_apply.sh \
  -target=sakura_container_registry.intern \
  -auto-approve
```

作成されたレジストリのホスト名と、デプロイに使うGit SHAを取得します。

```sh
export REGISTRY_HOST="$(terraform -chdir=infra/terraform output -raw registry_fqdn)"
export IMAGE_TAG="$(git rev-parse HEAD)"
```

### 2. Docker imageをpush（初回およびアプリ更新時）

作成したレジストリへ、`secret.auto.tfvars` のciユーザー情報でログインします。

```sh
docker login "${REGISTRY_HOST}" --username ci
```

backendをAppRun用の `linux/amd64` imageとしてbuild・pushします。

```sh
docker buildx build \
  --platform linux/amd64 \
  --tag "${REGISTRY_HOST}/intern2026-app-backend:${IMAGE_TAG}" \
  --push \
  ./app/backend
```

配布済みfrontend imageを自分のレジストリへpushします。

```sh
docker login intern22.sakuracr.jp
docker pull --platform linux/amd64 \
  intern22.sakuracr.jp/intern2026-app-frontend:latest
docker tag \
  intern22.sakuracr.jp/intern2026-app-frontend:latest \
  "${REGISTRY_HOST}/intern2026-app-frontend:${IMAGE_TAG}"
docker push "${REGISTRY_HOST}/intern2026-app-frontend:${IMAGE_TAG}"
```

### 3. TLSなしでTerraform初回デプロイ

```sh
ENABLE_TLS=false ./deploy.sh -auto-approve
```

`deploy.sh` は現在のGit SHAと同じタグのimageを参照します。手順2と3の間に
commitを切り替えた場合は、`IMAGE_TAG` を合わせてから再度pushしてください。

### 4. DNSを設定

LBのVIPを確認します。

```sh
terraform -chdir=infra/terraform output -raw lb_vip
```

`secret.auto.tfvars` の `frontend_host` と `backend_host` のDNS Aレコードを、
どちらも表示されたVIPへ向けます。CDNのプロキシは経由させないでください。Let's EncryptのHTTP-01
チャレンジが80番へ到達できなくなります。

名前解決を確認します。

```sh
dig +short app.example.com A
dig +short api.example.com A
```

### 5. TLSを有効化して再デプロイ

```sh
ENABLE_TLS=true ./deploy.sh -auto-approve
```

証明書の発行には数分かかる場合があります。発行後に接続を確認します。

```sh
./infra/terraform/check-lb.sh
```

`enable_tls = false` にすると LB から切り離され（`lb_port = null`）、
ワーカーノードのグローバル IP に平文 HTTP で直接ぶら下がる形に戻ります。

### 前提（変更できないもの）

LB のポートは**クラスタ作成時にしか設定できず、後から追加できません**。
`cluster.tf` の `ports` に `80/http` と `443/https` の両方が必要です
（80 番は Let's Encrypt の HTTP-01 チャレンジ用。アプリ側の
`exposed_ports` に 80 番のエントリを足す必要はありません）。

## デプロイ（バージョンの作り直し）

リポジトリルートから次の1コマンドで実行します。

```sh
ENABLE_TLS=true \
./deploy.sh
```

`deploy.sh` はTerraformで新しいversionを作成し、applyが成功した後にbackend、
frontendの順で最新versionをAppRun APIから有効化します。稼働中versionは事前に
無効化せず、実コンテナの切り替えはAppRunのversion切り替え機構に委ねます。

Terraformへオプションを渡す場合は、そのまま末尾に指定できます。

```sh
ENABLE_TLS=true \
./deploy.sh -auto-approve
```

## versionだけを手動で有効化する

Terraform で作成済みの version のうち、最大の version 番号を AppRun 専有型 API で有効化できます。
API キーには AppRun の操作権限を付与してください。

```sh
cd infra/terraform
./activate-latest-version.sh "<application-id>"
```

`<application-id>` は AppRun 専有型のアプリケーション ID（UUID）です。接続先を差し替える場合は
`APPRUN_DEDICATED_API_URL`、一覧のページサイズを変える場合は `APPRUN_VERSION_PAGE_SIZE` を設定します。
