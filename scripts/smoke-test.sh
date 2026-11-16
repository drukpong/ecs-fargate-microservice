#!/usr/bin/env bash
# Poll /health until it returns 200 or we give up. Used after each deploy.
# Usage: ./scripts/smoke-test.sh <base-url> [attempts] [sleep-seconds]
set -euo pipefail

BASE_URL="${1:?Usage: $0 <base-url> [attempts] [sleep-seconds]}"
ATTEMPTS="${2:-30}"
SLEEP="${3:-10}"

for ((i = 1; i <= ATTEMPTS; i++)); do
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "${BASE_URL%/}/health" || true)
  echo "[$i/$ATTEMPTS] GET /health -> ${code:-000}"
  if [[ "$code" == "200" ]]; then
    echo "Root response:"; curl -s --max-time 5 "${BASE_URL%/}/"; echo
    echo "Smoke test passed."
    exit 0
  fi
  sleep "$SLEEP"
done

echo "Smoke test FAILED: ${BASE_URL} never became healthy." >&2
exit 1
