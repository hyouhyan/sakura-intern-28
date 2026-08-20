#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
registry_host="${REGISTRY_HOST}"
image_tag="${IMAGE_TAG:-${GITHUB_SHA:-$(git -C "${script_dir}" rev-parse HEAD)}}"
# 入手元は別チームのレジストリで、資格情報がないと pull できない。
# 手元に控えがある場合は FRONTEND_SOURCE_IMAGE で差し替える。
source_image="${FRONTEND_SOURCE_IMAGE:-intern22.sakuracr.jp/intern2026-app-frontend:latest}"
target_image="${registry_host}/intern2026-app-frontend:${image_tag}"

echo "==> Frontend imageをpullします"
echo "    source: ${source_image}"
docker pull --platform linux/amd64 "${source_image}"

echo "==> Frontend imageをtag付けしてpushします"
echo "    target: ${target_image}"
docker tag "${source_image}" "${target_image}"
docker push "${target_image}"

echo "    source digest:"
docker image inspect "${source_image}" --format '{{index .RepoDigests 0}}'
echo "完了: ${target_image}"
