#!/bin/bash
# spot_audit.sh — the independent-MODEL post-merge spot-audit ledger (pure, fixture-tested).
#
# WHY this exists — a subtle metric-integrity problem worth understanding:
#   Once the independent oracle (gate 8) is folded INTO the merge gate as a blocking actuator, the
#   oracle's accept-rate becomes a TAUTOLOGY: every auto-merged PR is BY DEFINITION oracle-accepted,
#   so "the oracle accepts X% of merges" stops measuring anything. You've lost your forward safety
#   signal at the exact moment you armed the gate.
#
#   The fix: a SEPARATE, POST-merge audit. Sample the PRs the gate already auto-merged and re-review
#   each with a DIFFERENT model family (e.g. a larger model than the gate's reviewer). Because it
#   audits already-decided artifacts, there's no circularity with the gate — it's a true independent
#   measurement that survives arming.
#
# This ledger tracks that audit. It NEVER merges, reverts, or flips a kill-switch — it is advisory IO
# only. A human (and a CI ::warning::) reads it. The point is a measured FALSE-POSITIVE RATE you can
# publish honestly — not an auto-remediation. (An auto-revert would re-introduce the unattended-write
# risk the whole design exists to bound.)
#
# Note the inverted health semantics: a HEALTHY audit has a LOW finding-rate. `status` reports the
# finding-rate and flags CONCERN ABOVE a threshold (the gate may be mis-merging), rather than
# success ABOVE one.
#
# Ledger schema (.ledger/spot-audit.json):
#   { "audit": "spot-audit", "concern_threshold": 5, "entries": [
#       { "pr": 263, "diff_sha": "<40-hex>", "verdict": "clean"|"finding",
#         "critical": <int>, "evidence": "<url|note>", "ts": "<iso>" } ] }
#   - verdict = the INDEPENDENT auditor's decision (different model family from the gate's reviewer).
#   - critical = count of CRITICAL findings the auditor saw that the gate auto-merged anyway
#                (0 on clean; >=1 on finding).
#   - dedup key = pr number (re-auditing the same PR overwrites, never double-counts).
#
# Usage:
#   spot_audit.sh record <pr> <diff_sha> <verdict> <critical> [evidence] [--ledger PATH] [--ts ISO]
#   spot_audit.sh rate    [--ledger PATH]   → "<findings>/<audited> (<pct>%)"
#   spot_audit.sh status  [--ledger PATH]   → CONCERN | HEALTHY (always exit 0; advisory)
#   spot_audit.sh init    [--ledger PATH]   → create empty ledger if absent
#
# Exit: 0 success; 1 usage/IO error. `status` prints CONCERN/HEALTHY but exits 0 (advisory only).

set -uo pipefail

JQ="$(command -v jq || echo /usr/bin/jq)"
# Above this finding-rate (% of audited PRs with >=1 critical the gate missed), flag CONCERN — a
# signal a human MUST look at. Default 5% (i.e. a target of >=95% the gate got right).
SPOT_AUDIT_CONCERN_THRESHOLD="${SPOT_AUDIT_CONCERN_THRESHOLD:-5}"
LEDGER=".ledger/spot-audit.json"

# ── arg parse: pull --ledger / --ts out of the positional stream ──────────────
ARGS=()
TS_OVERRIDE=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --ledger) LEDGER="$2"; shift 2 ;;
    --ts)     TS_OVERRIDE="$2"; shift 2 ;;
    *)        ARGS+=("$1"); shift ;;
  esac
done
set -- "${ARGS[@]:-}"
CMD="${1:-}"

die() { echo "spot-audit: $1" >&2; exit 1; }

