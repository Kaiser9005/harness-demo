#!/bin/bash
# tests/verdict_core.test.sh — fixtures for core/verdict_core.sh.
#
# These prove the cardinal rule: the gate emits MERGE only when EVERY gate is unambiguously
# satisfied, and BLOCKs on any ambiguity. Each fixture builds an exact stdin state in python (so
# braces/newlines are exact), pipes it to the core, and asserts the verdict line + exit code.
# No git, no network, no live API. Exit code = number of failed assertions (0 = all pass).

set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CORE="$ROOT/core/verdict_core.sh"
FAILS=0
pass() { echo "  PASS  $1"; }
fail() { echo "  FAIL  $1 ${2:+→ got: $2}"; FAILS=$((FAILS + 1)); }

HEAD="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"   # 40-hex
OTHER="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

# state '<override as a JSON object>' → merges over a fully-green baseline, runs the core.
# The override is passed as argv (valid JSON: true/false/null) and json.loads'd — NOT a python literal.
state() {
  python3 - "$HEAD" "$1" <<'PY' | bash "$CORE"
import json, sys
head, override_json = sys.argv[1], sys.argv[2]
# A fully-green baseline; each fixture overrides specific keys.
base = {
  "kill_switch": "false",
  "is_agent_output": True, "is_open": True, "is_draft": False,
  "mergeable_state": "clean", "head_sha": head, "pr_number": 100,
  "checks": {"lint": "success", "tests": "success", "security": "success"},
  "verdict": {"verdict": "PASS", "critical_findings": 0, "diff_sha": head},
  "oracle": {"result": "accept"},
  "changed_files": ["src/feature.ts", "README.md"],
}
base.update(json.loads(override_json))
print(json.dumps(base))
PY
}
# run <override-dict> → echoes "EXIT|STDOUT"
run() { local out; out="$(state "$1")"; echo "$?|$out"; }
assert() { # assert <label> <override> <expected-exit> <expected-stdout-prefix>
  local r; r="$(run "$2")"; local ex="${r%%|*}"; local so="${r#*|}"
  if [ "$ex" = "$3" ] && [ "${so#"$4"}" != "$so" ]; then pass "$1"; else fail "$1" "exit=$ex out='$so'"; fi
}

echo "=== verdict_core fixtures ==="

# Happy path — every gate green → MERGE (exit 0)
assert "all gates green → MERGE"                 '{}'                                                   0 "MERGE"

# Gate 7 kill-switch — the fail-safe. Anything but "false" → NOOP (disabled, ships inert).
assert "kill-switch unset → NOOP"               '{"kill_switch": ""}'                                  2 "NOOP kill-switch"
assert "kill-switch 'true' → NOOP"              '{"kill_switch": "true"}'                              2 "NOOP kill-switch"
assert "kill-switch 'false' → enabled"          '{}'                                                   0 "MERGE"

# Gate 1 label — not our PR → NOOP
assert "no agent-output label → NOOP"           '{"is_agent_output": false}'                           2 "NOOP not-agent-output"

# Gate 2 required checks — any non-success → BLOCK (fail-closed on missing/renamed too)
assert "tests failing → BLOCK"                  '{"checks": {"lint":"success","tests":"failure","security":"success"}}' 1 "BLOCK"
assert "a check missing → BLOCK (rename guard)" '{"checks": {"lint":"success","tests":"success","security":null}}'      1 "BLOCK"

# Gate 3 structured verdict — absent / not PASS / criticals>0 → BLOCK
assert "no verdict JSON → BLOCK"                '{"verdict": null}'                                    1 "BLOCK"
assert "verdict not PASS → BLOCK"               '{"verdict": {"verdict":"FAIL","critical_findings":0,"diff_sha":"'"$HEAD"'"}}' 1 "BLOCK"
assert "critical_findings>0 → BLOCK"            '{"verdict": {"verdict":"PASS","critical_findings":2,"diff_sha":"'"$HEAD"'"}}' 1 "BLOCK"
assert "critical_findings non-int → BLOCK"      '{"verdict": {"verdict":"PASS","critical_findings":"oops","diff_sha":"'"$HEAD"'"}}' 1 "BLOCK"

