**Accepted.** Both required corrections from r1 are made, and I found no factual problem that blocks acceptance. I only read files: no edits, no commands, no GitHub queries.

## Correction 1: hosted 6cb record
`hosted-6cb.json` now has what r1 asked for:
- **Head and time:** `6cb3657`, observed 2026-10-29T08:34Z.
- **Swift:** run 40747764885, job 123026015244, `success`. This replaces the "still running" status r1 flagged.
- **Release:** run 40747764902, job 123026013386, `failure` in the standard Debug suite, with `optimized_reached: false`. It includes the summary line `Executed 3770 tests, with 4 tests skipped and 2 failures (0 unexpected)…` and points to `hosted-6cb-assertions.txt`.
- **Slow-drain:** run 40747764869, job 123026016525, `success`.
- **CodeQL:** summary, actions and python job IDs, `success`. The scope field says this is not a complete security diff review, and the annotations field records the 300-file diff limit.

So the "passes" sentence at `ROADMAP.md:57-58`, verification doc line 5 and README line 3 are now backed. The Release counts (3,770 tests, four skips, two failures, optimized build not reached) match all three docs.

## Correction 2: candidate status
`candidate-rebuild.json` records:
- commit `97a5b43`, version 0.6.0 and the executable SHA-256
- strict/deep signature check and the early read-only helper preflight, both exit 0 at 19:49 UTC
- `runtime_started: false` and `installed_or_replaced: false`
- the archive SHA-256, size and a passing ZIP integrity check
- the scope "Local Conduit Local Signing acceptance candidate, not release-certificate artifact"

`ROADMAP.md:52-54`, verification doc line 13 and README line 11 now say rebuild, signature check and preflight passed, and that the candidate is archived, unlaunched and uninstalled. That matches the JSON. All three still say final-head hosted checks and owner acceptance are pending, and the owner Quit and rollback constraints at `ROADMAP.md:62-65` are unchanged.

## Optional wording fixes (not required for acceptance)
1. **Release summary source:** the `hosted-6cb.json` scope says the Release summary was "retained from archived full job log", but no full job log is in this archive. Saying where that log lives, or "from the full job log", would be more accurate.
2. **Signature and preflight evidence:** `candidate-rebuild.json` records these only as "observed separately". It keeps no log hash or output excerpt, unlike the control evidence. The claim is recorded, but it's weaker evidence than the rest of the archive.
3. **CodeQL qualification:** `ROADMAP.md:57-58` says "passes … CodeQL" with no qualifier. The note that the diff limit was hit and this isn't a full security review is only in the JSON. Nothing in the docs claims more than a passing check, so this is accurate as written.
