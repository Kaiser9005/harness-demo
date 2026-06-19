#!/bin/bash
# tests/oracle_core.test.sh — fixtures for core/oracle_core.sh.
#
# Proves the two independent guards (anti-forgery author filter + anti-stale diff_sha) and the
# last-marker-wins / bot-suffix-normalization behavior. The forgery fixture is the security
# regression test: a non-oracle author posting a perfectly-formed accept must be ignored.
# No git, no network. Exit code = failed assertions.

set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CORE="$ROOT/core/oracle_core.sh"
FAILS=0
pass() { echo "  PASS  $1"; }
fail() { echo "  FAIL  $1 ${2:+→ got: $2}"; FAILS=$((FAILS + 1)); }

HEAD="2b4a7cf0cf37711f9294279fd6d63b983835605f"   # 40-hex
SHORT="2b4a7cf0c"                                  # 9-char prefix of HEAD
OTHER="1ee0b4d85b9b33548c4367d6e87dfa4672119bfa"

# run_core <head> <login> <strict:true|false> <comments-py-literal>
run_core() {
  python3 - "$1" "$2" "$3" <<PY | bash "$CORE"
import json, sys
head, login, strict = sys.argv[1], sys.argv[2], (sys.argv[3] == "true")
comments = $4
print(json.dumps({"head_sha": head, "oracle_login": login, "strict_sha": strict, "comments": comments}))
PY
}

# Build a marker body with a given diff_sha + verdict.
mk() { python3 - "$1" "$2" <<'PY'
import sys
sha, verdict = sys.argv[1], sys.argv[2]
print("<!-- oracle-verdict -->\n```json\n" + '{"pr":352,"diff_sha":"%s","oracle":"%s"}\n' % (sha, verdict) + "```\n")
PY
}

echo "=== oracle_core fixtures ==="

# 1. Happy path: oracle-authored accept, full sha == head → RECORD accept
B=$(mk "$HEAD" accept)
r=$(run_core "$HEAD" agent-bot true "[{'author':{'login':'agent-bot'},'body':'''$B'''}]")
[ "$r" = "RECORD 352 $HEAD accept oracle-run" ] && pass "oracle accept (sha==head) → RECORD accept" || fail "happy accept" "$r"

# 2. FORGERY: a non-oracle author posts a perfectly-formed accept → SKIP (author-filter). THE test.
r=$(run_core "$HEAD" agent-bot true "[{'author':{'login':'attacker'},'body':'''$B'''}]")
case "$r" in SKIP*) pass "FORGERY: non-oracle author accept → SKIP (not authorized)";; *) fail "forgery must SKIP" "$r";; esac

# 3. ANTI-STALE (strict): oracle judged a DIFFERENT head → SKIP stale
BO=$(mk "$OTHER" accept)
r=$(run_core "$HEAD" agent-bot true "[{'author':{'login':'agent-bot'},'body':'''$BO'''}]")
case "$r" in SKIP\ stale-verdict:*) pass "anti-stale: sha!=head (strict) → SKIP stale";; *) fail "stale full sha" "$r";; esac

# 4. STRICT_SHA divergence on a short prefix:
#    strict=false (ledger) accepts the prefix; strict=true (merge gate) rejects it.
BSHORT=$(mk "$SHORT" accept)
r=$(run_core "$HEAD" agent-bot false "[{'author':{'login':'agent-bot'},'body':'''$BSHORT'''}]")
[ "$r" = "RECORD 352 $HEAD accept oracle-run" ] && pass "strict=false: short-prefix sha → RECORD (ledger-tolerant)" || fail "ledger prefix" "$r"
r=$(run_core "$HEAD" agent-bot true "[{'author':{'login':'agent-bot'},'body':'''$BSHORT'''}]")
case "$r" in SKIP\ stale-verdict:*) pass "strict=true: short-prefix sha → SKIP (gate demands exact)";; *) fail "gate exact" "$r";; esac

# 5. LAST-MARKER-WINS: reject then accept (re-judge) → accept
BR=$(mk "$HEAD" reject); BA=$(mk "$HEAD" accept)
r=$(run_core "$HEAD" agent-bot true "[{'author':{'login':'agent-bot'},'body':'''$BR'''},{'author':{'login':'agent-bot'},'body':'''$BA'''}]")
[ "$r" = "RECORD 352 $HEAD accept oracle-run" ] && pass "last-marker-wins: reject→accept (re-judge) → accept" || fail "last-wins" "$r"

# 6. fail-closed: empty oracle_login → SKIP (never trust an unauthenticated author)
r=$(run_core "$HEAD" "" true "[{'author':{'login':'agent-bot'},'body':'''$B'''}]")
case "$r" in SKIP\ no-oracle-login*) pass "empty oracle_login → SKIP (fail-closed)";; *) fail "empty login" "$r";; esac

# 7. bot-suffix normalization: var='agent-bot[bot]' vs author='agent-bot' must compare EQUAL → RECORD
r=$(run_core "$HEAD" "agent-bot[bot]" true "[{'author':{'login':'agent-bot'},'body':'''$B'''}]")
[ "$r" = "RECORD 352 $HEAD accept oracle-run" ] && pass "bot-suffix: var=agent-bot[bot] vs author=agent-bot → RECORD" || fail "bot suffix" "$r"

# 7b. anti-forgery STILL holds after normalization: a PR-author login never matches
r=$(run_core "$HEAD" "agent-bot[bot]" true "[{'author':{'login':'Kaiser9005'},'body':'''$B'''}]")
case "$r" in SKIP*) pass "forgery (real PR-author login) still SKIP after normalization";; *) fail "forgery still" "$r";; esac

# 8. bad head sha → SKIP bad-head-sha (fail-closed)
r=$(run_core "not-a-sha" agent-bot true "[{'author':{'login':'agent-bot'},'body':'''$B'''}]")
case "$r" in SKIP\ bad-head-sha*) pass "bad head sha → SKIP (fail-closed)";; *) fail "bad head" "$r";; esac

echo ""
echo "=== oracle_core: $FAILS failed ==="
exit "$FAILS"
