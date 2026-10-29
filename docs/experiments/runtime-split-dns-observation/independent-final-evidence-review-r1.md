**ACCEPT once two small corrections are made.** The counts, the source checks and the scope limits all match the archive, and none of the owner constraints were lost. I read the listed docs, the archive files and the current roadmap paragraphs. I edited nothing, ran nothing and made no GitHub queries.

## Necessary corrections
1. **The hosted 6cb passes have no record in the archive.**
   - The verification doc (line 5), the README (line 3) and `ROADMAP.md:56-57` all say the complete Swift workflow passed at 6cb. The roadmap also says slow-drain and CodeQL passed.
   - The archive holds only `hosted-6cb-assertions.txt`, which is the two failure lines. It has no run or job IDs and no conclusions for Swift, slow-drain or CodeQL. It also lacks the Release summary line backing "3,770 tests, four skips".
   - Your last status before this said the Swift workflow (job 123026015244) was still running.
   - **Fix:** add a `hosted-6cb.json` in the same shape as `hosted-f59.json`: run and job IDs, conclusions, observation time, and the Release `Executed 3770 tests, with 4 tests skipped…` line. If slow-drain or CodeQL weren't actually observed as passing, take them out of the roadmap sentence.
2. **`ROADMAP.md:52-53`:** "An exact-source mechanical candidate rebuild and its preflight are in progress" overstates where things are. Only the rebuild (22028) is running; signing and the early helper preflight haven't started.
   - **Fix:** "An exact-source mechanical candidate rebuild is in progress; signature verification and the early helper preflight follow."

## Verified
- **Provenance:**
  - `full-workflow.json` has 41 checks, all exit 0, `stable: true`.
  - Its source fingerprint `d212ee55…` matches `source-commit-link.json`, which shows `matching: true` for 97a5b43 and production non-doc lines identical to 6cb.
- **Counts:**
  - 3,771 tests with four skips (the previous 3,770 plus the one new unit test), with a hash.
  - The 103/103 simulator records, with a hash.
  - Optimized: 106 tests (the earlier 90 plus 16 `SplitDNSEntryFileRepairTests`) plus 1 gated host test = 107.
  - Ten fresh Debug runs, each executing one test.
  - The optimized build used `-enable-testing` and is never called production.
- **Controls:**
  - `control-summaries.json` keeps the exact failure lines.
  - Hold A's 10 failures are all intermediate assertions, so "ten intermediate" is accurate. Hold B fails 4, and the guard omission fails 4.
  - The doc states that the guard control ran only the new unit case and that the gate controls don't reproduce the CI reversal.
- **Qualifications:**
  - The record order is described as implied by the CI assertions, not observed, and the scheduler/priority cause is described as not captured.
  - The ten unmodified runs are called non-reproduction, matching the scope field in `unmodified-ten-fresh.json`.
  - The doc says Swift 6.4 is no substitute for hosted 6.3.3.
  - No FIFO mechanism, policy, API or budget change is claimed.
- **Owner constraints (`ROADMAP.md:59-64`):**
  - The owner's manual Quit of 0.5.8 and approval of the stable Applications installation, with the login-item reason.
  - Rollback to the preserved 0.5.8, never the inactive 0.5.5 copy.
  - No installed-app acceptance claimed.
  - The verification doc has a shorter version that leaves out 0.5.5, which is fine because the roadmap has it.
- **Candidate:** the docs say a rebuild, signature check and preflight are required. They claim no new candidate pass, no install and no publication. Existing resource and native evidence stays limited to unchanged behaviour. `ROADMAP.md:190` keeps the earlier-head wording.
