#!/usr/bin/env bash
# LB 経由で frontend / backend に到達できるか、TLS 終端が効いているかを確認する。
#
#   ./check-lb.sh

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

frontend_url="$(terraform -chdir="${script_dir}" output -raw frontend_url)"
backend_url="$(terraform -chdir="${script_dir}" output -raw backend_url)"
vip="$(terraform -chdir="${script_dir}" output -raw lb_vip)"

echo "LB VIP: ${vip}"
echo

check() {
  local name="$1" url="$2"
  printf '%-10s %s\n' "${name}" "${url}"

  # -sS でエラーだけ出す。--max-time は LE 発行待ちで固まらないように短め。
  local code
  code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "${url}" 2>&1)" || {
    printf '  => 接続失敗\n\n'
    return
  }
  printf '  => HTTP %s\n' "${code}"

  # https のときだけ証明書の発行者と対象を出す。
  # Let's Encrypt が終端していれば issuer が R** / E** になる。
  if [[ "${url}" == https://* ]]; then
    local host="${url#https://}"
    host="${host%%/*}"
    echo | openssl s_client -connect "${host}:443" -servername "${host}" 2>/dev/null \
      | openssl x509 -noout -subject -issuer -dates 2>/dev/null \
      | sed 's/^/  /' || echo "  => 証明書を取得できませんでした (LE の発行待ちかも)"
  fi
  echo
}

check frontend "${frontend_url}"
check backend  "${backend_url}/trending"
