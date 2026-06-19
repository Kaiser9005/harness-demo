# harness-demo — the verdict core that lets an AI agent merge to production *safely*

**The problem:** if you let an autonomous coding agent open and merge its own pull requests, what
stops it from merging something broken — or something a prompt-injection talked it into?

**The answer in this repo:** a small, **fail-closed** decision core that an agent's PR must pass
*before* it can merge unattended. It emits `MERGE` only when **every one of 9 gates** is
unambiguously satisfied. Anything ambiguous, missing, or unexpected → `BLOCK` (a human merges).
Disabled → `NOOP` (ships inert). The burden of proof is on the *merge*, not on the human.

This is a **sanitized, runnable extraction** of a gate that runs in a real production monorepo,
where it has gated a class of agent-authored PRs behind these checks. The numbers and the honest
failure analysis below are real (see *Provenance*).

```
$ bash demo/run.sh        # watch the gates make decisions, narrated
$ bash tests/run.sh       # 48 assertions prove the fail-closed behavior
```

---

## Why this is the hard part (and the interesting part)

Most "AI coding agent" tooling sells *orchestration* — make the agent do more, faster. The
genuinely hard problem is the opposite: **bounding what an autonomous writer can do to your `main`
branch.** That's a safety-engineering problem, and safety engineering has one rule this code lives
by:

> **Fail closed.** Over-blocking costs one human merge-click. Under-blocking ships unreviewed code
> past the human gate — against a CI that can run red silently. Those costs are not symmetric, so
> the gate is not symmetric. Any ambiguity resolves to BLOCK.

## The 9 gates

