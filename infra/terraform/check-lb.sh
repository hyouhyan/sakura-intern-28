#!/usr/bin/env bash
# LB がバックエンドの nginx にトラフィックを振り分けているか確認する。
# 各コンテナは index.html に自分のホスト名を書き出しているので、
# 応答をカウントすれば分散の様子がわかる。
#
#   ./check-lb.sh [リクエスト数]

set -euo pipefail

count="${1:-30}"
vip="$(terraform output -raw lb_vip)"

echo "LB VIP: ${vip} に ${count} 回リクエストします"
echo

for _ in $(seq "${count}"); do
  # nginx の return は末尾に改行を付けないので echo で補って 1 行にする
  curl -s --max-time 5 "http://${vip}/" || printf "request failed"
  echo
done | sort | uniq -c | sort -rn
