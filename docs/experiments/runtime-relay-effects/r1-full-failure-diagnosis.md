I've verified the causal chain the fix relies on against the frozen code, still read-only. The diagnosis stands, and I don't think a diagnostic run or any instrumentation is needed: the existing log already contains the facts that settle it.

## Why it failed
- **The production path completed:**
  - `ProxyOrchestrator.swift:803` appended `config.proxy_restart` to the host's in-memory event log, in the same turn as the log line at `:804` (`swift-tests.log:1224`, `.175`).
  - The restart then stopped the old listener (`:1225`) and bound `::1:53010` (`:1226`, `.176`).
  - The test's `proxyHost == "::1"` settle passed, so the restart's `startProxy` had completed.
- **What the test reads instead:** the assertion at `:473` reads `events.ndjson` from disk (`AppStateHarnessTests.swift:130-132`). The host's `RuntimeEventFileWriter` writes that file on its own utility queue, some time after the in-memory append. Nothing in the test waits for that write. The settle observes a different path, the framed snapshot. Under full-suite load the file read ran before the queued record was written, so the count was 0.
- **The receipt sequence is normal:** `baseline_mismatch`, then `persisted`. It isn't involved, and relay 1c isn't on this path.

## The causal completion
The app's Quit settles only after the host's diagnostic flush:
- `admitQuit` runs `await flushEvents()`, which awaits the event writer's drain through `DiagnosticFlush.run`, and only then calls `flush?.quitDidEnd()` (`RuntimeHostLifecycle.swift:1017-1018`).
- `RuntimeQuitFlush.settled()` returns true only through `quitDidEnd` before the deadline (`RuntimeQuitFlush.swift:85-99`).
- The quit operation reports `completed(.quit)` only when `settled()` is true (`RuntimeHostControlOwner.swift:287`).
- `config.proxy_restart` was queued on the writer before the rebind, so before the quit was admitted, and the quit's drain covers everything queued when its wait began.

So once `finishQuit()` returns `.settled(.completed)`, the record is on disk, unless the writer actually lost it. A real loss would still fail the test and would show as `observability.writer_loss`.

## Plan, test only, after release
`AppStateActivationParityTests.testCommittingAListenHostLeavesTheDNSForwarderOnLoopback`:
1. Keep, unchanged: the settle on `proxyHost == "::1"` and the three DNS assertions (`dnsRunState == .running`, `dnsHost == "127.0.0.1"`, `dnsPort` unchanged). They must stay before the quit, because the quit stops DNS.
2. Add `XCTAssertTrue(state.beginQuit())` and `guard case .settled(.completed)? = await state.finishQuit()?.quit else { return XCTFail("the quit completed and confirmed its flush") }`. This is the same pattern as `AppStateHarnessTests.swift:387-388`.
3. Then assert, unchanged: `hostEvents(harness, "config.proxy_restart").count == 1` and `hostEvents(harness, "config.dns_restart").isEmpty`.

No polling of the asserted event and no sleep. The exact count also catches a double restart, and the negative DNS check stops being vacuous. Teardown's quit joins this one safely, since `beginQuit()` returns false the second time.

**Remaining risk:** the quit can still report completed when the event writer's drain timed out (`DiagnosticFlush` caps each wait at 2 s). In that case the assertion fails, which is a genuine finding, not a fixture flake.

**Verification after release:** one targeted run of this test plus the wrapper, then your full workflow. No blind rerun.

**Out of scope unless you ask:** the other unsynchronized file reads in this file (`:556`, `:725`, `:751`, `:903`, `:915`) and the 100 ms sleeps at `:724` and `:902` have the same latent race. They could move to the same post-quit read with assertion parity, but they pass today.

Waiting for release. The diagnostic plan resumes after this is settled.