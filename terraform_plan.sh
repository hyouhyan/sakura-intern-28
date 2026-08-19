#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
image_tag="${IMAGE_TAG:-$(git -C "${script_dir}" rev-parse HEAD)}"

export TF_VAR_sakuravel_backend_image_name="intern2026-app-backend:${image_tag}"

terraform -chdir="${script_dir}/infra/terraform" plan "$@"
