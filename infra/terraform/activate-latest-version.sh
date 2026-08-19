#!/usr/bin/env bash

# AppRun 専有型アプリケーションの指定バージョン（省略時は最新）を有効化する。
#
#   SAKURA_ACCESS_TOKEN=... \
#   SAKURA_ACCESS_TOKEN_SECRET=... \
#   ./activate-latest-version.sh <application-id> [version]
#
# APPRUN_APPLICATION_ID を設定して application-id を省略することもできる。
# API の接続先を変更する場合は APPRUN_DEDICATED_API_URL を設定する。

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/../.." && pwd)"
token_override="${SAKURA_ACCESS_TOKEN+x}"
token_value="${SAKURA_ACCESS_TOKEN-}"
secret_override="${SAKURA_ACCESS_TOKEN_SECRET+x}"
secret_value="${SAKURA_ACCESS_TOKEN_SECRET-}"

if [[ -f "${repo_root}/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "${repo_root}/.env"
  set +a
fi

[[ "${token_override}" != x ]] || export SAKURA_ACCESS_TOKEN="${token_value}"
[[ "${secret_override}" != x ]] || export SAKURA_ACCESS_TOKEN_SECRET="${secret_value}"

usage() {
  cat <<'EOF'
Usage:
  SAKURA_ACCESS_TOKEN=... SAKURA_ACCESS_TOKEN_SECRET=... \
    ./activate-latest-version.sh <application-id> [version]

Environment variables:
  APPRUN_APPLICATION_ID          application ID when the argument is omitted
  APPRUN_DEDICATED_API_URL       API root URL (default: the production API)
  APPRUN_VERSION_PAGE_SIZE       number of versions fetched per request (default: 100)
  APPRUN_VERSION_RELEASE_RETRIES old version release checks (default: 20)
  APPRUN_VERSION_RELEASE_INTERVAL seconds between release checks (default: 20)
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

if (( $# > 2 )); then
  usage >&2
  exit 2
fi

application_id="${1:-${APPRUN_APPLICATION_ID:-}}"
requested_version="${2:-}"
[[ -n "${application_id}" ]] || {
  usage >&2
  exit 2
}

# UUID が想定される値だが、API のモックなどでも使えるよう形式は限定しない。
# URL のパスを壊す文字だけ拒否する。
if [[ "${application_id}" == */* || "${application_id}" =~ [[:space:]] ]]; then
  die "application ID に不正な文字が含まれています"
fi

if [[ -n "${requested_version}" && ! "${requested_version}" =~ ^[1-9][0-9]*$ ]]; then
  die "version は正の整数で指定してください"
fi

command -v curl >/dev/null 2>&1 || die "curl が必要です"
command -v jq >/dev/null 2>&1 || die "jq が必要です"

access_token="${SAKURA_ACCESS_TOKEN:-}"
access_token_secret="${SAKURA_ACCESS_TOKEN_SECRET:-}"
[[ -n "${access_token}" ]] || die "SAKURA_ACCESS_TOKEN を設定してください"
[[ -n "${access_token_secret}" ]] || die "SAKURA_ACCESS_TOKEN_SECRET を設定してください"

api_root="${APPRUN_DEDICATED_API_URL:-https://secure.sakura.ad.jp/cloud/api/apprun-dedicated/1.0}"
api_root="${api_root%/}"
# API 側の maxItems の上限は 30。これを超えると
# "int: value 100 greater than 30" で 400 になる。
page_size="${APPRUN_VERSION_PAGE_SIZE:-30}"
[[ "${page_size}" =~ ^[1-9][0-9]*$ ]] || die "APPRUN_VERSION_PAGE_SIZE は正の整数にしてください"
(( page_size <= 30 )) || die "APPRUN_VERSION_PAGE_SIZE は 30 以下にしてください (API の上限)"

# UUID 以外の ID も安全に URL のパスへ埋め込めるようエスケープする。
encoded_application_id="$(jq -rn --arg id "${application_id}" '$id | @uri')"
versions_url="${api_root}/applications/${encoded_application_id}/versions"
application_url="${api_root}/applications/${encoded_application_id}"

previous_version="$(curl \
  --fail --silent --show-error --retry 3 --retry-delay 1 \
  --user "${access_token}:${access_token_secret}" \
  --header 'Accept: application/json' \
  "${application_url}" | jq -r '.application.activeVersion // empty')" \
  || die "現在のactive versionの取得に失敗しました"

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

target_version="${requested_version:-${latest_version}}"
grep -qx "${target_version}" "${versions_file}" \
  || die "version ${target_version} はapplication ${application_id}に存在しません"

echo "application ${application_id} の version ${target_version} を active にします"

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
  --data "{\"activeVersion\":${target_version}}" \
  "${application_url}" \
  >/dev/null; then
  die "version ${target_version} の有効化に失敗しました"
fi

if [[ -n "${previous_version}" && "${previous_version}" != "${target_version}" ]]; then
  release_retries="${APPRUN_VERSION_RELEASE_RETRIES:-20}"
  release_interval="${APPRUN_VERSION_RELEASE_INTERVAL:-20}"
  [[ "${release_retries}" =~ ^[1-9][0-9]*$ ]] || die "APPRUN_VERSION_RELEASE_RETRIES は正の整数にしてください"
  [[ "${release_interval}" =~ ^[1-9][0-9]*$ ]] || die "APPRUN_VERSION_RELEASE_INTERVAL は正の整数にしてください"

  containers_url="${application_url}/containers"

  for ((attempt = 1; attempt <= release_retries; attempt++)); do
    containers="$(curl \
      --fail --silent --show-error --retry 3 --retry-delay 1 \
      --user "${access_token}:${access_token_secret}" \
      --header 'Accept: application/json' \
      "${containers_url}")" || die "applicationのdesired状態取得に失敗しました"

    if jq -e --argjson target "${target_version}" '
        [.nodes[].desired.containers[]?.applicationVersion] as $versions
        | ($versions | length) > 0
        and all($versions[]; . == $target)
      ' <<<"${containers}" >/dev/null; then
      echo "全ノードのdesired versionが ${target_version} に切り替わりました"
      break
    fi

    if (( attempt == release_retries )); then
      die "旧version ${previous_version} のコンテナが解放されませんでした"
    fi

    echo "desired version ${target_version} への切り替え待ち (${attempt}/${release_retries})"
    sleep "${release_interval}"
  done

  encoded_previous_version="$(jq -rn --arg version "${previous_version}" '$version | @uri')"
  previous_version_url="${versions_url}/${encoded_previous_version}"
  delete_response="${tmp_dir}/delete-response"

  for ((attempt = 1; attempt <= release_retries; attempt++)); do
    status="$(curl \
      --silent --show-error \
      --output "${delete_response}" \
      --write-out '%{http_code}' \
      --user "${access_token}:${access_token_secret}" \
      --header 'Accept: application/json' \
      --header 'X-Requested-With: XMLHttpRequest' \
      --request DELETE \
      "${previous_version_url}")" || die "旧version ${previous_version} の削除リクエストに失敗しました"

    case "${status}" in
      200|204|404)
        echo "旧version ${previous_version} の削除を確認しました"
        break
        ;;
      400)
        if (( attempt == release_retries )); then
          die "旧version ${previous_version} を削除できませんでした"
        fi
        echo "旧version ${previous_version} のノード解放待ち (${attempt}/${release_retries})"
        sleep "${release_interval}"
        ;;
      *)
        die "旧version ${previous_version} の削除に失敗しました (HTTP ${status})"
        ;;
    esac
  done
fi

echo "完了: application ${application_id} / active version ${target_version}"
