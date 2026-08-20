# デプロイ前手順(Webブラウザでの操作)

- ドメインを用意する

## APIキーの発行

[さくらのクラウドホーム > APIキー](https://secure.sakura.ad.jp/cloud/#/apikeys) よりAPIキーを発行する

<img width="2159" height="1228" alt="image" src="https://github.com/user-attachments/assets/06b15da3-22c4-4265-ab35-09d3a607888f" />

好きな名前を入力し、以下の権限を付与する。

- アクセスレベル
  - 作成・削除
- アクセス権
  - オブジェクトストレージ
  - AppRun
  - セキュリティコントロール管理者

<img width="1972" height="292" alt="image" src="https://github.com/user-attachments/assets/574df24a-1d3e-4953-8009-4812819c0fb5" />  
memo: 図が違う。運用者じゃなくて管理者

アクセストークン、アクセストークンシークレットを保存しておく

<img width="917" height="761" alt="image" src="https://github.com/user-attachments/assets/6721f2db-33af-4717-8e39-d6c25fe4e74d" />

## サービスプリンシパルIDの発行

[さくらのクラウドホーム > サービスプリンシパル](https://secure.sakura.ad.jp/cloud/#/service-principals) よりサービスプリンシパルを作成する

1. 「サービスプリンシパルの作成」をクリック  
<img width="2940" height="1912" alt="image" src="https://github.com/user-attachments/assets/21d0dfb2-ecac-430a-a51a-c390fef7113b" />

2. お好きな名前を入力して作成  
<img width="2940" height="1912" alt="image" src="https://github.com/user-attachments/assets/6dce8365-f0f0-467d-bfae-828fb596e012" />
<img width="1408" height="798" alt="image" src="https://github.com/user-attachments/assets/2fdbaa4d-9a18-495e-a49f-2100fa2e4298" />


3. リソースIDをコピーした後、キャンセルをクリックして画面を閉じる  
<img width="2940" height="1912" alt="image" src="https://github.com/user-attachments/assets/74042509-e176-4487-90be-eb213b3c09e6" />

## サービスプリンシパルに権限を付与

[さくらのクラウドホーム > IAMポリシー](https://secure.sakura.ad.jp/cloud/#/iam-policy) よりIAMポリシーを設定する

1. 「アクセス権の付与」をクリック
<img width="2940" height="1912" alt="image" src="https://github.com/user-attachments/assets/29be9b66-cd16-4751-bc47-bcec5114acca" />

2. プリンシパルに、先程作成したサービスプリンシパルを選択  
<img width="1990" height="1052" alt="image" src="https://github.com/user-attachments/assets/21d64e18-77a5-42d5-92e3-3da5fe73342a" />

3. ロールにて「さくらのクラウド > 作成・削除」と「AppRun > AppRun専有型管理者」を選択  
<img width="1828" height="1436" alt="image" src="https://github.com/user-attachments/assets/df886a8c-671f-4df3-b4e5-0cc79f7f603f" />  
<img width="1728" height="1038" alt="image" src="https://github.com/user-attachments/assets/0fb57002-75ac-409e-8444-72361ab43a41" />

4. 「作成」をクリック
<img width="2940" height="1912" alt="image" src="https://github.com/user-attachments/assets/6e34e596-5c6a-4d76-a0b2-da9e74492c96" />  
<img width="1134" height="484" alt="image" src="https://github.com/user-attachments/assets/e3bbac55-f4c5-4de4-8c81-e0d200ea7344" />


# 初期デプロイ手順

初期デプロイはローカルで実施します。state保存用バケットとコンテナレジストリを
bootstrapで作成した後、アプリケーション基盤をTLSなしで構築し、DNS設定後にTLSを
有効化します。初期デプロイ完了後の更新はGitHub Actionsから実施します。

特記がない限り、コマンドはリポジトリルートで実行してください。

## 1. 前提ツールを確認する

以下のコマンドが実行できることを確認します。

```sh
terraform version
docker buildx version
curl --version
jq --version
gh --version
```

リポジトリをクローンします。

```sh
git clone https://github.com/hyouhyan/sakura-intern-28.git sakura-intern-28-teamD
cd sakura-intern-28-teamD
```

## 2. さくらのクラウドAPI認証情報を設定する

```sh
cp .env.example .env
```

`.env`を編集し、AppRunやオブジェクトストレージを操作できるAPIキーを設定します。

```dotenv
SAKURA_ACCESS_TOKEN="..."
SAKURA_ACCESS_TOKEN_SECRET="..."
```

`.env`と、この手順で作成する`*.tfvars`、`backend.hcl`はGit管理外です。

## 3. bootstrapの設定を作成する

bootstrapは次のリソースをローカルで一度だけ作成します。

- Terraform state保存用のオブジェクトストレージバケットとAPIキー
- コンテナレジストリと`ci`・`apprun`ユーザー
- 配布元レジストリから取得したfrontend/backendの初期イメージ

```sh
cp infra/terraform-bootstrap/sercet.auto.tfvars.example \
  infra/terraform-bootstrap/secret.auto.tfvars
```

`infra/terraform-bootstrap/secret.auto.tfvars`の各値を設定します。

| 変数 | 設定内容 |
| --- | --- |
| `sakura_access_token` | `.env`と同じさくらのクラウドAPIトークン |
| `sakura_access_token_secret` | `.env`と同じAPIトークンシークレット |
| `registry_ci_user_password` | GitHub Actionsからpushする`ci`ユーザーのパスワード |
| `registry_apprun_user_password` | AppRunがpullする`apprun`ユーザーのパスワード |
| `source_registry_username` | 配布元レジストリのユーザー名 |
| `source_registry_password` | 配布元レジストリのパスワード |
| `bucket_name` | state保存用の一意なバケット名 |
| `registry_name` | コンテナレジストリの表示名 |
| `registry_subdomain_label` | `<値>.sakuracr.jp`となる一意なサブドメイン |

パスワードは1Passwordの該当項目を使用してください。`bucket_name`と
`registry_subdomain_label`はサービス全体で重複しない値にします。

## 4. bootstrapを実行する

```sh
terraform -chdir=infra/terraform-bootstrap init
terraform -chdir=infra/terraform-bootstrap plan
terraform -chdir=infra/terraform-bootstrap apply
```

bootstrapのstateはローカル管理です。削除すると作成済みリソースをTerraformで管理
できなくなるため、安全な場所に保管してください。

作成結果を確認します。

```sh
terraform -chdir=infra/terraform-bootstrap output bucket_name
terraform -chdir=infra/terraform-bootstrap output registry_fqdn
```

## 5. アプリケーションTerraformの設定を作成する

秘密変数を作成します。

```sh
cp infra/terraform/secret.auto.tfvars.example \
  infra/terraform/secret.auto.tfvars
```

`infra/terraform/secret.auto.tfvars`を編集します。

| 変数 | 設定内容 |
| --- | --- |
| `db_password` | データベースのパスワード。1Passwordの「DBパスワード（課題用）」を推奨 |
| `service_principal_id` | AppRun操作権限を持つサービスプリンシパルID |
| `frontend_host` | frontend公開用FQDN |
| `backend_host` | API公開用FQDN。frontendとは別のFQDNにする |
| `registry_apprun_user_password` | bootstrapに設定した同名変数と同じ値 |

環境固有の値を作成します。

```sh
cp infra/terraform/environment.auto.tfvars.example \
  infra/terraform/environment.auto.tfvars
```

`infra/terraform/environment.auto.tfvars`を編集します。

| 変数 | 設定内容 |
| --- | --- |
| `zone` | 作成先zone。デフォルトは石狩第1の`is1a` |
| `cluster_name` | AppRunクラスタ名 |
| `cluster_lets_encrypt_email` | Let's Encryptの通知先メールアドレス |
| `registry_name` | bootstrapの`registry_name`と同じ値 |
| `enable_tls` | 初回構築時は`false` |

`zone`と`cluster_name`を構築後に変更すると、DBを含む主要リソースが再作成される
可能性があります。

## 6. S3 backendを設定してTerraformを初期化する

bootstrapが発行したオブジェクトストレージの認証情報を`backend.hcl`へ設定します。

```sh
cp infra/terraform/backend.hcl.example infra/terraform/backend.hcl
terraform -chdir=infra/terraform-bootstrap output -raw access_key
terraform -chdir=infra/terraform-bootstrap output -raw secret_key
```

表示された値を`infra/terraform/backend.hcl`の`access_key`と`secret_key`へ設定します。
バケット名を環境変数へ設定し、初期化します。

```sh
export TFSTATE_BUCKET="$(terraform -chdir=infra/terraform-bootstrap output -raw bucket_name)"

terraform -chdir=infra/terraform init \
  -backend-config=backend.hcl \
  -backend-config="bucket=${TFSTATE_BUCKET}"
```

## 7. 初回デプロイ用イメージを用意する

bootstrapで作成したレジストリへログインし、Gitのcommit SHAと同じタグを持つ
backend/frontendイメージを用意します。

```sh
export REGISTRY_HOST="$(terraform -chdir=infra/terraform-bootstrap output -raw registry_fqdn)"
export IMAGE_TAG="$(git rev-parse HEAD)"
docker login "${REGISTRY_HOST}" --username ci
```

パスワードにはbootstrapの`registry_ci_user_password`を入力します。

backendを`linux/amd64`向けにbuild・pushします。

```sh
docker buildx build \
  --platform linux/amd64 \
  --tag "${REGISTRY_HOST}/intern2026-app-backend:${IMAGE_TAG}" \
  --push \
  ./app/backend
```

bootstrapが投入したfrontendの`latest`を、同じcommit SHAでタグ付けします。

```sh
docker pull --platform linux/amd64 \
  "${REGISTRY_HOST}/intern2026-app-frontend:latest"
docker tag \
  "${REGISTRY_HOST}/intern2026-app-frontend:latest" \
  "${REGISTRY_HOST}/intern2026-app-frontend:${IMAGE_TAG}"
docker push "${REGISTRY_HOST}/intern2026-app-frontend:${IMAGE_TAG}"
```

## 8. TLSなしで初回構築する

DNS設定前のため、TLSを無効化してローカルから初回applyします。

```sh
ENABLE_TLS=false IMAGE_TAG="${IMAGE_TAG}" \
  ./deploy.sh -auto-approve
```

applyが完了し、frontend/backendのURLが出力されることを確認します。

## 9. DNSを設定する

ロードバランサーのVIPを確認します。

```sh
terraform -chdir=infra/terraform output -raw lb_vip
```

`frontend_host`と`backend_host`のAレコードを、どちらもこのVIPへ向けます。
CDNなどのプロキシは経由させないでください。Let's EncryptのHTTP-01検証が
ロードバランサーの80番ポートへ到達できる必要があります。

```sh
dig +short <frontend_host> A
dig +short <backend_host> A
```

両方がロードバランサーのVIPを返してから次へ進みます。

## 10. TLSを有効化する

`infra/terraform/environment.auto.tfvars`の`enable_tls`も`true`へ変更し、TLSを有効化して
再度ローカルからapplyします。

```sh
ENABLE_TLS=true IMAGE_TAG="${IMAGE_TAG}" \
  ./deploy.sh -auto-approve
```

証明書発行とコンテナ起動には時間がかかる場合があります。

## 11. 疎通を確認する

```sh
./infra/terraform/check-lb.sh
```

frontendとbackendがHTTP `200`を返し、証明書のissuerがLet's Encryptであることを
確認します。backend起動時にはDB migrationも自動実行されます。

## 12. GitHub Actionsの設定を登録する

GitHub CLIで対象リポジトリへログインします。

```sh
gh auth login
gh auth status
```

ローカル設定とbootstrap outputから、必要なGitHub SecretsとRepository Variablesを
確認・登録します。Secretの値は出力されません。

```sh
./sync_github_config.sh --dry-run
./sync_github_config.sh
```

別のリポジトリへ登録する場合は`--repo OWNER/REPOSITORY`を指定します。

```sh
./sync_github_config.sh --repo hyouhyan/sakura-intern-28
```

登録される項目は[README](README.md)の一覧を参照してください。

## デプロイ後の運用

初期デプロイ完了後は、`main`へのmergeまたはpushでGitHub Actionsの`Deploy`が実行され、
次の処理を直列に行います。

1. backendをbuildしてcommit SHAタグでpush
2. frontendに同じcommit SHAタグを付けてpush
3. Terraformの`init`、`validate`、`plan`
4. Terraformの`apply`と新しいAppRun versionの有効化

state保存先のS3互換APIには排他ロックがないため、Actionsの`concurrency`で同時applyを
防止しています。ローカルとActionsでapplyを同時に実行しないでください。

ASGまたはロードバランサーの置換をplanで検出した場合、通常のpush起点のデプロイは
停止します。停止時間を確認したうえで、Actionsの`Run workflow`から
`recreate_runtime`を有効にして手動実行してください。

デプロイ後は少なくとも次を確認します。

- GitHub Actionsの全stepが成功していること
- frontend/backendのHTTPステータスとTLS証明書
- AppRunの新versionがactiveで、旧versionのactive nodeが0になっていること
- アプリケーションログ、DB接続エラー、5xx応答の有無
- Terraform planに意図しない再作成や削除が含まれていないこと
