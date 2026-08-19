#!/usr/bin/env bash
# bench.sh <URL> [追加のcurlオプション...]
# 環境変数 N でリクエスト数を上書き可能（デフォルト100）。
url="$1"; shift
n="${N:-100}"
for i in $(seq 1 "$n"); do
  curl -s -o /dev/null -w '%{time_total}\n' "$url" "$@"
done | sort -n | awk -v n="$n" '
  { a[NR]=$1; sum+=$1 }
  END {
    printf "count=%d avg=%.4f p50=%.4f p95=%.4f p99=%.4f max=%.4f\n",
      n, sum/n, a[int(n*0.50)+1], a[int(n*0.95)+1], a[int(n*0.99)+1], a[n]
  }'