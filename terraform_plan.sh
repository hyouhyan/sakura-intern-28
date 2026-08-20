#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
image_tag="${IMAGE_TAG:-$(git -C "${script_dir}" rev-parse HEAD)}"

export TF_VAR_sakuravel_backend_image_name="intern2026-app-backend:${image_tag}"

common_var_args=()
if [[ -f "${script_dir}/infra/common.tfvars" ]]; then
  common_var_args=(-var-file=../common.tfvars)
fi

terraform -chdir="${script_dir}/infra/terraform" plan \
  "${common_var_args[@]}" \
  "$@"
