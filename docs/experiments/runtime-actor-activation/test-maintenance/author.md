I made the fix the review required plus your buffering change. The final `transport` and expanded `strict` runs both passed. The fixture is frozen, and no Source, module, CI or toolchain file changed.

**Edits (test files only, no assertion changed):**
- **Cancellation test** (`testACancelledDriverEndsItsWaitingCallAsCancelled`): after `held.untilHeld()` it now checks `hasWaitingDriver`. If no driver is waiting, it opens the job and fails. The order is now cancel, open, then await the result, with no suspension between cancel and open.
- **`untilHopQueued` doc comment:** `ended` runs under the queue's lock, so it must not read the queue.
- **`runCall` doc comment:** it assumes an empty queue at the start and drains once, so every hop the call needs must already be queued.
- **`HeldJob`:** both streams now use `bufferingPolicy: .bufferingNewest(1)`. Each is a one-shot signal, so nothing buffers without limit.

**Runs:**

| # | Mode | Output dir | Exit | Result |
|---|---|---|---|---|
| 1 | transport, negative control | `IXRdHQ` | 1 | Only failure: `RuntimeManualSchedulerTests.swift:99` "a cancelled page is not answered", 2.150 s, no hang. The other 28 passed. |
| 2 | transport (before buffering change) | `vIcixv` | 0 | 29/29 |
| 3 | strict (before buffering change) | `RUTnJW` | 0 | 104 tests, 0 failures; both sims passed |
| 4 | **transport, final** | `i0sE8L` | **0** | 29/29 |
| 5 | **strict, final** | `uneOcl` | **0** | 104 tests, 0 failures, 12.794 s. Ledger 32/32, ManualScheduler 2/2, Transport 13/13. Both sims passed. |

- **Negative control:** for run 1 I temporarily removed the driver's cancel handler. With the guard and reorder in place, the regression now fails instead of hanging, as the review predicted. I put the handler back before run 2 and checked that no control marker was left.
- **Strict test count:** the expanded strict filter ran 104 tests, not about 72. The extra ones are the 32 `RuntimeCollectionLedgerTests` you added.

**Notes:**
- **Ledger case:** the `RuntimeCollectionLedgerTests` suite includes the reviewer's leftover `harness.page()` case, and all 32 passed on the one-thread pool. `harness.page()` itself is unchanged, and its spurious-failure risk stays as a follow-up.
- **Failed control:** as the review asked, the record says the earlier failed control (`2HrEh6`) shows the defect itself, not the final test's exact assertion.
- **Not run:** I didn't rerun the broad 798, since nothing new failed.

The mode file is left at `strict`. The frozen set is `RuntimeServiceFixtures.swift`, `RuntimeServiceTransportTests.swift`, `RuntimeManualSchedulerTests.swift` and `/tmp/conduit-testcompat-driver-fix-report.md`, which now records this round as runs 5–9.