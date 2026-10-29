## Phase1c relay: final executed acceptance

**Phase1c (TCP relay over the host's PlatformWork) is accepted for the frozen r3 source.** I read only the executed artifacts in `runtime-actor-relay-r3-full-gates/`. I made no Source reads, builds, network calls or edits.

### What the artifacts show
- **`results.json`:** `source_sha256` and `final_source_sha256` are both `6b1efad9…6e371d0a`, and `stable` is true. All 41 checks exited 0. The link between this fingerprint and the r3 snapshot hash `509150e4…` rests on the parent's statement.
- **Swift tests** (`swift-tests.log:10623-10624`): "Executed 3713 tests, with 4 tests skipped and 0 failures", and "Test Suite 'All tests' passed".
  - The four skips are the same environment-gated ones as before: two need a live Kerberos ticket (`:7311`, `:7314`) and two are log-only resource probes (`:8704`, `:8711`).
- **The witnesses for both earlier failures passed:**
  - the listen-host test (r1's full-run failure), `:1326`;
  - the back-off test with its new barrier (r2's full-run failure), `:930`, in 13.1 s.
- **The other four tests moved behind the Quit join also passed:** `:850`, `:1067`, `:1119`, `:1526` and `:1589`.
- **Relay witnesses passed:**
  - DNS Stop while a reassert's start is held, `:7591`;
  - a tick while a reassert is in flight, `:7601`;
  - the host's held relay start on the platform queue, `:8087`;
  - the exit-flush audit retarget, `:2445`.
- **Simulator:** all 103 scenario outcomes are PASS, with no `[fail]` lines, and the sim-outcomes check passes.
  - In `relay-reassert-after-stop`, the held-start rows pass (`pm-sim-all.log:789-791`). The note records `held relay start ran on: io.github.srps.Conduit.pm-sim.relay-platform-work`.
  - In `runtime-host-effects`, the drop-order check from 1b still passes (`:2361`).

### What is accepted
- Relay commands go through the host's single PlatformWork, behind a kernel closure seam. There is no kernel queue and no new API.
- The DNS module's slot orders every relay command.
- The reassert probes outside the slot, then checks its epoch and generation again inside it, with at most one reassert in flight.
- `tcpRelayActive` changes only after a command lands, failures are logged as before, and a DNS Stop leaves the relay stopped.
- With no relay closure (pm-proxy), behaviour is unchanged.
- The dead termination path is removed, along with the `observability.audit_flush_timeout` row in the event catalogue.
- The test-only causal corrections (r2's Quit join and r3's setup barrier) weaken no assertion.

### Limitations carried forward
- **Relay latency:** relay commands can wait behind queued PlatformWork, including the relay stop during a terminal quit, which stays inside the quit budget. A stuck helper holds the DNS slot for up to its transaction budget.
- **No blind relay stop at quit:** a relay left by a crashed earlier run is replaced by `TCPRelayPlan` at the next DNS start.
- **Negative-artifact vacuity is still open:**
  - a completed Quit only joins a bounded flush attempt, so the post-Quit negative event checks can pass on a short file;
  - the credential test's snapshot read (`?? ""`);
  - the `config.workflow` witness, which the open's own startup event already satisfies;
  - the read inside the settings-flood loop.

  These are left for the diagnostics plan.
- **Test infrastructure:** when `HeldCall .recorded` lets a call through, the later release leaves a semaphore permit behind. The two slot witnesses each spend a bounded 500 ms on their negative windows.
- **Not covered by this run:** TSan, CI and real-helper validation. The control cluster is still MainActor; the logger, the whole-actor retag and the native work are not done.

That's my final report for this session. I'm leaving no further tasks open.