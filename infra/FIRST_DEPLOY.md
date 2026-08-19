# 初回デプロイ手順

この手順は、何も構築されていない環境へ Terraform で初回デプロイするためのものです。
コマンドはすべてリポジトリルートで実行します。

## 1. 前提ツールを確認する

以下を利用します。

- Terraform
- Docker（`buildx` を含む）
- `curl`
- `jq`

```sh
terraform version
docker buildx version
curl --version
jq --version
```

## 2. 認証情報を設定する

`.env` を作成し、1Password に保存されているさくらのクラウド API トークンを設定します。

```sh
cp .env.example .env
```

```dotenv
SAKURA_ACCESS_TOKEN="..."
SAKURA_ACCESS_TOKEN_SECRET="..."
```

`ENABLE_TLS` は `.env` に保存しません。デプロイのたびにコマンドで明示します。

次に Terraform 用の秘密変数を作成します。

```sh
cp infra/terraform/secret.auto.tfvars.example \
  infra/terraform/secret.auto.tfvars
```

最低限、以下を実環境の値へ変更します。

- `db_password`
- `service_principal_id`
- `frontend_host`
- `backend_host`
- `registry_ci_user_password`
- `registry_apprun_user_password`

`frontend_host` と `backend_host` には異なる FQDN を指定してください。

環境固有のzoneとcluster名も、git管理外のファイルへ固定します。

```sh
cp infra/terraform/environment.auto.tfvars.example \
  infra/terraform/environment.auto.tfvars
```

`environment.auto.tfvars` の `zone` と `cluster_name` を対象環境に合わせて変更します。
構築後にこれらを変更すると、DBを含む主要リソースが再作成されるため注意してください。

## 3. Terraformを初期化する

```sh
terraform -chdir=infra/terraform init
terraform -chdir=infra/terraform fmt -check
terraform -chdir=infra/terraform validate
```

## 4. コンテナレジストリを先に作成する

TLS設定は未使用の `target` 実行でも必ず明示します。

```sh
ENABLE_TLS=false ./terraform_apply.sh \
  -target=sakura_container_registry.intern \
  -auto-approve
```

レジストリのホスト名と、イメージに付けるタグを取得します。

```sh
export REGISTRY_HOST="$(terraform -chdir=infra/terraform output -raw registry_fqdn)"
export IMAGE_TAG="$(git rev-parse HEAD)"
```

## 5. backendとfrontendのイメージをpushする

Terraformはbackendとfrontendに必ず同じタグを使います。片方だけではデプロイ後に
コンテナを起動できないため、両方をレジストリへ用意します。

まず、`secret.auto.tfvars` のCIユーザー情報で作成したレジストリへログインします。

```sh
docker login "${REGISTRY_HOST}" --username ci
```

backendをAppRun向けの `linux/amd64` としてbuild・pushします。

```sh
docker buildx build \
  --platform linux/amd64 \
  --tag "${REGISTRY_HOST}/intern2026-app-backend:${IMAGE_TAG}" \
  --push \
  ./app/backend
```

配布済みfrontendイメージを同じタグでpushします。

```sh
docker login intern22.sakuracr.jp
docker pull --platform linux/amd64 \
  intern22.sakuracr.jp/intern2026-app-frontend:latest
docker tag \
  intern22.sakuracr.jp/intern2026-app-frontend:latest \
  "${REGISTRY_HOST}/intern2026-app-frontend:${IMAGE_TAG}"
docker push "${REGISTRY_HOST}/intern2026-app-frontend:${IMAGE_TAG}"
```

## 6. TLSなしで初回構築する

DNS設定前なので `ENABLE_TLS=false` を明示します。

```sh
ENABLE_TLS=false IMAGE_TAG="${IMAGE_TAG}" \
  ./deploy.sh -auto-approve
```

applyの最後までエラーがなく、backend/frontendのversionが出力されることを確認します。

## 7. DNSを設定する

LBのVIPを確認します。

```sh
terraform -chdir=infra/terraform output -raw lb_vip
```

`frontend_host` と `backend_host` のAレコードを、どちらもこのVIPへ向けます。
CDNのプロキシは経由させないでください。Let's EncryptのHTTP-01検証が
LBの80番ポートへ到達できる必要があります。

```sh
dig +short <frontend_host> A
dig +short <backend_host> A
```

両方がLBのVIPを返してから次へ進みます。

## 8. TLSを有効化する

```sh
ENABLE_TLS=true IMAGE_TAG="${IMAGE_TAG}" \
  ./deploy.sh -auto-approve
```

証明書の発行とコンテナ起動には少し時間がかかる場合があります。

## 9. 疎通を確認する

```sh
./infra/terraform/check-lb.sh
```

frontendとbackendがHTTP `200` を返し、証明書のissuerがLet's Encryptであることを
確認します。backend起動時にはDB migrationも自動実行されます。