| # | Gate | What it stops |
|---|------|---------------|
| 1 | **label present** | only PRs explicitly tagged agent-output are even considered (else NOOP) |
| 2 | **required CI checks green** — via the API, per-check, *not* `mergeable_state` alone | a red check; **a renamed/missing check reading as "passed"** (fail-closed rename guard) |
| 3 | **structured adversarial verdict** `{"verdict":"PASS","critical_findings":0,…}` — parsed, not grepped | a reviewer that found problems; a free-text "looks good" that isn't a real verdict |
| 3b | **diff_sha re-validation** == PR head | a commit landing *after* the review (the post-review-commit race) **and** a fabricated PASS planted by prompt-injection (it can't carry the real head sha) |
| 4 | **not draft** | a reviewer signalling a CRITICAL by marking the PR draft |
| 5 | **no guarded path** (migrations, `*.sql`, auth/tenant/permission/secrets) | schema + security changes auto-merging — these ALWAYS get a human |
| 6 | **no gate-defining file** | a PR that edits the very gate judging it, to weaken it and self-pass |
| 7 | **kill-switch == "false"** | the gate running by accident — it's OFF unless *explicitly* enabled |
| 8 | **independent oracle accepts** — a **second model, different family** | a correlated blind spot: one model's mistake the other is unlikely to share |
| 9 | **sentinel exclusion** | a **known, recorded false-pass** re-merging — even if every other gate is green, even on a manual re-label |

Plus a `mergeable_state` conflict guard (additive to gate 2, never a substitute for it).

### The two ideas worth stealing even if you never use this code

1. **An independent oracle of a *different model family* (gate 8).** A single reviewer can't defend
   against its own blind spots. A second model from a different family can — correlated failure is
   the threat, model diversity is the defense. See [`core/oracle_core.sh`](core/oracle_core.sh),
   with its two independent guards: an **author filter** (a forged verdict from a non-oracle
   account is ignored — see the forgery fixture) and a **diff_sha pin** (a verdict against a stale
   head is rejected).

2. **A post-merge audit that survives arming (gate 8's companion).** Once the oracle is wired into
   the gate as a blocking actuator, its accept-rate becomes a *tautology* — every auto-merged PR is
   by-definition oracle-accepted, so you've lost your forward safety signal at the exact moment you
   armed the gate. The fix: a **separate, post-merge** audit that samples already-merged PRs and
   re-reviews each with *yet another* model. It measures a real **false-positive rate** you can
   publish honestly. It **never auto-reverts** — that would re-introduce the unattended-write risk
   the whole design exists to bound. See [`core/spot_audit.sh`](core/spot_audit.sh).

---

## How it can still fail (the part nobody publishes)

A gate that claims to be perfect is lying, and a sharp reviewer will catch it. Here is the honest
threat model — the failures this design **bounds but does not eliminate**:

- **The gate's reviewer model can be wrong, and the oracle can share the mistake.** Model diversity
  *reduces* correlated failure; it doesn't make it zero. In the production system this came from,
  **a small number of auto-merged PRs were later found to be false-passes** by the independent
  post-merge audit (gate 8's companion). That's not a hidden bug — it's the *measured* outcome the
  spot-audit exists to surface, and those specific PRs are now **hard-excluded by gate 9** so they
  can never re-merge. The honest claim is *"a measured, low false-positive rate, caught by an
  independent auditor and fenced off,"* **not** *"never wrong."*

- **Gate 2 trusts your CI.** If a required check can pass while silently not running (a masking
  layer, a swallowed error, a `max-turns` cutoff), the gate inherits that blind spot. The
  rename-guard (a *missing* check fails closed) defends one slice of this; it does not make your CI
  honest. Audit your CI for silent-pass paths separately.

- **The guarded-path list (gate 5) is a denylist.** A novel sensitive path not in the pattern would
  pass it. The mitigation is a *second*, independent classifier upstream (on issue text, before the
  agent even starts) — two layers with different input domains, each covering the full superset. A
  single denylist is one layer, and one layer is not enough.

- **This is a gate, not a sandbox.** It decides *merge / don't merge*. It does not constrain what
  the agent does *inside* the PR, what it reads, or what tools it calls. Pair it with execution
  sandboxing and least-privilege tokens.

If you're evaluating whether to let an agent near your `main`, those four bullets are the
conversation to have — not the green checkmark.

---

## Layout

```
core/
  verdict_core.sh   the 9-gate merge decision. stdin JSON state → MERGE | BLOCK <reasons> | NOOP.
  oracle_core.sh    the independent-oracle verdict parser (author filter + diff_sha pin).
  spot_audit.sh     the post-merge, different-model audit ledger (measures the false-positive rate).
demo/
  run.sh            a narrated walkthrough — see each gate make a decision.
tests/
  run.sh            runs all suites. 48 assertions.
  *.test.sh         fixtures: happy path, every BLOCK reason, forgery, stale review, fail-closed garbage.
.github/workflows/
  example-automerge.yml   the thin glue: gather PR state via the API → call the core → act on exit code.
```

Each core is a pure function: **state in (stdin JSON), decision out (one line + exit code).** No
network, no eval of input (json-parse only), bash-3.2 portable. The glue is deliberately thin so
the *decision* is the testable part.

## Run it

Requirements: `bash`, `python3` (for JSON parsing), and `jq` for the spot-audit ledger only.

```bash
git clone https://github.com/Kaiser9005/harness-demo && cd harness-demo
bash demo/run.sh        # narrated: watch the gates decide
bash tests/run.sh       # 48 assertions, all green
```

## Provenance

This is extracted and generalized from a verdict core running in a production multi-tenant SaaS
monorepo (a vertical ERP). In that system, as of the last verified snapshot:

- **410 merged PRs** over ~3 months; **26** of them gate-auto-merged behind these checks (the rest
  human-reviewed). The honest framing is *"a safe class auto-merges behind 9 gates + an independent
  oracle,"* **not** *"400+ auto-merged."*
- a **post-merge independent-model audit** runs daily on a sample of the auto-merges — the forward
  safety signal that survives arming.

No production code, secrets, tenant data, or internal identifiers are in this repo (it was extracted
through a secret-scan + PII scan). It's the *pattern* and the *decision logic*, made runnable.

---

*Built by [Kaiser9005](https://github.com/Kaiser9005). If you're putting an autonomous agent near a
production branch and want a second pair of eyes on the safety design, that's exactly the kind of
work I do.*

## License

MIT — see [LICENSE](LICENSE).
