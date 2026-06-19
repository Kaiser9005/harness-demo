#!/bin/bash
# verdict_core.sh — the pure, fixture-tested decision function that decides whether an
# AI-agent-authored pull request may be merged UNATTENDED, past a human review gate.
#
# This is a sanitized, runnable extraction of a verdict core that runs in a real production
# monorepo. The glue that gathers the state (gh-api / octokit: checks.listForRef, listFiles,
# listComments) lives in a thin GitHub Actions workflow; this script is the part that makes the
# decision, and it is the part that must be unit-testable — because the glue can only be
# integration-tested on a live PR, but the LOGIC that lets an agent's PR merge unreviewed must be
# provable in isolation.
#
# ─────────────────────────────────────────────────────────────────────────────────────────────
# THE CARDINAL RULE OF AN AUTO-MERGE GATE: never emit MERGE unless EVERY gate is unambiguously
# satisfied. Any ambiguity, any missing/unparseable input, any unexpected value → BLOCK
# (human-merge), never MERGE. This is the fail-closed discipline. The asymmetry is deliberate:
#   - over-blocking costs one human merge-click.
#   - under-blocking ships unreviewed code past the human gate — against a CI that can run red
#     silently. Those costs are not symmetric, so the gate is not symmetric.
# ─────────────────────────────────────────────────────────────────────────────────────────────
#
# The 9 gates (ALL must hold for MERGE):
#   1. label present                  the PR carries the "agent-output" label, else NOOP (not ours)
#   2. the REAL required CI checks green via gh-api, NOT mergeable_state / branch-protection alone:
#        each named required check must report conclusion==success. A missing/renamed check → BLOCK
#        (fail-closed rename guard — a check that quietly disappears must not read as "passed").
#   3. structured adversarial verdict JSON {"verdict":"PASS","critical_findings":0,"diff_sha":"…"}
#        — PARSED, not free-text grep. verdict!=PASS or critical_findings!=0 or absent → BLOCK.
#   3b. diff_sha RE-VALIDATED == PR head sha. Kills two attacks at once: a fabricated PASS planted
#        by prompt-injection (its diff_sha won't match the real head) AND the post-review-commit
#        race (a commit landing after the reviewer looked).
#   4. PR is NOT draft                 (the reviewer marks a PR draft to signal a CRITICAL finding)
#   5. NO guarded path                 (migrations, *.sql, auth/permission/tenant code) → human merge
#   6. NO gate-defining file           a PR must not edit the very gate that is judging it (else it
#                                      could weaken its own gate to self-pass) → human merge
#   7. kill-switch == "false"          fail-safe: the gate runs ONLY when explicitly enabled; unset
#                                      / "true" / anything-else → NOOP (disabled). Ships inert.
#   8. independent oracle accepted     a SECOND model (different family) must also accept — see the
#                                      sibling oracle_core.sh. reject/forged/malformed → BLOCK;
#                                      pending → NOOP await (never masks a real BLOCK).
#   9. sentinel exclusion              known-bad PR numbers (recorded false-passes) can NEVER merge,
#                                      even with all other gates green and even on a manual re-label.
#   + mergeable_state guard            conflict guard, additive to gate 2, never a substitute.
#
# Exit-code contract (the workflow wrapper depends on these EXACTLY):
#   0  MERGE  — every gate passed → queue squash auto-merge
#   1  BLOCK  — at least one gate failed → post "human-merge required (<reasons>)" + stop
#   2  NOOP   — workflow disabled (kill-switch not 'false') OR PR is not an agent-output candidate
#
# Stdout: a single line — "MERGE" | "BLOCK <semicolon-joined reasons>" | "NOOP <reason>".
# The script NEVER evals its input — it only json-parses it (no untrusted-interpolation vector).
#
# Input JSON (stdin):
#   {
#     "kill_switch":       "<raw repo-var value>",        # gate 7; normalized lower-case here
#     "is_agent_output":   true | false,                  # gate 1 (label present)
#     "is_open":           true | false,
#     "is_draft":          true | false,                  # gate 4
#     "mergeable_state":   "clean"|"dirty"|"blocked"|… | null,
#     "head_sha":          "<40-char PR head sha>",        # gate 3b anchor
#     "pr_number":         <int>,                          # gate 9
#     "checks": {                                          # gate 2 — conclusion per required check
#       "lint":     "success"|"failure"|…|"missing"|null,
#       "tests":    "success"|…|"missing"|null,
#       "security": "success"|…|"missing"|null
#     },
#     "verdict": { "verdict":"PASS"|…, "critical_findings":<int>, "diff_sha":"<sha>" } | null,
#     "oracle":  { "result":"accept"|"reject"|"await"|"block" } | null,   # gate 8 (from oracle_core)
#     "changed_files": ["path", …]                         # gates 5 + 6 are computed from this
#   }
#
# Configurable via env (defaults match a typical setup; override for your repo):
#   GUARDED_RE        POSIX-ERE of paths that always require human merge (gate 5)
#   GATE_FILE_RE      POSIX-ERE of files that define the gate itself (gate 6)
#   SENTINEL_PRS      comma list of known-bad PR numbers that can never merge (gate 9)

