#!/usr/bin/env bash
# backend / frontend の version を作り直して有効化する。
#
# AppRun の version は不変リソースで、しかもアクティブなものは削除できない。
# そのため image や env_vars を変えるたびに以下の 3 段階が必要になる:
#   1. application の active_version を null にする (無効化)
#   2. 古い version を破棄して新しい version を作る
#   3. 新しい version 番号で有効化する
#
#   ./redeploy.sh [terraform に渡す追加オプション]

set -euo pipefail

echo "==> 1/3 現在のバージョンを無効化"
terraform apply -auto-approve -input=false -var-file=deactivate.tfvars \
  -target=sakura_apprun_dedicated_application.backend \
  -target=sakura_apprun_dedicated_application.frontend "$@" >/dev/null

# 無効化の直後はコンテナがまだ desired 状態に残っており、
# 古い version を消そうとすると 400 "it is currently in desired state" になる。
# これは時間で解消するのでリトライする。
# 一方 "Target port is duplicated" のような設定不備は何度やっても直らないので、
# リトライせず即座に失敗させる。
echo "==> 2/3 新しいバージョンを作成"
log="$(mktemp)"
trap 'rm -f "${log}"' EXIT

for attempt in $(seq 1 20); do
  if terraform apply -auto-approve -input=false -var-file=deactivate.tfvars "$@" >"${log}" 2>&1; then
    break
  fi

  # terraform のログには version リソースの ID (不正な UTF-8 のバイト列) が
  # 混ざるため、-a を付けないと grep がバイナリ扱いしてマッチを報告しない。
  # その結果、リトライすれば解消するエラーを恒久的な失敗と誤判定してしまう。
  if ! grep -qa "in desired state" "${log}"; then
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

backend_version="$(terraform output -raw backend_version)"
frontend_version="$(terraform output -raw frontend_version)"

echo "==> 3/3 バージョンを有効化 (backend=${backend_version} / frontend=${frontend_version})"
terraform apply -auto-approve -input=false \
  -var "backend_active_version=${backend_version}" \
  -var "frontend_active_version=${frontend_version}" "$@" >/dev/null

echo "完了:"
echo "  frontend: $(terraform output -raw frontend_url)"
echo "  backend : $(terraform output -raw backend_url)"

# TLS を有効にしている場合、Let's Encrypt の証明書発行に数分かかる。
# 発行が終わるまで 443 は繋がらないので、待ってから check-lb.sh を叩くこと。
