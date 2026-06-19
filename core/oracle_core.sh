#!/bin/bash
# oracle_core.sh — the independent-oracle verdict-extraction core (pure, fixture-tested).
#
# Gate 8 of the auto-merge pipeline (see verdict_core.sh) is "an independent model must ALSO accept".
# The first reviewer and the oracle are deliberately DIFFERENT model families, so a blind spot in one
# is unlikely to be shared by the other (correlated failure is the thing a single reviewer can't
# defend against). This script parses the oracle's verdict comment off a PR, safely.
#
# It is sanitized + runnable. In production the glue (a GitHub Actions step) fetches the PR comments
# + the judged head SHA and pipes them here; this script makes the parse decision.
#
# ─────────────────────────────────────────────────────────────────────────────────────────
# TWO INDEPENDENT GUARDS — they stop DIFFERENT threats, both are required:
#
#   ANTI-FORGERY = author filter. The oracle posts as an authenticated bot login. A PR author
#                  CANNOT impersonate that login, so a forged verdict block planted by a malicious
#                  commenter is ignored. diff_sha matching does NOT stop forgery (the attacker
#                  controls the PR head, so they could make a forged diff_sha match). If the
#                  oracle_login is empty/unset → SKIP (fail-closed: never trust an unauthenticated
#                  author).
#
#   ANTI-STALE   = diff_sha vs head. Stops accepting a verdict the oracle produced against an OLDER
#                  head (a commit landed after the judge looked).
# ─────────────────────────────────────────────────────────────────────────────────────────
# WHY a shared core: two consumers need the same parse — the auto-merge gate (high-stakes) and a
# post-merge audit ledger. Two copies of an anti-forgery parser WOULD DRIFT (a hardening to one
# would miss the other, and the merge path is the higher-stakes one). One core, parameterized.
#
# Input JSON (stdin):
#   {
#     "head_sha":     "<40-hex PR head the oracle judged against>",
#     "oracle_login": "<authenticated login the oracle posts as, e.g. 'agent-bot'>",
#     "strict_sha":   true | false,   # OPTIONAL — default false. true = exact 40-hex equality only
#                                     #            (the merge gate); false = 7-40 hex prefix tolerant
#                                     #            (the ledger).
#     "marker":       "<html-comment marker name>",  # OPTIONAL — default "oracle-verdict"
#     "comments":     [ { "author": {"login": "<login>"}, "body": "<markdown>" }, … ]
#   }
#
# Marker contract (the LAST oracle-authored comment containing it wins — a re-judge supersedes):
#     <!-- oracle-verdict -->
#     ```json
#     {"pr":263,"diff_sha":"<40-hex>","oracle":"accept"}
#     ```
#
# Stdout (ONE line):
#   RECORD <pr> <head_sha> <verdict> oracle-run        (verdict ∈ accept|reject)
#   SKIP <reason>
#     reasons: parse-error | bad-head-sha | no-oracle-login | bad-marker-name | no-verdict-marker |
#              malformed-verdict:<field> | stale-verdict:<vsha>!=<head>
#
# Exit: ALWAYS 0 (the caller reads stdout; a non-zero would wedge the per-PR loop). Never evals
# input — json-parse only. bash-3.2 safe: python3 does the JSON.

set -uo pipefail

INPUT=$(cat)