set -uo pipefail

# Guarded-path set (gate 5) — security-sensitive surfaces that ALWAYS require human merge.
# The lesson encoded here: a TEXT-classifier upstream can keep "auth/tenant" *issues* out of the
# safe pool by title/body, but THIS gate sees the actual changed FILES — an issue text-classified
# "safe" whose implementation drifts into auth/migration code would slip a text-only filter. Two
# layers, different input domains, each must cover the full superset. (?i:…) so real casings match.
GUARDED_RE="${GUARDED_RE:-^migrations/|^db/migrations/|[.]sql$|(?i:auth)|(?i:tenant)|(?i:permission)|(?i:rls)|session|secret|credential}"

# Gate-defining file set (gate 6) — a PR touching ANY of these must be human-merged: it could
# otherwise weaken the very gate judging it. Conservative on purpose: the CI workflows, the verdict
# cores, and this gate's own tests.
GATE_FILE_RE="${GATE_FILE_RE:-^[.]github/workflows/|^core/verdict_core[.]sh$|^core/oracle_core[.]sh$|^core/spot_audit[.]sh$|^tests/}"

INPUT=$(cat)

# Single python3 parse → emit a flat, whitespace-free token line the bash logic reads.
# (bash-3.2 / 5.x portable: no declare -A, no ${var,,} — python does the JSON.)
PARSED=$(printf '%s' "$INPUT" | GUARDED_RE="$GUARDED_RE" GATE_FILE_RE="$GATE_FILE_RE" python3 -c '
import json, sys, re, os

GUARD_RE = re.compile(os.environ["GUARDED_RE"])
GATE_RE  = re.compile(os.environ["GATE_FILE_RE"])

def b(v): return "true" if v is True else "false"

try:
    d = json.load(sys.stdin)
    if not isinstance(d, dict):
        raise ValueError("not an object")
except Exception:
    print("PARSE_ERROR"); sys.exit(0)

kill = str(d.get("kill_switch") or "").strip().lower() or "<unset>"

is_ao   = b(d.get("is_agent_output"))
is_open = b(d.get("is_open"))
is_draft= b(d.get("is_draft"))
mstate  = d.get("mergeable_state"); mstate = "null" if mstate is None else (str(mstate).strip() or "null")
head    = (d.get("head_sha") or "").strip() or "null"

checks = d.get("checks") or {}
def conc(k):
    v = checks.get(k)
    return "missing" if v is None else (str(v).strip() or "missing")
lint = conc("lint"); tests = conc("tests"); sec = conc("security")

# Verdict block.
v = d.get("verdict")
if not isinstance(v, dict):
    vverdict = vcrit = vsha = "ABSENT"
else:
    vverdict = str(v.get("verdict") or "ABSENT").strip() or "ABSENT"
    cf = v.get("critical_findings")
    # critical_findings MUST be an integer; anything non-int → ABSENT (fail-closed).
    vcrit = "ABSENT" if (isinstance(cf, bool) or not isinstance(cf, int)) else str(cf)
    vsha = str(v.get("diff_sha") or "ABSENT").strip() or "ABSENT"

# Oracle block (gate 8) — ENUM ONLY (the workflow pre-parses the oracle comment via oracle_core.sh
# and passes {result}). accept|reject|await|block; anything else → "block" (fail-closed). Absent
# entirely → "await" (back-compat: a transitional gather not yet wired must not wedge every PR).
o = d.get("oracle")
if o is None:
    oresult = "await"
elif not isinstance(o, dict):
    oresult = "block"
else:
    r = o.get("result")
    oresult = r.strip().lower() if isinstance(r, str) else ""
    if oresult not in ("accept", "reject", "await", "block"):
        oresult = "block"

# Gate-9 sentinel — env SENTINEL_PRS + input pr_number.
#   off       env unset/blank → dormant (back-compat: un-wired config must not wedge the lane)
#   malformed env set but any non-numeric token → BLOCK every PR (fail-closed)
#   no-num    env valid but pr_number absent/non-int → BLOCK (fail-closed, half-wired gather)
#   hit       pr_number listed → BLOCK sentinel (can NEVER MERGE)
#   ok        pr_number valid and not listed → no effect
senv = os.environ.get("SENTINEL_PRS", "")
pn = d.get("pr_number")
pnum_disp = str(pn) if (isinstance(pn, int) and not isinstance(pn, bool)) else "null"
if not senv.strip():
    sent = "off"
else:
    stoks = [t.strip().lstrip("#") for t in senv.split(",")]
    stoks = [t for t in stoks if t]
    if not stoks or any(not re.match(r"^[0-9]+$", t) for t in stoks):
        sent = "malformed"
    elif isinstance(pn, bool) or not isinstance(pn, int):
        sent = "no-num"
    elif pn in {int(t) for t in stoks}:
        sent = "hit"
    else:
        sent = "ok"

# Compute guarded + gate-file hits from the authoritative changed_files list (the script does NOT
# trust any glue-precomputed hit list — it re-derives from the full file list).
files = d.get("changed_files") or []
if not isinstance(files, list): files = []
files = [str(f).strip() for f in files if str(f).strip()]
guarded_hits  = [f for f in files if GUARD_RE.search(f)]
gatefile_hits = [f for f in files if GATE_RE.search(f)]
def joinhits(hs): return (",".join(hs[:5]) if hs else "none")

print(" ".join([
    "OK", kill, is_ao, is_open, is_draft, mstate, head,
    lint, tests, sec, vverdict, vcrit, vsha,
    str(len(guarded_hits)), joinhits(guarded_hits),
    str(len(gatefile_hits)), joinhits(gatefile_hits),
    oresult, sent, pnum_disp,
]))
' 2>/dev/null || echo "PARSE_ERROR")

# Unparseable / empty input → BLOCK (fail-closed; an auto-merge gate must never MERGE on garbage).
if [ "${PARSED%% *}" = "PARSE_ERROR" ] || [ -z "$PARSED" ]; then
    echo "BLOCK unparseable-state-input"
    exit 1
fi

read -r TAG KILL IS_AO IS_OPEN IS_DRAFT MSTATE HEAD LINT TESTS SEC VVERDICT VCRIT VSHA GCOUNT GHITS FCOUNT FHITS ORACLE SENT PNUM <<< "$PARSED"

# ── Gate 7 (kill-switch) FIRST — a disabled workflow is a NOOP, not a block. ──
if [ "$KILL" != "false" ]; then
    echo "NOOP kill-switch='${KILL}'(not 'false')"
    exit 2
fi

# ── Gate 1 (agent-output label) — not our PR → NOOP. ──
if [ "$IS_AO" != "true" ]; then
    echo "NOOP not-agent-output"
    exit 2
fi

# Closed PR → NOOP (nothing to merge).
if [ "$IS_OPEN" != "true" ]; then
    echo "NOOP not-open"
    exit 2
fi

# From here, any failure is a BLOCK (human-merge required). Accumulate ALL reasons.
REASONS=""
add() { REASONS="${REASONS:+$REASONS; }$1"; }

# ── Gate 4 (not draft) ──
[ "$IS_DRAFT" = "true" ] && add "PR is draft (reviewer left a CRITICAL finding)"

# ── conflict guard (additive to gate 2): accept clean|null; BLOCK dirty|blocked|behind|other. ──
case "$MSTATE" in
    clean|null) : ;;
    *)  add "mergeable_state=${MSTATE} (conflict / not all green)" ;;
