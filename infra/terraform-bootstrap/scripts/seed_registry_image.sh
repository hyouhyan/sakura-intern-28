#!/usr/bin/env bash
# 配布元コンテナレジストリからイメージを取得し、自分たちのレジストリへ
# push し直す。infra/terraform-bootstrap の terraform_data.seed_registry_image
# から local-exec で呼び出される想定。
#
# 認証情報は環境変数経由でのみ受け取り、コマンドライン引数や標準出力には
# 一切出さない (docker login は --password-stdin を使用)。
set -euo pipefail

IMAGE_NAME="${1:?usage: $0 <image-name>}"

: "${SOURCE_REGISTRY_HOST:?SOURCE_REGISTRY_HOST is required}"
: "${SOURCE_REGISTRY_USERNAME:?SOURCE_REGISTRY_USERNAME is required}"
: "${SOURCE_REGISTRY_PASSWORD:?SOURCE_REGISTRY_PASSWORD is required}"
: "${DEST_REGISTRY_HOST:?DEST_REGISTRY_HOST is required}"
: "${DEST_REGISTRY_USERNAME:?DEST_REGISTRY_USERNAME is required}"
: "${DEST_REGISTRY_PASSWORD:?DEST_REGISTRY_PASSWORD is required}"

SRC_IMAGE="${SOURCE_REGISTRY_HOST}/${IMAGE_NAME}:latest"
DEST_IMAGE="${DEST_REGISTRY_HOST}/${IMAGE_NAME}:latest"

echo "==> seeding ${DEST_IMAGE} from ${SRC_IMAGE}"

printf '%s' "${SOURCE_REGISTRY_PASSWORD}" | docker login "${SOURCE_REGISTRY_HOST}" \
  --username "${SOURCE_REGISTRY_USERNAME}" --password-stdin

docker pull --platform linux/amd64 "${SRC_IMAGE}"

docker tag "${SRC_IMAGE}" "${DEST_IMAGE}"

printf '%s' "${DEST_REGISTRY_PASSWORD}" | docker login "${DEST_REGISTRY_HOST}" \
  --username "${DEST_REGISTRY_USERNAME}" --password-stdin

docker push "${DEST_IMAGE}"

echo "==> done: ${DEST_IMAGE}"
