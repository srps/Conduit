**r1-to-r2 delta: ACCEPTED.** It needs no code fix, so the full41 run can continue. I reviewed only the delta: `r1-to-r2.patch`, `manifest.json` and the author's report.

- **The required fix is in:**
  - The cancellation test now checks `hasWaitingDriver` right after `held.untilHeld()`, using the same open-then-fail guard as test 1.
  - The order is now `page.cancel()`, `held.open()`, `await page.result`, with no suspension between the cancel and the open.
  - The comment correctly gives the reason: the cancel resolves the wait first, and a call the cancel didn't reach is answered by the commit hop, so the test fails instead of hanging.
- **The negative control witnesses it:** IXRdHQ removed only the driver's cancel handler. It produced the one expected failure ("a cancelled page is not answered") in 2.15 s with no hang, and the other 28 tests passed.
- **The `.bufferingNewest(1)` change is safe:**
  - `entered` is consumed exactly once per test through `untilHeld`, so a single-slot buffer keeps the one signal that matters.
  - `opened` is never yielded to and is only ended by `finish()`. A finish is delivered whatever the buffering policy, and after it `pass()` returns at once.
  - So neither signal changes and there's no unbounded buffer. Whether several tasks consume one stream is unaffected by this change, and these tests run one flight before the open.
- **The two comments are correct.** One optional wording fix each, not required, and they can wait until after the gate:
  - `untilHopQueued`: "must not read this queue" could say "must not use any `ManualOwnerScheduling` accessor". `pendingCount`, `queuedHopCount` and `hasWaitingDriver` all take the same `NSLock`.
  - `runCall`: "every hop the call needs is queued before it" could say "is queued before that drain, or by hops it runs; hops queued later from off the owner are not run".
- **Scope:**
  - The manifest shows an empty production module diff, so f3 is unchanged.
  - `RuntimeServiceTransportTests.swift` (`9a01de…`) and `RuntimeActorFairnessTests.swift` (`c509cb…`) have the same hashes as r1. Only the fixtures and the manual-scheduler tests changed.
- **Final runs, as reported:**
  - transport i0sE8L: 29/29;
  - strict uneOcl: 104 tests, 0 failures. That includes the 32 Ledger tests, so the `harness.page()` test also has a one-thread-pool pass.
  - The polling risk in `harness.page()` stays a documented follow-up for test cleanup.

With r2 accepted, the remaining gates are the running full41, exact-head hosted CI on the older compiler, and applicable real-machine acceptance. Whenever you want, I can do a targeted check of the five plus two doc corrections in the live files.