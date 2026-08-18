#!/usr/bin/env bash
# bench_concurrent.sh <URL> [追加のcurlオプション...]
url="$1"; shift
n=200      # 総リクエスト数
c=10       # 同時実行数
start=$(date +%s.%N)
seq 1 "$n" | xargs -P "$c" -I{} \
  curl -s -o /dev/null -w '%{http_code} %{time_total}\n' "$url" "$@" \
  > /tmp/bench_results.txt
end=$(date +%s.%N)
total=$(echo "$end - $start" | bc)
awk -v total="$total" -v n="$n" '
  { split($0,a," "); t[NR]=a[2]; sum+=a[2] }
  END {
    asorta_n=asort(t)
    printf "n=%d total=%.2fs rps=%.2f avg=%.4f p50=%.4f p95=%.4f\n",
      n, total, n/total, sum/n, t[int(n*0.50)+1], t[int(n*0.95)+1]
  }' /tmp/bench_results.txt