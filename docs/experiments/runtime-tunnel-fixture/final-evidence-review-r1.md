**Verdict: ACCEPT, with two small wording fixes and one gap to decide on.**

Nearly all the counts and claims hold up against the archive. I couldn't run `git diff` because I only had Read/Grep, so I checked the roadmap as it now reads rather than line by line against HEAD.

**Matches the evidence**
- **Local workflow:** `full-workflow.json` lists exactly 41 checks, all exit 0, with `stable: true`. The source fingerprint `ac3e7adc…` matches `source-commit-link.json`, which also shows `matching: true` and no product paths changed since e120.
- **Test counts:** `test-summaries.json` backs 3,770 tests with 4 skips, the 90 optimized tests, and the 10 single-test fresh Debug processes. `ProxiedTunnelTests.swift` has 10 tests, which fits the 10 + 14 = 24 focused runs and the "ten pure tests remain" claim.
- **Controls:** `controls.json` and `controls-review.md` agree with the verification doc and README:
  - removing the closed guard gives 3 assertion failures;
  - removing release alone is described as the missing-signal error-cleanup witness, not a semantic guard;
  - removing release plus the byte wait gives 2 failures;
  - baseline and restored runs each pass 24 tests;
  - no crash markers in any run.
- **Hosted f59:** `hosted-f59.json` backs the passes for the complete Swift workflow, slow-drain and CodeQL, and the Release crash in the standard Debug suite before optimized compilation. The origin is stated as unproven, and the README credits the observation to the parent's tools rather than claiming an independent GitHub query. This resolves the one condition in `document-scope-review.md`, and its optional "showed no … marker" wording is adopted in README line 7.
- **Scope:**
  - The optimized build ran with `-enable-testing` and is never called production.
  - Swift 6.4 is kept separate from hosted 6.3.3.
  - The IP-literal pool dial is a stated limit, and nothing claims to prove Stop/quiescence.
  - The production checkpoint stays 66c411d (seven trials, 162 checks, 929.3 ms out of 10 s, fake effects).
  - No installed-app, RSS or physical Stop latency claims.
  - The Quit doc's new last sentence is correctly scoped.

**Corrections needed**
1. **`ROADMAP.md:50–51`:** "its Release suite crashed in a legacy fixture" places the crash more firmly than the evidence does. Use something like "its Release standard suite crashed while a legacy fixture was active (origin unproven), before optimized compilation". Every other artifact keeps this qualified.
2. **`ROADMAP.md:179–180`:** "Release/resource trials, native Dev checks and hosted CI pass; installed real-machine acceptance is pending" reads as if all hosted CI has passed. Hosted Release failed at e120 (optimized build) and at f59 (standard suite), so this contradicts lines 52–53. Scope it to the earlier head (for example, "earlier-head hosted CI pass; final-head hosted standard/optimized checks and installed real-machine acceptance remain"). I can't tell whether this line is part of the current diff, but it's inconsistent either way.

**Your call: owner constraints in the roadmap**
- The current roadmap text doesn't mention the owner's manual Quit of serving 0.5.8, the approval for the stable Applications handoff, or the login-item reason for it. They are recorded in the linked Quit doc (line 11) and tunnel doc (line 13), so they aren't lost from the repo.
- The rollback target (stable 0.5.8, never inactive 0.5.5) appears nowhere in the repo docs I searched.
- If these should survive in the roadmap, a clause at lines 53–54 would cover it: "…after the owner quits serving 0.5.8 and approves the stable Applications handoff; rollback is to 0.5.8".

**Small provenance gap (optional)**
The figure of 103 simulator scenarios rests only on your observation. The archive records `pm-sim all` exit 0 but no count line. Adding its summary line and hash to `test-summaries.json` would back it the same way the 3,770 count is backed.

Nothing else needs changing. Final-head hosted standard, optimized and packaging checks, plus real-machine acceptance, are correctly listed as still required.