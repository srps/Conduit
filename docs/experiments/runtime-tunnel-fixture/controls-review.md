## R2 tunnel test controls

**Verdict: ACCEPT.** I read `results.json`, the three control patches and the log lines. I ran nothing.

### What the logs show
| Run | Exact change | Result in the log | What it proves |
|---|---|---|---|
| Baseline | none | 10 + 14 = **24 tests, 0 failures** | The frozen R2 files pass the focused tests once, locally. |
| Closed admission removed | Only the `!record.closed` guard removed | **3 assertion failures, 0 unexpected:** `:266` "admitted, then failed with UnexpectedConnect()", `:273` "…with NeverReleased()", `:275` connect count 1 ≠ 0 | The closed flag is what refuses a dial after the join, in both the released and held branches. It is the only change, so this is a real guard witness. It runs without network and doesn't show that a late CONNECT actually happens in the integration test. |
| Release removed | Only `dials.release()` removed | **1 failure, the expected typed error:** `:245` "the OP_MSG at the target did not arrive within five seconds", after 6.519 s | **Error-cleanup witness, not a semantic guard.** The wait gives up within its budget, cleanup ends the held dial before any resolver starts, and there's no hang. |
| Completion barrier removed | `release()` and the bytes wait removed | **2 assertion failures, 0 unexpected:** `:218` bytes `[]` ≠ the 37-byte OP_MSG, `:221` `unknown` ≠ `mongodb` | The byte and protocol assertions depend on actually waiting for delivery. The detection log alone, which is what the old fixture waited for, would not prove the bytes arrived. Cleanup with the gate still held also worked here. |
| Restored | exact R2 bytes | **24 tests, 0 failures** | The files were restored exactly and pass again. |

Across all five logs I grepped for `Fatal`, `leaking`, `Cannot schedule`, `crash`, `Cleanup failed` and failures of the `tearDown` `XCTAssertNoThrow`. None appear. That matches `crash_marker: false`.

### Limits
- Each check is one local run. They show the guards work and that cleanup behaves on these paths. They don't prove there's no leak under every timing, and they say nothing about hosted Swift 6.3.3 or the optimized build.
- **The historical CI crash's cause is still unproven.** These results show the new fixture removes the in-flight-dial shape at shutdown, not that this shape caused the f59 crash.
- The forwarder's own pool dial is still not joined. That stays a stated, accepted limit.
- The all-41 run (12950) is still in progress, and hosted CI on the new head is still owed. I count neither as passed.