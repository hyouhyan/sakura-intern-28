#!/usr/bin/env bash

# ASG / LB の不変属性を変更するときのデプロイ。
# 一時停止を伴い、version / LB / ASG だけを削除してから再作成する。

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export ENABLE_TLS="${ENABLE_TLS:-${TF_VAR_enable_tls:-}}"

case "${1:-}" in
  -h|--help)
    cat <<'EOF'
Usage:
  ENABLE_TLS=true IMAGE_TAG=<tag> ./deploy-recreate-runtime.sh [-auto-approve]

ASGまたはLBの置換がplanに含まれる場合だけ使用します。
DB、cluster、internet、private vSwitchは削除対象にしません。
EOF
    exit 0
    ;;
esac

case "${ENABLE_TLS:-}" in
  true|false) ;;
  *)
    echo "エラー: ENABLE_TLS=true または ENABLE_TLS=false をコマンド実行時に明示してください" >&2
    exit 1
    ;;
esac

echo "==> 1/3 applicationを無効化してコンテナ解放を待機"
"${script_dir}/infra/terraform/deactivate-applications.sh"

echo "==> 2/3 version / LB / ASGを削除"
"${script_dir}/terraform_apply.sh" \
  -destroy \
  -input=false \
  -target=sakura_apprun_dedicated_version.backend \
  -target=sakura_apprun_dedicated_version.frontend \
  -target=sakura_apprun_dedicated_lb.main \
  -target=sakura_apprun_dedicated_auto_scaling_group.main \
  "$@"

echo "==> 3/3 現行構成を作成して新versionを有効化"
"${script_dir}/terraform_apply.sh" -input=false "$@"

echo "ランタイムの再作成が完了しました"
