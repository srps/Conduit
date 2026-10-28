All five required corrections are in the live docs and are accurate. Of the two optional ones, the gate-list part is done in all four places I named. Two items under the second optional correction were not applied; they are minor, factual and not blocking.

## Required corrections: all applied

1. **`ROADMAP.md:208`** now says 3,766 tests, matching `verification-runtime-actor-activation-2026-10-28.md:19`.
2. **`0031…:272`** is now marked as an intermediate checkpoint, with implementation partial at that point and completed in the next section. That is consistent with the header (implemented / pending) and with `:276`.
3. **Resource acceptance is no longer described as open:**
   - `design-runtime-adoption-cut-review.md:17` now says "resource fairness is accepted", with the test-maintenance workflow, hosted and real-machine acceptance still due.
   - `0038…:111` now says final-source resource acceptance passes. It also carries the custody caption: a small-kind capture can keep an unselected larger collection alive, and neither the row cap nor the encoded accounts bound the whole frozen value or app RAM.
4. **`docs/experiments/actual-runtime-client-profile/README.md:124`** now points to the f3abd5f run: ten seconds selected, 907.1 ms with fake effects.
5. **The optimized row (`verification…:22`)** now says XCTest with testability, run on the dd9d1b test text before the compatibility patch, which changed only the helper-call spelling. The fixture rounds since then didn't touch that file: its hash is still `c509cb…` in both the r1 and r2 manifests.

## Optional corrections

6. **Done:** `design-runtime-host-contract.md:354` now says older storage of any snapshot collection, including an unselected larger one, can stay alive, and that there is no whole-value RAM bound.
7. **Partly done:**
   - The gate lists are fixed: `ROADMAP.md:36`, `ROADMAP.md:208`, `0031…:276` and `verification…:48` all include the complete local workflow on the test-maintenance head.
   - **Not applied:** the "Remaining work" cells at `ROADMAP.md:33-35` still list finished work:
     - `:33` "Verify AppState consumes that owner without a parallel path." — `verification…:3` and `0031…:276` say the replaced paths are deleted.
     - `:34` "…consume it through the native-client completion below."
     - `:35` "…consume it with the production composition." — 0039 is implemented, and the f3 run uses the selected ten seconds.
     Suggested fix: point all three to the row-36 gates, or say "done in the RuntimeActor activation".
   - **Not applied:** `kernel-cow/README.md:3` still says "use the final production Release objects". Its `results.json` records only the source hash, not per-object hashes. Suggested: "…link the f3 Release objects folder (per-object hashes not recorded)."

## Paragraphs you're holding as pending

These are correct as interim text and I'm not reporting them as findings:
- `verification…:44` says the fixture path is "under correction" and the interrupted run is not a pass.
- `verification…:20` gives the 57 strict tests on the product checkpoint; the 104-test strict run belongs to the test-maintenance head.

When full41 finishes, the `:44` text should point to the accepted r2 fixture and the terminal full41 result, as you planned.