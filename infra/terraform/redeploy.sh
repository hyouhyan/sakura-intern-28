#!/usr/bin/env bash
# backend / frontend の version を作り直して有効化する。
#
# AppRun の version は不変リソースで、しかもアクティブなものは削除できない。
# そのため image や env_vars を変えるたびに以下の 3 段階が必要になる:
#   1. application の activeVersion を null にする (無効化)
#   2. 古い version を破棄して新しい version を作る
#   3. 新しい version を有効化する
#
# 有効化 / 無効化は terraform ではなく AppRun 専有型 API で行う。
# application.tf が active_version を ignore_changes にしており、
# terraform 側からは操作できないため (65217c8 以降の設計)。
# 有効化は activate-latest-version.sh に委譲している。
#
#   ./redeploy.sh [terraform に渡す追加オプション]
#
# 認証情報は SAKURA_ACCESS_TOKEN / SAKURA_ACCESS_TOKEN_SECRET を使う。
# 未設定なら secret.auto.tfvars から読む。

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${script_dir}"

# terraform_apply.sh と同じ規則でイメージのタグを決める。
# ここで設定しないと、内部の terraform apply が
# "No value for required variable sakuravel_backend_image_name" で失敗する。
image_tag="${IMAGE_TAG:-$(git -C "${script_dir}" rev-parse HEAD)}"
: "${TF_VAR_sakuravel_backend_image_name:=intern2026-app-backend:${image_tag}}"
export TF_VAR_sakuravel_backend_image_name

api_root="${APPRUN_DEDICATED_API_URL:-https://secure.sakura.ad.jp/cloud/api/apprun-dedicated/1.0}"
api_root="${api_root%/}"

read_tfvar() {
  sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\"\([^\"]*\)\".*/\1/p" secret.auto.tfvars 2>/dev/null | head -1
}
: "${SAKURA_ACCESS_TOKEN:=$(read_tfvar sakura_access_token)}"
: "${SAKURA_ACCESS_TOKEN_SECRET:=$(read_tfvar sakura_access_token_secret)}"
export SAKURA_ACCESS_TOKEN SAKURA_ACCESS_TOKEN_SECRET

if [[ -z "${SAKURA_ACCESS_TOKEN}" || -z "${SAKURA_ACCESS_TOKEN_SECRET}" ]]; then
  echo "SAKURA_ACCESS_TOKEN / SAKURA_ACCESS_TOKEN_SECRET を設定してください" >&2
  exit 1
fi

backend_app="$(terraform output -raw backend_application_id)"
frontend_app="$(terraform output -raw frontend_application_id)"

deactivate_app() {
  curl --fail --silent --show-error --retry 3 --retry-delay 1 \
    --user "${SAKURA_ACCESS_TOKEN}:${SAKURA_ACCESS_TOKEN_SECRET}" \
    --header 'Content-Type: application/json' \
    --header 'X-Requested-With: XMLHttpRequest' \
    --request PUT --data '{"activeVersion":null}' \
    "${api_root}/applications/$1" >/dev/null
}

echo "==> 1/3 現在のバージョンを無効化"
deactivate_app "${backend_app}"
deactivate_app "${frontend_app}"

echo "==> 2/3 新しいバージョンを作成"
log="$(mktemp)"
trap 'rm -f "${log}"' EXIT

# 無効化の直後はコンテナがまだノード上に残っており、古い version を消そうとすると
# 400 になる。時間で解消するのでリトライする。文言は状況によって変わるため
# 複数を見る。一方 "Target port is duplicated" のような設定不備は何度やっても
# 直らないので、リトライせず即座に失敗させる。
retryable='in desired state|currently running|deployed on nodes|currently active'

for attempt in $(seq 1 20); do
  if terraform apply -auto-approve -input=false "$@" >"${log}" 2>&1; then
    break
  fi

  # terraform のログには version リソースの ID (不正な UTF-8 のバイト列) が
  # 混ざるため、-a を付けないと grep がバイナリ扱いしてマッチを報告しない。
  # その結果、リトライすれば解消するエラーを恒久的な失敗と誤判定してしまう。
  if ! grep -qaE "${retryable}" "${log}"; then
    echo "リトライしても解消しないエラーです:" >&2
    cat "${log}" >&2
    exit 1
  fi

  if [ "${attempt}" -eq 20 ]; then
    echo "旧バージョンを解放できませんでした:" >&2
    cat "${log}" >&2
    exit 1
  fi

  echo "    旧バージョンの解放待ち (${attempt}/20)"
  sleep 20
done

echo "==> 3/3 バージョンを有効化"
./activate-latest-version.sh "${backend_app}"
./activate-latest-version.sh "${frontend_app}"

echo "完了:"
echo "  frontend: $(terraform output -raw frontend_url)"
echo "  backend : $(terraform output -raw backend_url)"

# TLS を有効にしている場合、Let's Encrypt の証明書発行に数分かかる。
# 発行が終わるまで 443 は繋がらないので、待ってから check-lb.sh を叩くこと。
