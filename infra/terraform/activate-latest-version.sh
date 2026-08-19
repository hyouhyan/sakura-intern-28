#!/usr/bin/env bash

# AppRun 専有型アプリケーションの最新バージョンを有効化する。
#
#   SAKURA_ACCESS_TOKEN=... \
#   SAKURA_ACCESS_TOKEN_SECRET=... \
#   ./activate-latest-version.sh <application-id>
#
# APPRUN_APPLICATION_ID を設定して application-id を省略することもできる。
# API の接続先を変更する場合は APPRUN_DEDICATED_API_URL を設定する。

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  SAKURA_ACCESS_TOKEN=... SAKURA_ACCESS_TOKEN_SECRET=... \
    ./activate-latest-version.sh <application-id>

Environment variables:
  APPRUN_APPLICATION_ID          application ID when the argument is omitted
  APPRUN_DEDICATED_API_URL       API root URL (default: the production API)
  APPRUN_VERSION_PAGE_SIZE       number of versions fetched per request (default: 100)
EOF
}

die() {
  printf 'エラー: %s\n' "$*" >&2
  exit 1
}

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
esac

if (( $# > 1 )); then
  usage >&2
  exit 2
fi

application_id="${1:-${APPRUN_APPLICATION_ID:-}}"
[[ -n "${application_id}" ]] || {
  usage >&2
  exit 2
}

# UUID が想定される値だが、API のモックなどでも使えるよう形式は限定しない。
# URL のパスを壊す文字だけ拒否する。
if [[ "${application_id}" == */* || "${application_id}" =~ [[:space:]] ]]; then
  die "application ID に不正な文字が含まれています"
fi

command -v curl >/dev/null 2>&1 || die "curl が必要です"
command -v jq >/dev/null 2>&1 || die "jq が必要です"

access_token="${SAKURA_ACCESS_TOKEN:-}"
access_token_secret="${SAKURA_ACCESS_TOKEN_SECRET:-}"
[[ -n "${access_token}" ]] || die "SAKURA_ACCESS_TOKEN を設定してください"
[[ -n "${access_token_secret}" ]] || die "SAKURA_ACCESS_TOKEN_SECRET を設定してください"

api_root="${APPRUN_DEDICATED_API_URL:-https://secure.sakura.ad.jp/cloud/api/apprun-dedicated/1.0}"
api_root="${api_root%/}"
page_size="${APPRUN_VERSION_PAGE_SIZE:-100}"
[[ "${page_size}" =~ ^[1-9][0-9]*$ ]] || die "APPRUN_VERSION_PAGE_SIZE は正の整数にしてください"

# UUID 以外の ID も安全に URL のパスへ埋め込めるようエスケープする。
encoded_application_id="$(jq -rn --arg id "${application_id}" '$id | @uri')"
versions_url="${api_root}/applications/${encoded_application_id}/versions"
application_url="${api_root}/applications/${encoded_application_id}"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT
versions_file="${tmp_dir}/versions"
: > "${versions_file}"

list_versions() {
  local cursor="${1:-}"
  local -a curl_args=(
    --fail
    --silent
    --show-error
    --retry 3
    --retry-delay 1
    --user "${access_token}:${access_token_secret}"
    --header 'Accept: application/json'
    --get "${versions_url}"
    --data-urlencode "maxItems=${page_size}"
  )

  if [[ -n "${cursor}" ]]; then
    curl_args+=(--data-urlencode "cursor=${cursor}")
  fi

  curl "${curl_args[@]}"
}

cursor=""
page=0
while :; do
  page=$((page + 1))
  response="$(list_versions "${cursor}")" || die "version 一覧の取得に失敗しました (page=${page})"

  if ! jq -e '
      (.versions | type) == "array"
      and ((.nextCursor == null) or ((.nextCursor | type) == "number"))
      and all(.versions[]; (.version | type) == "number" and .version >= 0)
    ' <<<"${response}" >/dev/null; then
    die "version 一覧のレスポンス形式が不正です (page=${page})"
  fi

  jq -r '.versions[] | .version' <<<"${response}" >>"${versions_file}"
  next_cursor="$(jq -r '.nextCursor // empty' <<<"${response}")"

  [[ -n "${next_cursor}" ]] || break
  [[ "${next_cursor}" != "${cursor}" ]] || die "version 一覧のページネーションが進みません"
  cursor="${next_cursor}"
done

latest_version="$(jq -Rsr '
    split("\n")
    | map(select(length > 0) | tonumber)
    | if length == 0 then error("version が存在しません") else max end
  ' "${versions_file}")" || die "有効な version が見つかりません"

echo "application ${application_id} の最新 version は ${latest_version} です"
echo "version ${latest_version} を active にします"

if ! curl \
  --fail \
  --silent \
  --show-error \
  --retry 3 \
  --retry-delay 1 \
  --user "${access_token}:${access_token_secret}" \
  --header 'Accept: application/json' \
  --header 'Content-Type: application/json' \
  --header 'X-Requested-With: XMLHttpRequest' \
  --request PUT \
  --data "{\"activeVersion\":${latest_version}}" \
  "${application_url}" \
  >/dev/null; then
  die "version ${latest_version} の有効化に失敗しました"
fi

echo "完了: application ${application_id} / active version ${latest_version}"
