## Review of the tunnel fixture README

**Verdict: ACCEPT once one fact on line 3 is confirmed or qualified.** I read only `docs/experiments/runtime-tunnel-fixture/README.md`, plus a one-line check of `release.yml`. I edited and ran nothing.

**Fix needed on line 3**
- "The separate complete Swift workflow passed at the same head" goes further than anything I've seen.
- The last status you gave me was that Swift's full suite passed and its later checks were still running.
- If hosted Swift job 122991227162 has since finished green, the sentence is right. If not, change it to "the separate Swift workflow's full test suite passed at the same head".

**Confirmed**
- **The historical cause stays qualified.** Line 3 says "the exact historical source remains unproven", and line 9 says attribution stays qualified even after passing runs.
- **"Standard Debug suite" is accurate:** `release.yml:47` runs plain `xcrun swift test`, which builds in debug, before the optimized build at `:53`.
- **The 5 s budget is described correctly.** Line 7 calls the five-second signal timer a nominal test budget and separates it from whole-case and process durations.
- **PostgreSQL narrowing is explicit.** Line 5 says the PostgreSQL integration case is removed and classification keeps only unit coverage.
- **No production claims.** Line 9 says there are no changes to production source, API, policy or runtime budgets. The pool's IP-literal dial is stated as a scoped limit, explicitly "not proof of every production Stop/quiescence interleaving".
- **No pass claimed for later gates.** The complete workflow and optimized checks are described as still running or pending, and local Swift 6.4 is not taken as proof of hosted 6.3.3.
- **The control descriptions match the logs I reviewed:**
  - removing the closed guard fails three semantic assertions;
  - removing only the release is labelled the error-cleanup witness, not a semantic guard;
  - removing the release and the bytes wait fails the byte and classification assertions;
  - baseline and restored runs each pass 24 tests.

**Optional nit**
- "No control crashed, hung or leaked a promise" rests on single runs whose logs have no crash or leak markers. "showed no crash, hang or promise-leak marker" would match that scope more exactly.

**Still open**
- The all-41 run (12950, currently at pm-sim-all), the optimized build, the fresh repeats and hosted CI on c6e2c41.
- Real-machine acceptance.

None of these is claimed as passed.