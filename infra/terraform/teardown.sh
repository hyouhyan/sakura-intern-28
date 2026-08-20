#!/usr/bin/env bash
# すべて破棄する。
#
# アクティブな version は削除できないため、先に AppRun API で無効化してから
# terraform destroy を回す。無効化直後はコンテナがノード上に残っていて
# 400 になるので、解消するまでリトライする。
#
#   ENABLE_TLS=true ./teardown.sh [terraform に渡す追加オプション]
#
# 破棄する前に確認すること:
#   - コンテナレジストリも破棄対象に入る (中のイメージごと消える)
#   - ルータを作り直すと VIP が変わることがある (DNS の貼り直しが要る)
#   - DB のデータは消える
#
# deactivate-applications.sh とは役割が違う。あちらは稼働を続ける前提で
# ASG / LB を作り直すためのもので、terraform output が揃っていないと動かない。
# こちらは作りかけの環境も片付けられるよう、output の欠けを黙って読み飛ばす。

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/../.." && pwd)"
cd "${script_dir}"

# API トークンは未設定のときだけ .env から補う (deploy.sh と同じ扱い)。
token_override="${SAKURA_ACCESS_TOKEN+x}"
token_value="${SAKURA_ACCESS_TOKEN-}"
secret_override="${SAKURA_ACCESS_TOKEN_SECRET+x}"
secret_value="${SAKURA_ACCESS_TOKEN_SECRET-}"

if [[ -f "${repo_root}/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "${repo_root}/.env"
  set +a
fi

[[ "${token_override}" != x ]] || export SAKURA_ACCESS_TOKEN="${token_value}"
[[ "${secret_override}" != x ]] || export SAKURA_ACCESS_TOKEN_SECRET="${secret_value}"

if [[ -z "${SAKURA_ACCESS_TOKEN:-}" || -z "${SAKURA_ACCESS_TOKEN_SECRET:-}" ]]; then
  echo "エラー: SAKURA_ACCESS_TOKEN と SAKURA_ACCESS_TOKEN_SECRET を設定してください" >&2
  exit 1
fi

# destroy でも変数はすべて解決される。enable_tls には既定値がないので、
# 明示されていなければここで止める (apply 側と同じ約束)。
case "${ENABLE_TLS:-}" in
  true|false) ;;
  *)
    echo "エラー: ENABLE_TLS=true または ENABLE_TLS=false をコマンド実行時に明示してください" >&2
    exit 1
    ;;
esac
export TF_VAR_enable_tls="${ENABLE_TLS}"

image_tag="${IMAGE_TAG:-$(git -C "${script_dir}" rev-parse HEAD)}"
export TF_VAR_sakuravel_backend_image_name="intern2026-app-backend:${image_tag}"
export TF_VAR_sakura_access_token="${SAKURA_ACCESS_TOKEN}"
export TF_VAR_sakura_access_token_secret="${SAKURA_ACCESS_TOKEN_SECRET}"

api_root="${APPRUN_DEDICATED_API_URL:-https://secure.sakura.ad.jp/cloud/api/apprun-dedicated/1.0}"
api_root="${api_root%/}"

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
