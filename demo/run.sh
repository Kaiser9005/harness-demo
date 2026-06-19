#!/bin/bash
# demo/run.sh — a narrated walkthrough. Pipes example PR states through the real verdict core so you
# can SEE the gates make decisions. No setup beyond bash + python3. Run it: bash demo/run.sh
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CORE="$ROOT/core/verdict_core.sh"
HEAD="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

hr()  { printf '%s\n' "────────────────────────────────────────────────────────────"; }
say() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# decide '<scenario JSON override>' — merges over a green baseline, runs the core, prints the verdict.
decide() {
  local verdict ex
  verdict=$(python3 - "$HEAD" "$1" <<'PY' | bash "$CORE"
import json, sys
head, override = sys.argv[1], sys.argv[2]
base = {
  "kill_switch": "false", "is_agent_output": True, "is_open": True, "is_draft": False,
  "mergeable_state": "clean", "head_sha": head, "pr_number": 100,
  "checks": {"lint": "success", "tests": "success", "security": "success"},
  "verdict": {"verdict": "PASS", "critical_findings": 0, "diff_sha": head},
  "oracle": {"result": "accept"}, "changed_files": ["src/feature.ts"],
}
base.update(json.loads(override))
print(json.dumps(base))
PY
)
  ex=$?
  printf '   → exit %s   %s\n' "$ex" "$verdict"
}

say "An AI agent opened a PR. Should it merge UNATTENDED — past the human gate?"
echo "   The verdict core decides. It emits MERGE only when EVERY gate is satisfied."
echo "   Anything ambiguous → BLOCK (a human merges). Disabled → NOOP. Fail-closed by design."

hr; say "1. Everything is green — clean CI, PASS review, independent oracle accepts."
decide '{}'
echo "   ✅ MERGE. This is the only path to an unattended merge."

hr; say "2. The agent's tests are failing. (gate 2: required CI checks)"
decide '{"checks":{"lint":"success","tests":"failure","security":"success"}}'
echo "   🛑 BLOCK. A red check is never a merge — and a MISSING check blocks too (rename guard)."

hr; say "3. The PR touches a database migration. (gate 5: guarded path)"
decide '{"changed_files":["db/migrations/004_add_table.sql"]}'
echo "   🛑 BLOCK. Schema/auth/permission changes ALWAYS get a human, no matter how green."

hr; say "4. A commit landed AFTER the reviewer looked. (gate 3b: diff_sha re-validation)"
decide '{"verdict":{"verdict":"PASS","critical_findings":0,"diff_sha":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}}'
echo "   🛑 BLOCK. The review is stale — it judged a different head. (Also kills a fabricated PASS:"
echo "      a planted verdict can't carry the real head sha.)"

hr; say "5. The PR edits the gate that is judging it. (gate 6: self-protection)"
decide '{"changed_files":["core/verdict_core.sh"]}'
echo "   🛑 BLOCK. A PR must not weaken its own gate to self-pass."

hr; say "6. The independent oracle (a DIFFERENT model) rejects. (gate 8)"
decide '{"oracle":{"result":"reject"}}'
echo "   🛑 BLOCK. Two models must agree. A blind spot in one is unlikely shared by the other."

hr; say "7. The oracle hasn't run yet. (gate 8: pending)"
decide '{"oracle":{"result":"await"}}'
echo "   ⏸  NOOP await — the PR stays open, quiet, re-evaluated when the oracle posts."
echo "      (But a pending oracle NEVER masks a real failure — green-but-awaiting + red CI = BLOCK.)"

hr; say "8. This PR is a KNOWN false-pass we recorded. (gate 9: sentinel)"
SENTINEL_PRS="352" decide '{"pr_number":352}'
echo "   🛑 BLOCK. A recorded false-pass can NEVER auto-merge — even with every other gate green,"
echo "      even on a manual re-label. Honesty about your blind spots, encoded as a hard gate."

hr; say "9. Someone fed the gate garbage."
echo "not even json" | bash "$CORE" | sed 's/^/   → /'
echo "   🛑 BLOCK (fail-closed). An auto-merge gate must NEVER merge on unparseable input."

hr
say "That's the whole idea: the burden of proof is on the MERGE, not on the human."
echo "Run the fixtures to see all of it asserted:  bash tests/run.sh"
