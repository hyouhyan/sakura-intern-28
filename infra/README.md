# 28卒エンジニアインターン用インフラ

構築前に tfvars をコピーして編集します：

```
cp secret.auto.tfvars.example secret.auto.tfvars
cp tls.auto.tfvars.example tls.auto.tfvars
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

apply の直前に、backend/frontend のコンテナイメージがレジストリに
存在するかを確認するステップが入っています
(`docker-build-push.yml` の push 未完了時に、存在しないイメージを参照する
AppRun version を作ってしまうのを防ぐため)。
**コンテナレジストリ自体をまだ作っていない完全なブートストラップ時**は、
このチェックが先に失敗して `terraform apply` (＝レジストリ作成) に
たどり着けません。その場合だけ、GitHub Actions の画面から
`Terraform Apply` を `workflow_dispatch` で手動実行し、
`skip_image_check` を `true` にしてイメージチェックを一度だけ迂回してください。
レジストリ作成後にイメージを push すれば、以降は通常の push トリガーに戻せます。

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

> **注意**: 上記の GitHub Actions は現状 `terraform plan`/`apply` をそのまま実行するだけです。
> 下記「デプロイ（バージョンの作り直し）」にあるとおり、AppRun のバージョン更新
> (イメージや環境変数の変更を反映するデプロイ) には無効化 → 再作成 → 有効化の3段階 apply
> (`redeploy.sh`) が必要で、素の `terraform apply` 1回では反映されません。
> CI からのデプロイ自動化にはワークフロー側の追従が別途必要です。

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