# Gate 3b diff_sha re-validation — verdict reviewed an OLDER head → BLOCK (post-review-commit race
# AND fabricated-PASS: a planted PASS won't carry the real head sha)
assert "diff_sha != head → BLOCK (stale review)" '{"verdict": {"verdict":"PASS","critical_findings":0,"diff_sha":"'"$OTHER"'"}}' 1 "BLOCK"

# Gate 4 draft — reviewer marks draft to signal a CRITICAL → BLOCK
assert "draft PR → BLOCK"                       '{"is_draft": true}'                                   1 "BLOCK"

# Gate 5 guarded path — auth/migration/sql touched → BLOCK (human merge)
assert "touches *.sql → BLOCK"                  '{"changed_files": ["src/x.ts","db/migrations/001.sql"]}' 1 "BLOCK"
assert "touches auth code → BLOCK"              '{"changed_files": ["src/authService.ts"]}'            1 "BLOCK"
assert "touches tenant code → BLOCK"            '{"changed_files": ["src/useTenantContext.ts"]}'       1 "BLOCK"

# Gate 6 gate-file self-protection — a PR editing its own gate → BLOCK
assert "edits the verdict core → BLOCK"         '{"changed_files": ["core/verdict_core.sh"]}'          1 "BLOCK"
assert "edits a workflow → BLOCK"               '{"changed_files": [".github/workflows/automerge.yml"]}' 1 "BLOCK"

# Gate 8 oracle — reject / forged-or-malformed (block) → BLOCK; await → NOOP; accept → ok
assert "oracle reject → BLOCK"                  '{"oracle": {"result":"reject"}}'                      1 "BLOCK"
assert "oracle malformed → BLOCK (fail-closed)" '{"oracle": {"result":"???"}}'                         1 "BLOCK"
assert "oracle await (pending) → NOOP"          '{"oracle": {"result":"await"}}'                       2 "NOOP await-oracle"
assert "oracle absent → NOOP await (back-compat)" '{"oracle": null}'                                   2 "NOOP await-oracle"

# Oracle await must NOT mask a real BLOCK — a pending oracle on red CI is still a BLOCK
assert "await + red CI → BLOCK (await never masks)" '{"oracle":{"result":"await"},"checks":{"lint":"failure","tests":"success","security":"success"}}' 1 "BLOCK"

# Gate 9 sentinel — a known-bad PR number can NEVER merge, even fully green.
# SENTINEL_PRS lists recorded false-passes; PR #352 is in it → BLOCK even with every other gate green.
( export SENTINEL_PRS="352,358"
  r="$(run '{"pr_number": 352}')"; ex="${r%%|*}"; so="${r#*|}"
  { [ "$ex" = "1" ] && [ "${so#BLOCK}" != "$so" ]; } && pass "sentinel PR #352 → BLOCK (gate-9, even all-green)" || fail "sentinel BLOCK" "exit=$ex out='$so'"
  r="$(run '{"pr_number": 999}')"; ex="${r%%|*}"; so="${r#*|}"
  { [ "$ex" = "0" ] && [ "${so#MERGE}" != "$so" ]; } && pass "non-sentinel PR #999 → MERGE (sentinel does not over-block)" || fail "non-sentinel" "exit=$ex out='$so'"
  r="$(SENTINEL_PRS="abc" state '{"pr_number": 10}')"; { [ "${r#BLOCK}" != "$r" ]; } && pass "SENTINEL_PRS malformed → BLOCK (fail-closed)" || fail "sentinel malformed" "$r"
)

# Conflict guard — dirty mergeable_state → BLOCK
assert "mergeable_state dirty → BLOCK"          '{"mergeable_state": "dirty"}'                         1 "BLOCK"

# Garbage input → BLOCK (fail-closed)
echo "not json at all" | bash "$CORE" >/dev/null 2>&1; [ "$?" = "1" ] && pass "garbage stdin → BLOCK (fail-closed)" || fail "garbage stdin"

echo ""
echo "=== verdict_core: $FAILS failed ==="
exit "$FAILS"
