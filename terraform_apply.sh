#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# deploy.shを経由しない-target適用でも.envを利用する。
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
[[ "${tls_override}" != x ]] || export ENABLE_TLS="${tls_value}"

image_tag="${IMAGE_TAG:-$(git -C "${script_dir}" rev-parse HEAD)}"

export TF_VAR_sakuravel_backend_image_name="intern2026-app-backend:${image_tag}"

# 運用時に使う環境変数名をTerraformの入力変数へ変換する。
# 値が未設定の場合は、Terraform側のdefaultまたはtfvarsを使用する。
[[ -z "${SAKURA_ACCESS_TOKEN:-}" ]] || export TF_VAR_sakura_access_token="${SAKURA_ACCESS_TOKEN}"
[[ -z "${SAKURA_ACCESS_TOKEN_SECRET:-}" ]] || export TF_VAR_sakura_access_token_secret="${SAKURA_ACCESS_TOKEN_SECRET}"
[[ -z "${ENABLE_TLS:-}" ]] || export TF_VAR_enable_tls="${ENABLE_TLS}"

terraform -chdir="${script_dir}/infra/terraform" apply "$@"