esac

# ── Gate 2 (required checks green — fail-closed on missing/renamed/unfinished) ──
[ "$LINT"  != "success" ] && add "check 'lint'=${LINT} (not success)"
[ "$TESTS" != "success" ] && add "check 'tests'=${TESTS} (not success)"
[ "$SEC"   != "success" ] && add "check 'security'=${SEC} (not success)"

# ── Gate 3 (structured JSON verdict PASS, 0 critical) + 3b (diff_sha re-validation) ──
if [ "$VVERDICT" = "ABSENT" ]; then
    add "no structured adversarial verdict JSON (verdict marker absent/malformed)"
else
    [ "$VVERDICT" != "PASS" ] && add "adversarial verdict='${VVERDICT}' (not PASS)"
    if [ "$VCRIT" = "ABSENT" ]; then
        add "verdict critical_findings not an integer (malformed)"
    elif [ "$VCRIT" != "0" ]; then
        add "verdict critical_findings=${VCRIT} (not 0)"
    fi
    if [ "$VSHA" = "ABSENT" ]; then
        add "verdict has no diff_sha (cannot re-validate review freshness)"
    elif [ "$HEAD" = "null" ]; then
        add "PR head_sha unknown (cannot re-validate diff_sha)"
    elif [ "$VSHA" != "$HEAD" ]; then
        add "diff_sha mismatch: reviewed ${VSHA} != head ${HEAD} (commit landed after review)"
    fi
