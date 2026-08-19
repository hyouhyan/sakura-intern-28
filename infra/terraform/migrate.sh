#!/usr/bin/env bash
# DB マイグレーションを適用する。
#
# データベースアプライアンスはプライベート vSwitch 上にしか IP を持たず、
# terraform を実行するマシンからは到達できない。AppRun に init コンテナや
# ジョブの概念も無いため、backend の version を一時的にマイグレーション用の
# イメージに差し替えて実行し、結果を取得したら元に戻す。
#
#   ./migrate.sh
#
# 実行中の数分間、backend は本来のアプリではなくマイグレーション用の
# コンテナになる (frontend は影響を受けない)。

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${script_dir}"
repo_root="$(cd "${script_dir}/../.." && pwd)"
migrations_dir="${repo_root}/app/backend/migrations"

command -v docker >/dev/null || { echo "docker が必要です" >&2; exit 1; }
[[ -d "${migrations_dir}" ]] || { echo "${migrations_dir} が見つかりません" >&2; exit 1; }

tag="${MIGRATE_TAG:-migrate-$(date +%Y%m%d%H%M%S)}"
registry="$(terraform output -raw registry_fqdn)"

# 戻す先は「今デプロイされているイメージのタグ」。git HEAD から作ると、
# push 後にコミットを積んでいた場合に存在しないタグを指してしまう。
current_backend="$(terraform state show sakura_apprun_dedicated_version.backend | sed -n 's/.*image *= *"\(.*\)"/\1/p')"
current_frontend="$(terraform state show sakura_apprun_dedicated_version.frontend | sed -n 's/.*image *= *"\(.*\)"/\1/p')"
orig_tag="${current_backend##*:}"

echo "==> レジストリ : ${registry}"
echo "==> 一時タグ   : ${tag}"
echo "==> 復帰先タグ : ${orig_tag}"

workdir="$(mktemp -d)"
trap 'rm -rf "${workdir}"' EXIT
cp "${migrations_dir}"/*.sql "${workdir}/"

cat > "${workdir}/run.sh" <<'EOF'
#!/bin/sh
DSN="${DATABASE_URL}"
CREDS="${DSN%%@tcp(*}"; REST="${DSN#*@tcp(}"; ADDR="${REST%%)*}"; TAIL="${REST#*)/}"
U="${CREDS%%:*}"; P="${CREDS#*:}"; H="${ADDR%%:*}"; PT="${ADDR##*:}"; D="${TAIL%%\?*}"
mkdir -p /tmp/www
M="mariadb --skip-ssl --connect-timeout=10 -h $H -P $PT -u $U -p$P"
echo "MIGRATE_RUNNING" > /tmp/www/index.html
httpd -f -p "${PORT:-8080}" -h /tmp/www &
{
  echo "target: $U@$H:$PT/$D"
  echo
  # ノード新設直後は eth1 の準備が間に合わないことがあるので到達を待つ
  echo "=== DB の到達待ち ==="
  i=0
  while [ $i -lt 60 ]; do
    i=$((i+1))
    if $M -e 'SELECT 1' >/dev/null 2>&1; then echo "  ${i} 回目で到達"; break; fi
    sleep 5
  done
  echo
  for f in /migrations/*.sql; do
    echo "=== $(basename "$f") ==="
    # CREATE INDEX に IF NOT EXISTS が無いファイルがあるため、
    # --force で「既にある」エラーを飛ばして続行する
    $M --force "$D" < "$f" 2>&1 | head -20
  done
  echo
  echo "=== テーブル ==="
  $M "$D" -e 'SHOW TABLES;' 2>&1 | head -30
  echo
  echo "=== インデックス ==="
  $M "$D" -e "SELECT TABLE_NAME, INDEX_NAME FROM information_schema.STATISTICS WHERE TABLE_SCHEMA='$D' AND INDEX_NAME LIKE 'idx_%' GROUP BY TABLE_NAME, INDEX_NAME;" 2>&1 | head -30
  echo
  echo "MIGRATE_DONE"
} > /tmp/www/index.html 2>&1
wait
EOF

cat > "${workdir}/Dockerfile" <<'EOF'
FROM alpine:3.21
RUN apk add --no-cache mariadb-client busybox-extras
COPY *.sql /migrations/
COPY run.sh /run.sh
CMD ["/bin/sh", "/run.sh"]
EOF

echo "==> 1/5 マイグレーション用イメージを push"
docker buildx build --platform linux/amd64 \
  -t "${registry}/intern2026-app-backend:${tag}" --push "${workdir}" >/dev/null

# frontend のイメージ名は backend と同じ変数から replace() で導出されるため、
# タグを変えると frontend も同じタグを探しに行く。無いと 503 になるので、
# 現在の frontend イメージを同じタグで置いておく。
echo "==> 2/5 frontend を同じタグで push (巻き込み対策)"
docker pull -q "${current_frontend}" >/dev/null
docker tag "${current_frontend}" "${registry}/intern2026-app-frontend:${tag}"
docker push -q "${registry}/intern2026-app-frontend:${tag}" >/dev/null

echo "==> 3/5 マイグレーション用イメージをデプロイ"
IMAGE_TAG="${tag}" ./redeploy.sh

echo "==> 4/5 実行結果の取得"
vip="$(terraform output -raw lb_vip)"
backend_url="$(terraform output -raw backend_url)"
host="${backend_url#*://}"; host="${host%%[:/]*}"
curl_opts=(--silent --max-time 15)
case "${backend_url}" in
  https://*) curl_opts+=(--resolve "${host}:443:${vip}") ;;
esac

result=""
for _ in $(seq 1 40); do
  body="$(curl "${curl_opts[@]}" "${backend_url}/" 2>/dev/null || true)"
  case "${body}" in
    *MIGRATE_DONE*) result="${body}"; break ;;
  esac
  sleep 15
done

if [[ -n "${result}" ]]; then
  echo "----------------------------------------"
  echo "${result}"
  echo "----------------------------------------"
else
  echo "結果を取得できませんでした。手動で ${backend_url}/ を確認してください" >&2
fi

echo "==> 5/5 元のイメージに戻す"
IMAGE_TAG="${orig_tag}" ./redeploy.sh

echo "完了: マイグレーションを適用し、backend を ${orig_tag} に戻しました"
