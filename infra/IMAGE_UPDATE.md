# コンテナイメージ更新・再デプロイ手順

アプリケーションの変更を新しいコンテナイメージとしてAppRunへ再デプロイする手順です。
コマンドはすべてリポジトリルートで実行します。

## 重要事項

- `ENABLE_TLS=true` または `ENABLE_TLS=false` を毎回必ず明示します。
- Git SHAなど、既存versionと異なるイメージタグを使います。
- Terraformはbackendとfrontendに同じタグを使うため、同じタグの両イメージが必要です。
- `terraform apply` より先に両イメージのpushを完了させます。
- migration SQLはbackendバイナリへ埋め込まれ、backend起動時に未適用分だけ実行されます。

## 1. 変更を検証する

backendを変更した場合は、少なくともGoのテストを実行します。

```sh
cd app/backend
go test ./...
go vet ./...
cd ../..
```

Terraformを変更した場合は以下も実行します。

```sh
terraform -chdir=infra/terraform fmt -check
terraform -chdir=infra/terraform validate
```

## 2. レジストリと新しいタグを決める

コミット済みの変更はGit SHAを使用します。

```sh
export REGISTRY_HOST="$(terraform -chdir=infra/terraform output -raw registry_fqdn)"
export IMAGE_TAG="$(git rev-parse HEAD)"
```

未コミットの動作確認を行う場合は、既存タグと衝突しない値を明示します。

```sh
export IMAGE_TAG="test-$(date +%Y%m%d-%H%M%S)"
```

使用する値を確認します。

```sh
printf 'REGISTRY_HOST=%s\nIMAGE_TAG=%s\n' "${REGISTRY_HOST}" "${IMAGE_TAG}"
```

## 3. backendイメージをbuild・pushする

```sh
docker login "${REGISTRY_HOST}" --username ci
docker buildx build \
  --platform linux/amd64 \
  --tag "${REGISTRY_HOST}/intern2026-app-backend:${IMAGE_TAG}" \
  --push \
  ./app/backend
```

## 4. frontendイメージを同じタグで用意する

このリポジトリにはfrontendのビルド元がないため、配布済みイメージを同じタグで
レジストリへpushします。backendだけを変更した場合もこの手順は省略できません。

```sh
docker login intern22.sakuracr.jp
docker pull --platform linux/amd64 \
  intern22.sakuracr.jp/intern2026-app-frontend:latest
docker tag \
  intern22.sakuracr.jp/intern2026-app-frontend:latest \
  "${REGISTRY_HOST}/intern2026-app-frontend:${IMAGE_TAG}"
docker push "${REGISTRY_HOST}/intern2026-app-frontend:${IMAGE_TAG}"
```

## 5. Terraform planを確認する

本番の現在構成がTLS有効の場合は `ENABLE_TLS=true` を指定します。

```sh
set -a; source .env; set +a
export TF_VAR_sakura_access_token="${SAKURA_ACCESS_TOKEN}"
export TF_VAR_sakura_access_token_secret="${SAKURA_ACCESS_TOKEN_SECRET}"
export TF_VAR_enable_tls=true
export TF_VAR_sakuravel_backend_image_name="intern2026-app-backend:${IMAGE_TAG}"
terraform -chdir=infra/terraform plan
```

通常のイメージ更新では、backend/frontendのversionがそれぞれ
`create replacement and then destroy` になることを確認します。意図せず
TLS、ホスト名、DBなどが変わるplanならapplyせず、設定を見直してください。

## 6. 差分に応じた方法でデプロイする

### パターンA: versionだけを更新する

ASGとLBの置換がplanに含まれない通常更新で使用します。新versionを先に作り、
active切替後に旧versionを削除します。

```sh
ENABLE_TLS=true IMAGE_TAG="${IMAGE_TAG}" \
  ./deploy.sh -auto-approve
```

### パターンB: ASGまたはLBを再作成する

ASG/LBは同じIP poolで新旧を並存できません。専用スクリプトがapplicationを
無効化し、version/LB/ASGだけを削除してから再作成します。一時停止が発生します。

```sh
ENABLE_TLS=true IMAGE_TAG="${IMAGE_TAG}" \
  ./deploy-recreate-runtime.sh -auto-approve
```

このスクリプトの限定destroyにはDB、cluster、internet、private vSwitchを含めません。

## 7. 起動と疎通を確認する

```sh
terraform -chdir=infra/terraform output backend_version
terraform -chdir=infra/terraform output frontend_version
./infra/terraform/check-lb.sh
```

切り替え直後にHTTP `404` になる場合は、AppRunが新コンテナを起動中の可能性が
あります。少し待ってから再確認します。継続して `404` や `5xx` になる場合は、
まずbackend/frontendの両方に `${IMAGE_TAG}` のイメージがpush済みか確認してください。
