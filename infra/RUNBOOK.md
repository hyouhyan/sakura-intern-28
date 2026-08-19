# 構築・運用手順

`infra/README.md` は構成の説明、こちらは手を動かす手順です。

## 必要なもの

| ツール | 用途 |
| --- | --- |
| Terraform 1.11 以降 | `required_version` の指定。write-only 引数を使っている |
| Docker（buildx が使えること） | イメージのビルドと push |
| `jq` | `activate-latest-version.sh` が使う |
| `curl` | `redeploy.sh` が AppRun API を叩く |

さくらのクラウドの API キーには **AppRun の操作権限**が必要です。

## ゾーンについて

既定は **石狩第3 (`is1c`)** です。

この構成はスイッチを 2 つ使います（ルータ付属のグローバル用と、DB とワーカーノードをつなぐプライベート用）。**石狩第1 (`is1a`) はゾーン内のスイッチ数上限に引っかかり、2 つ目が作れませんでした。**

```
409 Conflict / limit_count_in_zone
要求を受け付けできません。ゾーン内リソース数上限により、リソースの割り当てに失敗しました。
```

破棄から 25 分待ってリトライしても解放されませんでした。ゾーンを変える場合は、**ルータが作り直しになるので VIP が変わり、DNS の貼り直しが必要**です。

## tfvars を用意する

3 つとも gitignore 対象なので、クローン後に自分で作ります。

```bash
cd infra/terraform
cp secret.auto.tfvars.example secret.auto.tfvars   # API キー、DB とレジストリのパスワード
cp tls.auto.tfvars.example  tls.auto.tfvars        # frontend_host / backend_host / enable_tls
```

`registry.auto.tfvars` は、既定のレジストリ名が使えない場合だけ作ります（後述）。

```hcl
registry_name            = "インターン用"
registry_subdomain_label = "intern6"
```

---

## まっさらな状態から構築する

この手順は実際にすべて破棄してから通しで実行して確認しています（is1c、所要 40 分ほど）。

**順序が重要です。** イメージが無いまま version を作るとコンテナが起動せず、DNS が無いまま TLS を有効にすると Let's Encrypt のレート制限を消費します。

### 1. コンテナレジストリを用意する

`subdomain_label` は `sakuracr.jp` 全体で一意です。他アカウントで使われている名前は作成できず、`400 registry_name: すでに利用されています` になります。

**新しく作る場合** — `registry.auto.tfvars` で未使用の名前を指定してから:

```bash
terraform apply -target=sakura_container_registry.intern
```

**既存のレジストリを使う場合** — `registry.auto.tfvars` を実物に合わせたうえで import します。

```bash
# アカウント内のレジストリを一覧する
curl -s -u "$SAKURA_ACCESS_TOKEN:$SAKURA_ACCESS_TOKEN_SECRET" \
  "https://secure.sakura.ad.jp/cloud/zone/is1a/api/cloud/1.1/commonserviceitem" \
  | jq -r '.CommonServiceItems[] | select(.Provider.Class=="containerregistry")
           | "\(.ID)\t\(.Name)\t\(.Status.hostname)"'

terraform import sakura_container_registry.intern <ID>
terraform apply -target=sakura_container_registry.intern
```

> import 後の apply は、`registry.tf` に書いた `ci` / `apprun` の 2 ユーザーに置き換えます。**既存のユーザーは消えます。**

### 2. イメージをビルドして push する

```bash
docker login <registry>.sakuracr.jp -u ci
REGISTRY_HOST=<registry>.sakuracr.jp ./build_push_backend.sh
REGISTRY_HOST=<registry>.sakuracr.jp ./build_push_frontend.sh
```

タグは `git rev-parse HEAD` です。`terraform_apply.sh` と `redeploy.sh` も同じ規則で決めます。

> **push のあとにコミットを積むとタグがずれます。** HEAD が動いた瞬間、terraform は存在しないイメージを指すようになり、コンテナが起動せず 503 のままになります。実際にこれで 8 分溶かしました。
>
> - デプロイの直前にコミットを積まない、または
> - `IMAGE_TAG` を明示して固定する（`build_push_*.sh` と `terraform_apply.sh` / `redeploy.sh` の両方で同じ値にすること）
>
> 症状が出たら、まず state の `image` とレジストリの中身を突き合わせてください。
>
> ```bash
> terraform state show sakura_apprun_dedicated_version.backend | grep image
> docker manifest inspect <registry>.sakuracr.jp/intern2026-app-backend:$(git rev-parse HEAD)
> ```

