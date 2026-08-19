#!/usr/bin/env bash
# すべて破棄する。
#
# アクティブな version は削除できないため、先に AppRun API で無効化してから
# terraform destroy を回す。無効化直後はコンテナがノード上に残っていて
# 400 になるので、解消するまでリトライする。
#
#   ./teardown.sh [terraform に渡す追加オプション]
#
# 破棄する前に確認すること:
#   - コンテナレジストリも破棄対象に入る (中のイメージごと消える)
#   - ルータを作り直すと VIP が変わることがある (DNS の貼り直しが要る)
#   - DB のデータは消える

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${script_dir}"

image_tag="${IMAGE_TAG:-$(git -C "${script_dir}" rev-parse HEAD)}"
: "${TF_VAR_sakuravel_backend_image_name:=intern2026-app-backend:${image_tag}}"
export TF_VAR_sakuravel_backend_image_name

api_root="${APPRUN_DEDICATED_API_URL:-https://secure.sakura.ad.jp/cloud/api/apprun-dedicated/1.0}"
api_root="${api_root%/}"

read_tfvar() {
  sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\"\([^\"]*\)\".*/\1/p" secret.auto.tfvars 2>/dev/null | head -1
}
: "${SAKURA_ACCESS_TOKEN:=$(read_tfvar sakura_access_token)}"
: "${SAKURA_ACCESS_TOKEN_SECRET:=$(read_tfvar sakura_access_token_secret)}"

if [[ -z "${SAKURA_ACCESS_TOKEN}" || -z "${SAKURA_ACCESS_TOKEN_SECRET}" ]]; then
  echo "SAKURA_ACCESS_TOKEN / SAKURA_ACCESS_TOKEN_SECRET を設定してください" >&2
  exit 1
fi

echo "==> 1/2 アプリケーションを無効化"
for output in backend_application_id frontend_application_id; do
  app="$(terraform output -raw "${output}" 2>/dev/null || true)"
  [[ -n "${app}" ]] || { echo "    ${output} は未作成、スキップ"; continue; }
  curl --fail --silent --show-error --retry 3 --retry-delay 1 \
    --user "${SAKURA_ACCESS_TOKEN}:${SAKURA_ACCESS_TOKEN_SECRET}" \
    --header 'Content-Type: application/json' \
    --header 'X-Requested-With: XMLHttpRequest' \
    --request PUT --data '{"activeVersion":null}' \
    "${api_root}/applications/${app}" >/dev/null
  echo "    ${app} を無効化"
done

echo "==> 2/2 destroy"
log="$(mktemp)"
trap 'rm -f "${log}"' EXIT

# 状況によって文言が変わるため複数を見る。terraform のログには version の ID
# (不正な UTF-8) が混ざるので grep には -a が要る。
retryable='in desired state|currently running|deployed on nodes|currently active'

for attempt in $(seq 1 30); do
  if terraform destroy -auto-approve -input=false "$@" >"${log}" 2>&1; then
    grep -aE 'Destroy complete' "${log}" || true
    echo "完了: すべて破棄しました"
    exit 0
  fi

  if ! grep -qaE "${retryable}" "${log}"; then
    echo "リトライしても解消しないエラーです:" >&2
    cat "${log}" >&2
    exit 1
  fi

  echo "    コンテナの解放待ち (${attempt}/30)"
  sleep 25
done

echo "解放されませんでした:" >&2
cat "${log}" >&2
exit 1