RESULT=$(printf '%s' "$INPUT" | python3 -c '
import json, sys, re

def out(s):
    print(s); sys.exit(0)

try:
    d = json.load(sys.stdin)
    if not isinstance(d, dict):
        raise ValueError("not an object")
except Exception:
    out("SKIP parse-error")

head = str(d.get("head_sha") or "").strip().lower()
if not re.fullmatch(r"[0-9a-f]{40}", head):
    out("SKIP bad-head-sha")

oracle_login = str(d.get("oracle_login") or "").strip().lower()
if not oracle_login:
    out("SKIP no-oracle-login")   # fail-closed anti-forgery: never trust an unauthenticated author

def _norm_login(s):
    # The SAME bot can present two login strings depending on the API surface: the GraphQL Actor.login
    # returns the bare name ("agent-bot") while the REST user.login carries a "[bot]" suffix
    # ("agent-bot[bot]"). Strip a trailing "[bot]" so the two compare EQUAL. Anti-forgery still
    # holds — a PR author can present neither "agent-bot" nor "agent-bot[bot]".
    v = str(s or "").strip().lower()
    return v[:-5] if v.endswith("[bot]") else v

oracle_login_norm = _norm_login(oracle_login)

strict_sha = d.get("strict_sha")
strict_sha = bool(strict_sha) if isinstance(strict_sha, bool) else False

# marker name — parameterized; default preserves the common caller. Validated to a safe charset and
# regex-escaped before interpolation (never trust input into a regex).
marker_name = str(d.get("marker") or "oracle-verdict").strip()
if not re.fullmatch(r"[a-z0-9-]{1,64}", marker_name):
    out("SKIP bad-marker-name")

comments = d.get("comments")
if not isinstance(comments, list):
    comments = []

# Marker: an HTML comment, then (allowing blank lines) a ```json fenced block. DOTALL so the JSON
# can span lines. Anchored ON the marker (not first-match anywhere) so a stray earlier ```json block
# in the same body is NOT grabbed. Non-greedy to the closing fence. Scan ALL oracle-authored
# comments, keep the LAST marker found (later comment = re-judge supersedes earlier).
MARKER = re.compile(
    r"<!--\s*" + re.escape(marker_name) + r"\s*-->\s*```json\s*(\{.*?\})\s*```",
    re.DOTALL,
)

last_json = None
for c in comments:
    if not isinstance(c, dict):
        continue
    author = c.get("author") or {}
    login = str((author.get("login") if isinstance(author, dict) else "") or "").strip().lower()
    if _norm_login(login) != oracle_login_norm:
        continue  # ANTI-FORGERY: ignore non-oracle authors
    body = c.get("body")
    if not isinstance(body, str):
        continue
    for m in MARKER.finditer(body):
        last_json = m.group(1)   # keep overwriting → last match in last oracle comment wins

if last_json is None:
    out("SKIP no-verdict-marker")

try:
    v = json.loads(last_json)
    if not isinstance(v, dict):
        raise ValueError("marker not an object")
except Exception:
    out("SKIP malformed-verdict-json")

pr = v.get("pr")
if isinstance(pr, bool) or not isinstance(pr, int) or pr <= 0:
    out("SKIP malformed-verdict:pr")

verdict = str(v.get("oracle") or "").strip().lower()
if verdict not in ("accept", "reject"):
    out("SKIP malformed-verdict:oracle")

vsha = str(v.get("diff_sha") or "").strip().lower()
if not re.fullmatch(r"[0-9a-f]{7,40}", vsha):
    out("SKIP malformed-verdict:diff_sha")

# gate-3b: diff_sha must match the judged head, per the strict_sha flag.
if strict_sha:
    if vsha != head:                     # AUTO-MERGE GATE: exact 40-hex equality, no prefix tolerance
        out("SKIP stale-verdict:%s!=%s" % (vsha, head))
else:
    if not head.startswith(vsha):        # LEDGER: accept a 7-40 hex prefix, but a STRICT prefix only
        out("SKIP stale-verdict:%s!=%s" % (vsha, head))

# All guards passed. Emit using the authoritative full head_sha + a FIXED evidence literal.
out("RECORD %d %s %s oracle-run" % (pr, head, verdict))
' 2>/dev/null || echo "SKIP python-error")

# Defensive: an empty result (python crashed before printing) → fail-closed SKIP.
if [ -z "$RESULT" ]; then
    echo "SKIP empty-result"
    exit 0
fi

echo "$RESULT"
exit 0
