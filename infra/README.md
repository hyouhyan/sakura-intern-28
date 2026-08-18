# 28卒エンジニアインターン用インフラ

構築前に tfvars をコピーして編集します：

```
cp secret.auto.tfvars.example secret.auto.tfvars
```

クレデンシャルなどは1Passwordに入ってます。

`terraform init` に必要な state 保存用オブジェクトストレージの認証情報 (`access_key` /
`secret_key`) も同様にファイルで供給します (`backend` ブロックは変数を参照できないため、
tfvars ではなく `-backend-config` 用のファイルに分離しています)：

```
cp backend.hcl.example backend.hcl
# access_key / secret_key を編集 (値は bootstrap の出力、下記参照)
terraform init -backend-config=backend.hcl
```

## Terraform apply について

`infra/terraform` の `terraform apply` は GitHub Actions
(`.github/workflows/terraform-apply.yml`) からのみ実行します。
`main` へのマージ・push を契機に `init` → `validate` → `plan` → `apply` が実行されます。
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
`TFSTATE_ACCESS_KEY_ID` / `TFSTATE_SECRET_ACCESS_KEY` に登録してください。

### GitHub Secrets 一覧

| Secret名 | 用途 |
| --- | --- |
| `SAKURA_ACCESS_TOKEN` | さくらのクラウド API トークン |
| `SAKURA_ACCESS_TOKEN_SECRET` | さくらのクラウド API トークンシークレット |
| `TFSTATE_ACCESS_KEY_ID` | state 保存用オブジェクトストレージのアクセスキー (bootstrap の出力) |
| `TFSTATE_SECRET_ACCESS_KEY` | state 保存用オブジェクトストレージのシークレットキー (bootstrap の出力) |
| `TF_VAR_DB_PASSWORD` | データベースパスワード |
| `TF_VAR_SERVER_PASSWORD` | サーバー初期パスワード |
| `REGISTRY_SUBDOMAIN` | さくらのコンテナレジストリのサブドメイン (`<REGISTRY_SUBDOMAIN>.sakuracr.jp`)。`.github/workflows/docker-build-push.yml` で使用 |
| `REGISTRY_CI_USER_PASSWORD` | コンテナレジストリの CI 用ユーザー (`ci`) のパスワード |