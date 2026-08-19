#!/usr/bin/env bash
# アプリケーションコンテナから DB アプライアンスへ、プライベート vSwitch
# 経由で到達できているか確認する。
#
# 各コンテナは起動時から 10 秒ごとに DB の TCP ポートへ接続を試み、
# 結果を /db-check で返している (application.tf の起動スクリプトを参照)。
# LB 越しに複数回叩いて、全コンテナが ok を返すことを確認する。
#
#   ./check-db.sh [リクエスト数]
#
# 出力例:
#   3 db: ok (192.168.1.30:3306) container_ip=192.168.1.100
#
# ng が返る場合に確認すること:
#   - terraform output private_net の app_nodes が
#     database.tf の source_ranges (db_private_net_allow_cidr) に含まれているか
#   - terraform output worker_nodes の addresses にプライベート側の IP があるか
#   - DB アプライアンスが起動済みか

set -euo pipefail

count="${1:-10}"
vip="$(terraform output -raw lb_vip)"

echo "LB VIP: ${vip} の /db-check に ${count} 回リクエストします"
echo

for _ in $(seq "${count}"); do
  curl -s --max-time 5 "http://${vip}/db-check" || printf "request failed\n"
done | sort | uniq -c | sort -rn
