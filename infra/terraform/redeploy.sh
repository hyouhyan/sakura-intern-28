#!/usr/bin/env bash
# nginx の version を作り直して有効化する。
#
# AppRun の version は不変リソースで、しかもアクティブなものは削除できない。
# そのため image や cmd を変えるたびに以下の 3 段階が必要になる:
#   1. application の active_version を null にする (無効化)
#   2. 古い version を破棄して新しい version を作る
#   3. 新しい version 番号で有効化する
#
#   ./redeploy.sh [terraform に渡す追加オプション]

set -euo pipefail

echo "==> 1/3 現在のバージョンを無効化"
terraform apply -auto-approve -input=false -var-file=deactivate.tfvars \
  -target=sakura_apprun_dedicated_application.nginx "$@" >/dev/null

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

  if ! grep -q "in desired state" "${log}"; then
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

version="$(terraform output -raw nginx_version)"

echo "==> 3/3 バージョン ${version} を有効化"
terraform apply -auto-approve -input=false -var "nginx_active_version=${version}" "$@" >/dev/null

echo "完了: version ${version} / $(terraform output -raw lb_endpoint)"
