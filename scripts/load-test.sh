#!/usr/bin/env bash
# Dependency-light load test (bash + curl + xargs + awk).
#
# Usage:
#   ./scripts/load-test.sh -u http://my-alb.amazonaws.com [-p /api/work?ms=50] \
#                          [-n 2000] [-c 50] [-e 1] [-l 500]
#
#   -u  base URL (required)
#   -p  path to hit            (default /health)
#   -n  total requests         (default 1000)
#   -c  concurrent requests    (default 20)
#   -e  max allowed error %    (default 1)   -> non-zero exit if exceeded
#   -l  max allowed p95 in ms  (default 0 = disabled)
set -euo pipefail

URL=""; REQ_PATH="/health"; TOTAL=1000; CONC=20; MAX_ERR=1; MAX_P95=0

while getopts "u:p:n:c:e:l:h" opt; do
  case "$opt" in
    u) URL="$OPTARG" ;;
    p) REQ_PATH="$OPTARG" ;;
    n) TOTAL="$OPTARG" ;;
    c) CONC="$OPTARG" ;;
    e) MAX_ERR="$OPTARG" ;;
    l) MAX_P95="$OPTARG" ;;
    h|*) sed -n '2,15p' "$0"; exit 1 ;;
  esac
done
[[ -n "$URL" ]] || { echo "Error: -u <url> is required" >&2; exit 1; }
command -v curl >/dev/null || { echo "curl is required" >&2; exit 1; }

TARGET="${URL%/}${REQ_PATH}"
RESULTS="$(mktemp)"; trap 'rm -f "$RESULTS"' EXIT

echo "Target: $TARGET | requests: $TOTAL | concurrency: $CONC"
START=$(date +%s.%N)

# One URL per line -> xargs runs $CONC curls in parallel; each prints "<code> <seconds>"
awk -v n="$TOTAL" -v t="$TARGET" 'BEGIN { for (i = 0; i < n; i++) print t }' | xargs -P "$CONC" -n 1 \
  curl -s -o /dev/null --max-time 15 -w '%{http_code} %{time_total}\n' > "$RESULTS"

END=$(date +%s.%N)

# Portable stats (works with mawk/gawk/BSD awk): sort latencies externally, then pick percentiles.
read -r OK BAD < <(awk '{ if ($1 ~ /^[23]/) ok++; else bad++ } END { print ok+0, bad+0 }' "$RESULTS")
SORTED="$(mktemp)"; trap 'rm -f "$RESULTS" "$SORTED"' EXIT
awk '{ printf "%.3f\n", $2 * 1000 }' "$RESULTS" | sort -n > "$SORTED"

awk -v ok="$OK" -v bad="$BAD" -v start="$START" -v end="$END" -v max_err="$MAX_ERR" -v max_p95="$MAX_P95" '
  { t[NR] = $1; sum += $1 }
  END {
    n = NR; total = ok + bad; elapsed = end - start
    p50 = t[int(n * 0.50 + 0.5)]; p95 = t[int(n * 0.95 + 0.5)]; p99 = t[int(n * 0.99 + 0.5)]
    err = (total ? bad * 100 / total : 100)
    printf "\n--- Results ---\n"
    printf "Duration:        %.2f s\n", elapsed
    printf "Throughput:      %.1f req/s\n", total / elapsed
    printf "Success / Fail:  %d / %d (%.2f%% errors)\n", ok, bad, err
    printf "Latency (ms):    avg %.1f | p50 %.1f | p95 %.1f | p99 %.1f | max %.1f\n", sum / n, p50, p95, p99, t[n]
    if (err > max_err) { printf "FAIL: error rate %.2f%% > %s%%\n", err, max_err; exit 2 }
    if (max_p95 > 0 && p95 > max_p95) { printf "FAIL: p95 %.1f ms > %s ms\n", p95, max_p95; exit 3 }
    print "PASS"
  }
' "$SORTED"
