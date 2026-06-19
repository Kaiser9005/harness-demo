#!/bin/bash
# tests/spot_audit.test.sh — fixtures for core/spot_audit.sh (the post-merge independent-model audit).
# Uses an isolated temp ledger so the real .ledger/ is never touched. Exit code = failed assertions.

set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SA="$ROOT/core/spot_audit.sh"
FAILS=0
pass() { echo "  PASS  $1"; }
fail() { echo "  FAIL  $1 ${2:+→ got: $2}"; FAILS=$((FAILS + 1)); }

command -v jq >/dev/null 2>&1 || { echo "  (skipped — jq not installed)"; echo "=== spot_audit: 0 failed (skipped) ==="; exit 0; }

TMP="$(mktemp -d)"; L="$TMP/ledger.json"
trap 'rm -rf "$TMP"' EXIT

echo "=== spot_audit fixtures ==="

bash "$SA" init --ledger "$L" >/dev/null
[ -s "$L" ] && pass "init creates ledger" || fail "init"

# Empty ledger is vacuously HEALTHY
r=$(bash "$SA" status --ledger "$L"); case "$r" in HEALTHY*) pass "empty ledger → HEALTHY";; *) fail "empty status" "$r";; esac

# Record clean audits → still healthy
bash "$SA" record 100 deadbeef clean 0 "note" --ledger "$L" --ts "2026-01-01T00:00:00Z" >/dev/null
bash "$SA" record 101 cafef00d clean 0 "note" --ledger "$L" --ts "2026-01-01T00:00:00Z" >/dev/null
r=$(bash "$SA" rate --ledger "$L"); [ "$r" = "0/2 (0%)" ] && pass "2 clean → rate 0/2 (0%)" || fail "rate clean" "$r"
r=$(bash "$SA" status --ledger "$L"); case "$r" in HEALTHY*) pass "2 clean → HEALTHY";; *) fail "status clean" "$r";; esac

# A finding (a critical the gate auto-merged) → rate climbs
bash "$SA" record 102 beadface finding 1 "missed critical" --ledger "$L" --ts "2026-01-01T00:00:00Z" >/dev/null
r=$(bash "$SA" rate --ledger "$L"); [ "$r" = "1/3 (33%)" ] && pass "1 finding of 3 → rate 1/3 (33%)" || fail "rate finding" "$r"
r=$(bash "$SA" status --ledger "$L"); case "$r" in CONCERN*) pass "33% finding-rate > 5% threshold → CONCERN";; *) fail "status concern" "$r";; esac

# dedup by pr: re-auditing #102 as clean overwrites, never double-counts
bash "$SA" record 102 beadface clean 0 "re-audit" --ledger "$L" --ts "2026-01-02T00:00:00Z" >/dev/null
r=$(bash "$SA" rate --ledger "$L"); [ "$r" = "0/3 (0%)" ] && pass "re-audit #102 clean → dedup, rate 0/3" || fail "dedup" "$r"

# coherence guards: clean-with-critical and finding-without-critical are rejected
bash "$SA" record 200 abc clean 2 --ledger "$L" >/dev/null 2>&1 && fail "clean+critical should reject" || pass "clean verdict with critical>0 → rejected"
bash "$SA" record 201 abc finding 0 --ledger "$L" >/dev/null 2>&1 && fail "finding+0 should reject" || pass "finding verdict with critical=0 → rejected"

# bad verdict value rejected
bash "$SA" record 300 abc maybe 0 --ledger "$L" >/dev/null 2>&1 && fail "bad verdict should reject" || pass "verdict 'maybe' → rejected"

echo ""
echo "=== spot_audit: $FAILS failed ==="
exit "$FAILS"