ensure_ledger() {
  mkdir -p "$(dirname "$LEDGER")" 2>/dev/null || true
  # (Re)create the ledger if it is absent, EMPTY, or not valid JSON with an .entries array.
  # A 0-byte file (e.g. a failed `git show > file` redirect) must NOT pass as "exists".
  if [ ! -s "$LEDGER" ] || ! "$JQ" -e 'has("entries") and (.entries|type=="array")' "$LEDGER" >/dev/null 2>&1; then
    "$JQ" -n --argjson ct "$SPOT_AUDIT_CONCERN_THRESHOLD" \
      '{audit:"spot-audit", concern_threshold:$ct, entries:[]}' > "$LEDGER" \
      || die "cannot create ledger $LEDGER"
  fi
}

case "$CMD" in
  init)
    ensure_ledger
    echo "spot-audit: ready at $LEDGER"
    ;;

  record)
    pr="${2:-}"; diff_sha="${3:-}"; verdict="${4:-}"; critical="${5:-}"; evidence="${6:-}"
    [ -n "$pr" ] && [ -n "$verdict" ] && [ -n "$critical" ] \
      || die "record needs <pr> <diff_sha> <verdict> <critical> [evidence]"
    case "$verdict" in clean|finding) ;; *) die "verdict must be clean|finding (got '$verdict')" ;; esac
    case "$critical" in ''|*[!0-9]*) die "critical must be a non-negative integer (got '$critical')" ;; esac
    # cross-field coherence: a contradictory row would corrupt the finding-rate → reject it.
    if [ "$verdict" = "clean" ] && [ "$critical" != "0" ]; then die "clean verdict must have critical=0"; fi
    if [ "$verdict" = "finding" ] && [ "$critical" = "0" ]; then die "finding verdict must have critical>=1"; fi
    ensure_ledger
    ts="${TS_OVERRIDE:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
    tmp="$(mktemp)"
    # dedup by pr: drop any existing entry for this pr, then append the new one.
    "$JQ" --argjson pr "$pr" --arg sha "$diff_sha" --arg vd "$verdict" \
          --argjson cr "$critical" --arg ev "$evidence" --arg ts "$ts" \
      '.entries = ([.entries[] | select(.pr != $pr)] + [{pr:$pr, diff_sha:$sha, verdict:$vd, critical:$cr, evidence:$ev, ts:$ts}])' \
      "$LEDGER" > "$tmp" && mv "$tmp" "$LEDGER" || die "record failed"
    echo "spot-audit: recorded PR #$pr → verdict=$verdict critical=$critical"
    ;;

  rate)
    ensure_ledger
    "$JQ" -r '
      (.entries | length) as $n |
      ([.entries[] | select(.verdict=="finding")] | length) as $f |
      if $n == 0 then "0/0 (0%)"
      else "\($f)/\($n) (\(($f*100/$n)|floor)%)" end' "$LEDGER"
    ;;

  status)
    ensure_ledger
    "$JQ" -r --argjson thr "$SPOT_AUDIT_CONCERN_THRESHOLD" '
      (.entries | length) as $n |
      ([.entries[] | select(.verdict=="finding")] | length) as $f |
      (if $n==0 then 0 else ($f*100/$n) end) as $pct |
      if ($n > 0 and $pct >= $thr) then
        "CONCERN — \($f)/\($n) (\($pct|floor)%) audited PRs had >=1 CRITICAL the gate auto-merged (>= \($thr)% threshold). A HUMAN must review the gate (the audit NEVER auto-reverts)."
      else
        "HEALTHY — \($f)/\($n) (\(if $n==0 then 0 else ($pct|floor) end)%) finding-rate; under the \($thr)% threshold. (0 audited yet is vacuously healthy.) NOTE: this measures gate FALSE-POSITIVES only (bad auto-merges the auditor caught) — NEVER false-negatives (good PRs the gate wrongly blocked). A clean rate means \"no caught bad auto-merge\", not \"gate fully correct\"."
      end' "$LEDGER"
    ;;

  *)
    die "usage: spot_audit.sh {init|record|rate|status} [--ledger PATH] [--ts ISO]"
    ;;
esac