fi

# ── Gate 5 (guarded path) ──
[ "$GCOUNT" != "0" ] && add "touches guarded path(s): ${GHITS}"

# ── Gate 6 (gate-file self-protection) ──
[ "$FCOUNT" != "0" ] && add "touches gate-defining file(s) — PR must not edit its own gate: ${FHITS}"

# ── Gate 9 (sentinel exclusion) — a listed PR number can NEVER yield MERGE. ──
case "$SENT" in
    hit)       add "sentinel PR #${PNUM} (SENTINEL_PRS) — a recorded false-pass never auto-merges (gate-9)" ;;
    malformed) add "SENTINEL_PRS malformed (fail-closed — sentinel protection cannot be trusted)" ;;
    no-num)    add "SENTINEL_PRS set but pr_number unavailable in state input (fail-closed)" ;;
    off|ok)    : ;;
    *)         add "gate-9 sentinel token '${SENT}' unrecognized (fail-closed)" ;;
esac

# ── Gate 8 (independent oracle) — reject / block are fail-closed BLOCK reasons. ──
case "$ORACLE" in
    reject) add "independent oracle verdict=reject (human-merge required)" ;;
    block)  add "oracle verdict unparseable/forged/malformed (fail-closed — cannot trust)" ;;
    accept|await) : ;;   # accept = ok; await handled below
    *)      add "oracle result token '${ORACLE}' unrecognized (fail-closed)" ;;
esac

# Any BLOCK reason (from ANY gate, incl. oracle reject/block) wins over an await — a missing oracle
# must NEVER mask a real failure (a pending oracle on a red-CI PR is still a BLOCK, not an await).
if [ -n "$REASONS" ]; then
    echo "BLOCK ${REASONS}"
    exit 1
fi

# No BLOCK reason. If the oracle hasn't accepted yet (await / absent), the PR is otherwise green but
# not ready to auto-merge — NOOP await-oracle (the workflow re-fires when the oracle posts).
if [ "$ORACLE" = "await" ]; then
    echo "NOOP await-oracle (no independent oracle accept for this head yet)"
    exit 2
fi

echo "MERGE"
exit 0
