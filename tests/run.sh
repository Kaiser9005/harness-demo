#!/bin/bash
# tests/run.sh — run every fixture suite. Exit non-zero if any assertion fails.
# This is the whole point of the repo: clone it, run this, watch the gates defend themselves.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TOTAL=0
for t in "$ROOT"/tests/*.test.sh; do
  echo ""
  bash "$t"
  TOTAL=$((TOTAL + $?))
done
echo ""
echo "════════════════════════════════════════════"
if [ "$TOTAL" -eq 0 ]; then
  echo "  ✅ ALL FIXTURE SUITES PASSED"
else
  echo "  ❌ $TOTAL assertion(s) FAILED"
fi
echo "════════════════════════════════════════════"
exit "$TOTAL"
