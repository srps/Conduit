**ACCEPT, no blockers, for one owner repeat.** I checked only the route change in `e8405532…` and the exact assertions in `check-scoped-proxy-fixtures.py`; both match what I asked for. Text for the parent to archive as `installed-scoped-proxy-independent-review-r2.md`:

---

# Scoped system-proxy verifier: independent review r2 (route delta)

**Verdict: ACCEPT for one owner repeat (R5). No blockers.**

## Scope
- **Reviewed:** only the route-attribution change in utility SHA `e8405532a98359e4e816e2bd90499eb7f45aa60ce1a3e4c8f7d903a1e25139c4`, and the exact assertions in `check-scoped-proxy-fixtures.py`.
- **Accepted in earlier rounds, not re-reviewed:**
  - the phase-reference delta (`3dff8fe3…`), the r1 utility (`bc639bad…`) and the tests (`7cdfbf05…`)
  - the product controls in `proxy-prior-controls/results.json`
- **Product source:** unchanged at HEAD. The review was read-only.

## Route change: confirmed
- **`route_origin` (:1201-1221).** One `held` predicate (:1206-1208) is shared by the preserved and rebased cases. It requires:
  - the current active location
  - an enabled member with readable fields
  - the endpoint held by both the reference prior and the member's current fields

  A rebased reference sets only `rebased_hit` (:1209-1210) and never `preserved`. Each endpoint is classified, best first, as preserved, then `rebased_prior_held`, then `introduced_by_applied`, then `unattributed`. The worst endpoint decides, in this order: introduced, unattributed, rebased, preserved (:1219).
- **`route_verdict` (:1237-1238).** `rebased_prior_held` returns the per-service verdict when it is `fail` or `pending`, and otherwise `unproven`. It is never attention or pass, and never fail on its own.
- **`settle_surfaces` (:1585).** `rebased_prior_held` is a converged origin, so the loop doesn't spin until the bound for a state it can't resolve.
- **Report text.** The docstrings and the check text (:1349, :1650) list the new origin.
- **Nothing else changed:** introduced and unattributed routes still fail once settled, and no false PASS has been introduced.

## Fixtures: confirmed exact
- The driver pins the utility SHA and parses it as AST, and `check` asserts exact equality (:4-7). All 56 cases pass.
- The new cases assert exact results:
  - origin `rebased_prior_held`
  - per-service `pass` → route `unproven`, `unproven` → `unproven`, `fail` → `fail`, `pending` → `pending`
  - an inactive location or disabled member → `introduced_by_applied` and route `fail`
  - a rebased endpoint mixed with an introduced one → `introduced_by_applied` and route `fail`
- The earlier cases (group outcome, preserved, introduced, unattributed, unknown, the verdict matrix, the leak check) are unchanged.

## Evidence the parent supplied
- 56/56 fixtures pass, and the AST parse passes.
- The elevated read-only `--inspect-only` run exited 0 with 5 checks passing, including 8/8 services equal to their applied values (`installed-lifecycle-bdq1ckkq/report.json`).
- The earlier non-elevated inspect failed `single_process` because it couldn't see the process, and made no changes. **The owner repeat should run with the same elevation as the passing inspect.**
- The 41 local gates completed with 0 failures.

## What R5 can and cannot show
- **Expected outcome:** one current prior is Conduit's loopback PAC. So if every recorded service is restored exactly, the expected global-route result is **ATTENTION** (`preexisting_prior_preserved`), not PASS. Other outcomes:
  - `rebased_prior_held`: something wrote between Stop and Start → unproven
  - `introduced_by_applied` or `unattributed` → FAIL
- **Limits:**
  - Services the journal doesn't record aren't judged.
  - Whoever publishes the global proxy view (a VPN or runtime publisher) is attributed only by exact match against a captured prior.
  - `applied_retained` after release means an applied value is present after release; it doesn't identify the writer.
- **R2 and R4 stay as they were:** the original reports are unchanged and aren't retroactive proof. R4's origin remains unattributed.
- **Ownership policy unchanged:** an untracked loopback setting is the user's (design `:44-45`, `LocationSettingsRecovery.apply` at `:255-256`). This verifier changes no product policy.

---

Parent execution clarification: require_escalated bypassed the Codex sandbox process-view restriction; it did not run as root. The owner executes the command in their normal Terminal login, without sudo.