> **frontend イメージには注意が必要です。** リポジトリに Dockerfile が無く、`build_push_frontend.sh` は `intern22.sakuracr.jp`（講座提供）から pull した完成品を tag し直すだけです。**`intern22` の資格情報が唯一の正規の入手経路**で、無い場合は 401 で止まります。
>
> ```
> failed to authorize: ... 401 Unauthorized
> ```
>
> 資格情報が無い場合、既にイメージを持っているレジストリか手元の Docker から持ち出すしかありません。**新しく作ったレジストリには当然 `latest` も無い**ので、この逃げ道も「どこかに現物が残っている」ことが前提です。
>
> ```bash
> SHA=$(git rev-parse HEAD)
> docker tag <既存>.sakuracr.jp/intern2026-app-frontend:latest \
>            <新>.sakuracr.jp/intern2026-app-frontend:$SHA
> docker push <新>.sakuracr.jp/intern2026-app-frontend:$SHA
> # あとで使うので latest も置いておくと楽
> docker tag <既存>.sakuracr.jp/intern2026-app-frontend:latest \
>            <新>.sakuracr.jp/intern2026-app-frontend:latest
> docker push <新>.sakuracr.jp/intern2026-app-frontend:latest
> ```

### 3. ネットワークだけ先に作って VIP を確定させる

DNS を先に登録したいのに、VIP は作ってみないと分かりません。ルータだけ先に作ります。

```bash
terraform apply -target=sakura_internet.main
terraform output -raw lb_vip
```

VIP は払い出されたセグメントから決定的に決まるので、`sakura_internet` を壊さない限り変わりません。

### 4. DNS の A レコードを 2 本登録する

`frontend_host` と `backend_host` の両方を VIP に向けます。**CDN のプロキシは経由させないでください**（Let's Encrypt の HTTP-01 チャレンジが 80 番に届かなくなります）。

```bash
terraform output dns_records
```

`dig` などで両方が VIP を返すのを確認してから次へ進みます。失敗するとレート制限を消費します。

### 5. 全体を apply する

```bash
cd ../..            # リポジトリのルート
./terraform_apply.sh
```

ワーカーノードのブートに 10 分前後かかります。状態は `terraform output worker_nodes` で見られます。

### 6. version を有効化する

apply は version を作りますが、有効化はしません（`active_version` は terraform 管理外）。

```bash
cd infra/terraform
./redeploy.sh
```

### 7. DB マイグレーションを適用する

**terraform では適用されません。** データベースアプライアンスはプライベート網からしか到達できないため、AppRun 上に一時的なコンテナを流して適用します。仕組み化はまだできていません。

```bash
mkdir -p /tmp/migrate && cd /tmp/migrate
cp <repo>/app/backend/migrations/*.sql .

cat > run.sh <<'EOF'
#!/bin/sh
DSN="${DATABASE_URL}"
CREDS="${DSN%%@tcp(*}"; REST="${DSN#*@tcp(}"; ADDR="${REST%%)*}"; TAIL="${REST#*)/}"
U="${CREDS%%:*}"; P="${CREDS#*:}"; H="${ADDR%%:*}"; PT="${ADDR##*:}"; D="${TAIL%%\?*}"
mkdir -p /tmp/www
M="mariadb --skip-ssl --connect-timeout=10 -h $H -P $PT -u $U -p$P"
echo "waiting" > /tmp/www/index.html
httpd -f -p "${PORT:-8080}" -h /tmp/www &
{
  # コンテナ起動直後は eth1 がまだ使えないことがあるので到達を待つ
  i=0; while [ $i -lt 60 ]; do i=$((i+1)); $M -e 'SELECT 1' >/dev/null 2>&1 && break; sleep 5; done
  for f in /migrations/*.sql; do
    echo "=== $f ==="
    # 002 は CREATE INDEX に IF NOT EXISTS が無いので --force で既存分を飛ばす
    $M --force "$D" < "$f" 2>&1 | head -10
  done
  $M "$D" -e 'SHOW TABLES;' 2>&1 | head -20
} > /tmp/www/index.html 2>&1
wait
EOF

cat > Dockerfile <<'EOF'
FROM alpine:3.21
RUN apk add --no-cache mariadb-client busybox-extras
COPY *.sql /migrations/
COPY run.sh /run.sh
CMD ["/bin/sh", "/run.sh"]
EOF

docker buildx build --platform linux/amd64 \
  -t <registry>.sakuracr.jp/intern2026-app-backend:migrate --push .
```

backend の version を一時的にこのイメージに差し替えて実行し、結果を読んだら戻します。

```bash
cd <repo>/infra/terraform
IMAGE_TAG=migrate ./redeploy.sh
curl -s https://<backend_host>/          # 適用結果が返る
./redeploy.sh                             # 本来のイメージに戻す
```

> **frontend も巻き込まれます。** frontend のイメージ名は backend と同じ変数から
> `replace()` で導出されるため、タグを `migrate` にすると frontend も
> `intern2026-app-frontend:migrate` を探しに行き、無ければ 503 になります。
> 先に同じタグで frontend を push しておいてください。
>
> ```bash
> docker tag <registry>.sakuracr.jp/intern2026-app-frontend:latest \
>            <registry>.sakuracr.jp/intern2026-app-frontend:migrate
> docker push <registry>.sakuracr.jp/intern2026-app-frontend:migrate
> ```

