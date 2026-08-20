# 28卒エンジニアインターン用インフラ

- [初回デプロイ手順](FIRST_DEPLOY.md)
- [コンテナイメージ更新・再デプロイ手順](IMAGE_UPDATE.md)

構築や更新の際は、上記の該当手順書に従ってください。クレデンシャルは
1Passwordに保管されています。

zoneとcluster名は `terraform/environment.auto.tfvars` に保存します。このファイルは
git管理外です。新しい環境では `environment.auto.tfvars.example` をコピーしてください。

`terraform init` に必要な state 保存用バケット名は `TFSTATE_BUCKET` 環境変数から
`-backend-config` へ渡します。認証情報 (`access_key` / `secret_key`) は
`-backend-config` 用のファイルで供給します：

```
cp backend.hcl.example backend.hcl
# access_key / secret_key を編集 (値は bootstrap の出力、下記参照)
export TFSTATE_BUCKET="intern26-group-d-tfstate-131313"
terraform init \
  -backend-config=backend.hcl \
  -backend-config="bucket=${TFSTATE_BUCKET}"
```

## Terraform apply について

`infra/terraform` の `terraform apply` は GitHub Actions
(`.github/workflows/deploy.yml`) からのみ実行します。
`main` へのマージ・push を契機に、backend/frontendへ同じGit SHAのタグを付けて
pushした後、`init` → `validate` → `plan` → `apply` が順番に実行されます。
ローカルから `terraform apply` を実行しないでください
(`terraform plan` までの確認はローカルで行って構いません)。

state はさくらのオブジェクトストレージ (S3 互換 API) に保存しており、
ロック機能が使えないため、GitHub Actions 側の `concurrency` で
apply の同時実行を防いでいます。

### state 保存用バケットの初回作成 (bootstrap)

`infra/terraform-bootstrap` で state 保存用バケットを作成します。
これは "バケット自体を作る" ためのモジュールなので、CI ではなく
**ローカルで一度だけ手動 apply** します (state はローカル管理)。

```
cd infra/terraform-bootstrap
export SAKURA_ACCESS_TOKEN=...
export SAKURA_ACCESS_TOKEN_SECRET=...
terraform init
terraform apply
terraform output -raw access_key
terraform output -raw secret_key
```

出力された `access_key` / `secret_key` を GitHub Secrets の
`tfstate_access_key_id` / `tfstate_secret_access_key` に登録してください。

### GitHub Secrets 一覧

| Secret名 | 用途 |
| --- | --- |
| `sakura_access_token` | さくらのクラウド API トークン |
| `sakura_access_token_secret` | さくらのクラウド API トークンシークレット |
| `tfstate_access_key_id` | state 保存用オブジェクトストレージのアクセスキー (bootstrap の出力) |
| `tfstate_secret_access_key` | state 保存用オブジェクトストレージのシークレットキー (bootstrap の出力) |
| `tf_var_db_password` | データベースパスワード |
| `tf_var_registry_apprun_user_password` | AppRun pull用ユーザーのパスワード |
| `registry_subdomain` | さくらのコンテナレジストリのサブドメイン (`<registry_subdomain>.sakuracr.jp`) |
| `registry_ci_user_password` | コンテナレジストリの CI 用ユーザー (`ci`) のパスワード |

GitHub Repository Variablesには次を登録します。

| Variable名 | 用途 |
| --- | --- |
| `enable_tls` | 本番構成に合わせて `true` または `false` を明示 |
| `tf_var_zone` | Terraformのzone（例: `is1c`） |
| `tf_var_cluster_name` | Terraformのcluster名 |
| `tf_var_cluster_lets_encrypt_email` | Let's Encryptの証明書通知先メールアドレス |
| `tf_var_registry_name` | bootstrap で作成したコンテナレジストリの表示名 |
| `registry_apprun_user_name` | AppRun pull用ユーザー名（未設定時は `apprun`） |
| `tfstate_bucket` | bootstrap で作成した Terraform state 保存用バケット名 |
| `TF_VAR_service_principal_id` | AppRunクラスタのサービスプリンシパルID |
| `TF_VAR_frontend_host` | frontendを公開するFQDN |
| `TF_VAR_backend_host` | backendを公開するFQDN |

通常のversion更新は無停止で自動デプロイされます。planにASG/LBの置換が含まれる場合、
push起点の実行は一時停止を避けるため失敗させます。内容を確認後、Actionsの
`Run workflow` から `recreate_runtime` を有効にして手動実行してください。

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
