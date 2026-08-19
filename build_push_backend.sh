#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
registry_host="${REGISTRY_HOST}"
image_tag="${IMAGE_TAG:-${GITHUB_SHA:-$(git -C "${script_dir}" rev-parse HEAD)}}"
image="${registry_host}/intern2026-app-backend:${image_tag}"

echo "==> Backend imageをbuildしてpushします"
echo "    image: ${image}"

docker buildx build \
  --platform linux/amd64 \
  --tag "${image}" \
  --push \
  "${script_dir}/app/backend"

echo "完了: ${image}"