### 8. 確認する

```bash
terraform output private_net      # DB とノードの IP 割り当て
terraform output worker_nodes     # ノードの状態と NIC
curl -s -o /dev/null -w '%{http_code}\n' https://<frontend_host>/
curl -s -o /dev/null -w '%{http_code}\n' https://<backend_host>/posts   # 401 なら起動済み
```

---

## アプリを更新する

イメージを push してから `redeploy.sh` を叩くだけです。**実行中は数分ダウンします。**

```bash
REGISTRY_HOST=<registry>.sakuracr.jp ./build_push_backend.sh
cd infra/terraform && ./redeploy.sh
```

`redeploy.sh` は「AppRun API で無効化 → version を作り直し（解放待ちリトライ）→ `activate-latest-version.sh` で有効化」を自動でやります。

構成を変えない（version の中身を変えない）ときは素の `terraform apply` で足ります。

---

## すべて破棄する

そのままでは失敗します。アクティブな version は削除できません。

```bash
cd infra/terraform
BE=$(terraform output -raw backend_application_id)
FE=$(terraform output -raw frontend_application_id)
API=https://secure.sakura.ad.jp/cloud/api/apprun-dedicated/1.0
for app in "$BE" "$FE"; do
  curl -s -u "$SAKURA_ACCESS_TOKEN:$SAKURA_ACCESS_TOKEN_SECRET" \
    -H 'Content-Type: application/json' -H 'X-Requested-With: XMLHttpRequest' \
    -X PUT -d '{"activeVersion":null}' "$API/applications/$app"
done

# コンテナがノードから抜けるまで数分かかるので、400 が出る間はリトライする
terraform destroy
```

破棄する前に確認してください。

- **レジストリごと消えます。** `sakura_container_registry.intern` が破棄対象に入っており、中のイメージも失われます。既存のものを import している場合は特に注意してください。
- **VIP が変わることがあります。** `sakura_internet` を破棄して作り直すとセグメントが再割り当てされます。同じゾーンで作り直したときは同じ VIP が返ってきましたが、**保証はされません**（ゾーンを変えたときは当然変わりました）。変わった場合は DNS の貼り直しと証明書の再取得が必要です。`terraform output dns_records` で確認してください。
- **DB のデータが消えます。**

---

## ハマりどころ

| 症状 | 原因 | 対処 |
| --- | --- | --- |
| `registry_name: すでに利用されています` | `subdomain_label` は `sakuracr.jp` 全体で一意 | 別名にするか、既存を import する |
| コンテナが起動しない | イメージのタグが `git HEAD` とずれている | push し直すか `IMAGE_TAG` を明示する |
| `Provider produced inconsistent result after apply` (`env_vars`) | API はキー名の昇順で返すが provider は List | `env_vars` を昇順で書く。plan では出ない |
| backend が 503 のまま | DB に ping できずプロセスが終了している | DB のポート・`source_ranges`・schema を確認 |
| 日本語が INSERT できない（409 が返る） | アプライアンスの `character_set_server` は `latin1` | マイグレーションで `CHARSET` を明示する |
| `ERROR 1129 Host is blocked` | 認証しない TCP 接続が `max_connect_errors` を超えた | **DB に TCP のみのヘルスチェックを向けないこと。** MariaDB の再起動で解除 |
| `terraform apply` がアプリを無効化する | `active_version` が terraform 管理外でドリフトする | `lifecycle { ignore_changes = [active_version] }` 済み |
| `-target` を付けたのに ASG や LB まで再作成される | `-target` は依存リソースも巻き込む | 変数を変えた状態で `-target` を使わない |
| リトライすべきエラーで即中断する | terraform のログに不正な UTF-8 が混ざり grep がバイナリ扱いする | `grep -a` を使う（対応済み） |
| `409 limit_count_in_zone` | ゾーン内のスイッチ数上限。`is1a` で発生 | `is1c` を使う。ゾーン変更は VIP が変わる |
| frontend の push が 401 | `intern22` の資格情報が無い | 現物を持っているレジストリ / 手元の Docker から持ち出す |
| デプロイ後ずっと 503 | イメージのタグが HEAD とずれている | state の `image` とレジストリを突き合わせる |

### 変えるとサービスが落ちるもの

`asg_min_nodes` / `asg_max_nodes` / `name_servers` / `zone` / `interfaces` はすべて `RequiresReplace` で、provider は ASG の Update を実装していません。**1 つ変えるだけで ASG が作り直しになり、LB も巻き添えで再作成されます**（実測で 20 分前後のダウンと証明書の再発行）。

なお「コンテナ 1 個につきワーカーノード 1 台」ではありません。ノードの空きリソースに収まる限り 1 台に複数のコンテナが載ります（実測で 4 コンテナが 3 ノードに収まりました）。
