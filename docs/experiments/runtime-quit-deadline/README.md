# Quit deadline and optimized model correction

Product correction: 66c411d4e91823db8eeb255d55d615f22b4e6f82; explicit model-helper isolation: a9d28b2. Both implement existing policy, with no new wire, schema, dependency, capacity or clock interface.

The d038 hosted Swift suite completed3,768 tests / four skips with one no-stream Quit assertion failure. Its three-second fixture expected a settled result; an expired, failed or busy final read can honestly remain unsettled. The exact I/O cause was not established. The Release-packaging standard suite passed, but Swift 6.3.3's optimized test build rejected three mutable captures. Two local model helpers now explicitly retain the enclosing RuntimeActor isolation; model rules and assertions are unchanged.

Independent policy review found a separate concrete mismatch: only the logger respected Quit's original deadline; artifacts received a fresh six-second phase. One optional absolute cap now clips that existing phase; nil keeps the ordinary six seconds. Started physical work keeps its authority. The two no-stream completion fixtures use the selected ten seconds with every settlement, teardown and persistence assertion unchanged; the held-unsettled two-second guard is unchanged.

[Source review](source-review.md), [policy review](policy-review.md) and [author report](author.md) record scope and limits. Removal-only controls fail semantically: host propagation removal breaks the host and simulator guards, and phase-clamp removal breaks the phase guard. Exact bytes were restored. Normal focused 115, corrected strict 2 and optimized 148 tests pass; the restored simulator passes.

The first full workflow passed 40 checks but its ordinary nil-flush simulator exercise reported unconfirmed output. Its retained file was written late, but neither that file nor the discarded logger established whether a timeout, refusal or write error caused it. The failed workflow is preserved, and the initial diagnosis is historical, not a proven cause. A bounded in-memory warning recorder now adds fixed report outcomes/counters on failure. No assertion, budget or wait changed. [Independent review](sim-diagnostic-review.md) accepts this diagnostic-only delta. The baseline and instrumented isolated scenarios pass; the final coherent R2 workflow passes all 41 checks: 3,770 tests / four skips / 103 scenarios, with stable relevant source. A non-reproduction does not classify the earlier failure.

An overbroad one-thread attempt included three older fixtures that deliberately block the sole thread. It failed 8 assertions in 16 tests and is not a product regression or a passing gate. Those fixtures pass normally; the corrected strict scope contains the two new non-blocking guards and passes. Raw-log hashes preserve the attempts.

[Production Release results](production-profile/metadata.json) use clean stable66c411d sources and objects without enable-testing: seven fresh trials / 162 checks, every scratch root removed. The widest client Quit settles both final saves, closes its listener and clears the fake proxy in 929.3 ms of 10,000 ms. Six held-logger trials preserve ordinary drainage and independent control progress. These are FakeMachine production objects, not installed-app RSS or real-helper acceptance. Earlier f3 full-list/native measurements remain qualified to the unchanged paths they covered.

Final hosted Swift 6.3.3 optimized compilation, candidate rebuild and applicable owner-coordinated production acceptance remain gates. No production app/helper change, release tag or publication occurred.

The [source-to-commit link](source-commit-link.json) confirms that committed66c411d has the exact relevant-source fingerprint of the completed R2 workflow. Evidence prose was added afterwards.
