The final results qualify as evidence for f3abd5f once three captions are added. I found no blocker and nothing that needs a rerun beyond the pressure-only label rerun you already planned. I checked everything below from the raw files, not from your parsed summary. I can't write files from this session, so `runtime-final-evidence-initial-review.md` is untouched; please keep it as you said. My initial notes stand, with the corrections below.

## Production profile, all 31 trials (Probe af37, Source f3abd5f)

- **Build and run:** the release build and the run.py command both exited 0 in `build-and-probe.json`. The source hash was `dd9d1b…` before and after, and marked stable.
- **Provenance in `metadata.json`:**
  - HEAD f3abd5f; product sources clean; 0 untracked product files; product source fingerprint `732c7d…`.
  - Sources and linked objects were unchanged during the run.
  - The probe hash is `af37b3ce…` and the runner hash is `2ae0f902…`, the frozen ones.
  - `compile.log` is empty, and the link command has `-swift-version 6 -O`.
- **Every mode:** all 31 trials exited 0, with no truncated output, 0 label violations and scratch removed. All 31 summary records show `failedChecks:0`, `inconclusive:[]` and `released:true`. No file has a `"passed":false`, inconclusive, `pinned` or `emit-error` record.
- **Cancel (I read it myself):**
  - case (a): `client.notSent.deadlineExpired`;
  - case (b): `client.notSent.cancelled`;
  - case (c): `client.notSent.deadlineExpired`, then lookup `unknown.not_recorded` and recovered outcome `none`;
  - every hold flag is `true`, the next update settled, the host was deallocated and the lease was reacquired.
- **Lane window:**
  - reads: 4 served, 4 refused `transportBusy`;
  - ordinary commands: 4 `transportBusy`, 4 `queue_full`;
  - both fill flags `true`, the hold stood after the callers were spawned, and the Stop sent in the window was `accepted`.
  - So the owner-held claim is witnessed here, not just passed vacuously.
- **Widest client Quit:** the routine took 907.1 ms of its 10,000 ms total, with 534.2 ms from release to return. The Quit completed, the listener closed, the fake system proxy cleared and the host reported the proxy down.

**Captions this evidence needs:**
1. **Erratum for af37.** `connectionsOpenedByProbe:0` is a hard-coded value, but `Probe.swift:3847` makes one connect-only liveness check against the listener. It sends no bytes and is closed before the pages are read. The same record shows `activeConnectionsTotal:0`, so that connection was gone by page time.
2. **Real-host pages are empty pages only.** All four collection kinds returned a page with total 0. There is no full capture, no over-bound case and nothing near 10k on the real host.
3. **Cancel release is bounded from above only.** All three cases have `busyRefusals:0` and `lastBusyRefusalMS:-1`. The probe waits for the hold to end before it retries, so it shows only that the transfer was free again within about 1.1–1.7 ms. It never observes the reservation still held after the caller returned. The owner-held evidence comes from the result labels and hold flags, not from these bounds.

## Optimized XCTest, 3 fresh trials

- The command was `swift test -c release -Xswiftc -enable-testing` with its own scratch path, so the shipping Release objects were left untouched. Each trial ran 15 tests with 0 failures.
- The fairness tests measured 10,000-row projections of 0.465, 0.519 and 0.505 s. Status and Stop answered 0.249–0.295 ms after being issued. `statusAfterProjection` is negative in every trial, meaning status answered before the projection finished.
- The client-side app collection took 0.75–0.84 s per 47-page pass of 10k rows. The heartbeat's worst lateness was 6.6 ms, with nothing over 16 ms.
- **Scope:** this is XCTest with testability and a fake owner. The RSS figures are for the test process, not the app.
- **Minor:** `results.json` records only the `dd9d1b…` source hash, not the commit. That's enough because the production metadata ties the same hash to f3abd5f.

## Kernel copy-on-write one-off, 3 fresh trials

- It ran against the same Release objects folder with Swift 6 and `-O`, and `compile.log` is empty. The numbers were identical across trials.
- At 10,000 rows:
  - the row stride is 120 B;
  - one activity update copied 1,212,416 B, taking 153–168 µs;
  - one remove copied the index, 409,536 B;
  - ending the second holder freed 1,622,144 B.
- The program's own scope string is accurate.
- **Caption:** shared string storage is not counted, because the copies retain the same strings. These are figures for the kernel value type, not the actual capture flight, app RAM or a bound.
- **Stale header:** `kernel-cow-observation/README.md:1` still says "(written, not compiled or run)".

## Still pending: the corrected probe

I won't accept a new probe hash until both of these arrive:
- **The diff:** limited to the `connectionsOpenedByProbe` label and its comments (`:3877`/`:3880`, plus the `:2306`/`:2882` wording if you touch them), with no change to methods, timing or instrumentation.
- **The pressure-only rerun's `metadata.json`:**
  - HEAD f3abd5f, product sources clean, fingerprint `732c7d…`;
  - runner `2ae0f902…`;
  - each object hash equal to the 31-trial run's `objects`, so the debug build must not have touched the Release objects;
  - a clean pressure summary, and the new probe hash recorded.