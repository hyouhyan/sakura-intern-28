#!/usr/bin/env bash

# Terraform で新しい version を作成し、apply 成功後に AppRun API で有効化する。
# 稼働中 version は事前に無効化しない。

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
terraform_dir="${script_dir}/infra/terraform"

# APIトークンは未設定の場合に.envから読み込む。ENABLE_TLSはデプロイごとに
# コマンド環境で明示し、.envの値は使用しない。
token_override="${SAKURA_ACCESS_TOKEN+x}"
token_value="${SAKURA_ACCESS_TOKEN-}"
secret_override="${SAKURA_ACCESS_TOKEN_SECRET+x}"
secret_value="${SAKURA_ACCESS_TOKEN_SECRET-}"
tls_override="${ENABLE_TLS+x}"
tls_value="${ENABLE_TLS-}"

if [[ -f "${script_dir}/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "${script_dir}/.env"
  set +a
fi

[[ "${token_override}" != x ]] || export SAKURA_ACCESS_TOKEN="${token_value}"
[[ "${secret_override}" != x ]] || export SAKURA_ACCESS_TOKEN_SECRET="${secret_value}"
if [[ "${tls_override}" == x ]]; then
  export ENABLE_TLS="${tls_value}"
else
  unset ENABLE_TLS
fi

# CIではTerraform入力用のTF_VAR_*を正とし、シェルが必要とする名前へ変換する。
export SAKURA_ACCESS_TOKEN="${SAKURA_ACCESS_TOKEN:-${TF_VAR_sakura_access_token:-}}"
export SAKURA_ACCESS_TOKEN_SECRET="${SAKURA_ACCESS_TOKEN_SECRET:-${TF_VAR_sakura_access_token_secret:-}}"
export ENABLE_TLS="${ENABLE_TLS:-${TF_VAR_enable_tls:-}}"

if [[ -z "${SAKURA_ACCESS_TOKEN:-}" || -z "${SAKURA_ACCESS_TOKEN_SECRET:-}" ]]; then
  echo "エラー: SAKURA_ACCESS_TOKEN と SAKURA_ACCESS_TOKEN_SECRET を設定してください" >&2
  exit 1
fi

case "${ENABLE_TLS:-}" in
  true|false) ;;
  *)
    echo "エラー: ENABLE_TLS=true または ENABLE_TLS=false をコマンド実行時に明示してください" >&2
    exit 1
    ;;
esac

"${script_dir}/terraform_apply.sh" "$@"

echo "デプロイが完了しました"
echo "  frontend: $(terraform -chdir="${terraform_dir}" output -raw frontend_url)"
echo "  backend : $(terraform -chdir="${terraform_dir}" output -raw backend_url)"
