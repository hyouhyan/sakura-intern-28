#!/usr/bin/env bash

# backend / frontend の active version を解除し、全ワーカーノードから
# desired container が解放されるまで待つ。

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/../.." && pwd)"

if [[ -f "${repo_root}/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "${repo_root}/.env"
  set +a
fi

case "${1:-}" in
  -h|--help)
    echo "Usage: $0"
    exit 0
    ;;
  "") ;;
  *)
    echo "Usage: $0" >&2
    exit 2
    ;;
esac

: "${SAKURA_ACCESS_TOKEN:?SAKURA_ACCESS_TOKEN を設定してください}"
: "${SAKURA_ACCESS_TOKEN_SECRET:?SAKURA_ACCESS_TOKEN_SECRET を設定してください}"

api_root="${APPRUN_DEDICATED_API_URL:-https://secure.sakura.ad.jp/cloud/api/apprun-dedicated/1.0}"
api_root="${api_root%/}"
backend_app="$(terraform -chdir="${script_dir}" output -raw backend_application_id)"
frontend_app="$(terraform -chdir="${script_dir}" output -raw frontend_application_id)"

deactivate() {
  local application_id="$1"
  curl --fail --silent --show-error --retry 3 --retry-delay 1 \
    --user "${SAKURA_ACCESS_TOKEN}:${SAKURA_ACCESS_TOKEN_SECRET}" \
    --header 'Content-Type: application/json' \
    --header 'X-Requested-With: XMLHttpRequest' \
    --request PUT \
    --data '{"activeVersion":null}' \
    "${api_root}/applications/${application_id}" >/dev/null
}

desired_container_count() {
  local application_id="$1"
  curl --fail --silent --show-error --retry 3 --retry-delay 1 \
    --user "${SAKURA_ACCESS_TOKEN}:${SAKURA_ACCESS_TOKEN_SECRET}" \
    --header 'Accept: application/json' \
    "${api_root}/applications/${application_id}/containers" \
    | jq '[.nodes[].desired.containers[]?] | length'
}

echo "backend / frontend の active version を解除します"
deactivate "${backend_app}"
deactivate "${frontend_app}"

for attempt in $(seq 1 30); do
  backend_count="$(desired_container_count "${backend_app}")"
  frontend_count="$(desired_container_count "${frontend_app}")"
  if [[ "${backend_count}" -eq 0 && "${frontend_count}" -eq 0 ]]; then
    echo "全コンテナの解放を確認しました"
    exit 0
  fi

  if [[ "${attempt}" -eq 30 ]]; then
    echo "エラー: コンテナが時間内に解放されませんでした" >&2
    exit 1
  fi

  echo "コンテナの解放待ち (${attempt}/30)"
  sleep 10
done
