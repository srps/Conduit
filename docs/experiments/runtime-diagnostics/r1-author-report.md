The diagnostic feature is implemented and green on the fixed wrapper, and Source is frozen. The run directory is `runtime-actor-prep-focused-LNZR7Y`; the wrapper exited 0.

**Results**
- **Tests:** 539 focused tests ran with 0 failures.
- **Simulator:** `runtime-host-effects`, `relay-reassert-after-stop` and `bounded-writers` all pass.
- **Checks:** the kernel-import, event-catalogue and decision checks pass, and so does `git diff --check`.
- **Manifest:** `/private/tmp/conduit-runtime-stage1-20261024/runtime-diagnostic-manifest.json`. It lists every file and the earlier failed runs.

**What the tests showed on real paths**
- **App Quit with the file log held:** the held line waits inside the internal app-log guard wrapper, which delegates to the protected-file guard.
  - The host's logger drain times out at its 2 s cap and records `source=host outcome=timed_out`.
  - The app's own final drain then gets `busy`, records `source=app outcome=busy`, and doesn't wait again.
  - The Quit still completes inside its budget (the test took 2.26 s). After release, every held line reaches the file and nothing is dropped.
- **Quit past its deadline:** with a 1 s Quit, the app records `skipped_budget` and the whole Quit ends in about 1.03 s. That shows no step gets a fresh budget.
- **Host stays responsive:** while the host's logger drain is held, a framed status read and a Stop admission are both answered. The drain ends `timed_out` and the Stop settles.
- **Kernel file writer:**
  - With its open held, it drops exactly the writes past its bound and reports `timed_out`, then `busy`, then `drained` after release.
  - A deadline that has already passed gives `skipped_budget`.
  - Close still writes what it had already accepted; a later write is counted as dropped and the file never reopens.
  - The simulator shows the same with the default limits: 4096 of 4106 lines accepted and exactly 10 dropped.
- **App log store:**
  - A 3000-line burst while main is blocked reaches the file without main and schedules one UI drain. The newest lines show up afterwards, and the UI trim is not counted as loss.
  - Lines logged off main and on main keep their order.
  - A drain timeout that happens across a Settings toggle is counted once, and no counter goes backwards.
  - A sink that doesn't implement the drain reports `unavailable`.
- **Other:** the logger outcome is kept out of `allConfirmed`, the ready file holds the status read at readiness and lands no later than the snapshot, and the typed/wire tables cover round-trips, a refused `drained` or unknown source, and an unknown newer type read as informational.

**Choices I made within scope**
- The store counts a timeout once for each timed-out wait it sees; the writers' own timeout counts are left out of its total.
- A line that reaches a closed writer is counted as dropped.
- `RecordWriterStatistics` has no initializer usable outside the kernel, so the store folds closed writers' counts into its own private counter. The kernel type is unchanged.
- The `LogSink.flush` default is unchanged; only `drain` defaults to `unavailable`.

**Left for you**
- Full41 and the full workflow.
- `scripts/test-event-catalogue.py`, which the wrapper doesn't run. It doesn't pin a typed-name list, so I don't expect it to need changes.
- `docs/design-runtime-host-contract.md` (around line 479) still lists the old `LifecycleEvent` cases without `logFlushUnconfirmed`.
- Decision evidence and the shipping resource/latency measurement.
- I didn't run Git, so the base commit `0aa744a` is as you reported it.

I edited the delegated rows: the typed-name list in `check-event-catalogue.py`, and in `docs/events.md` the typed payload row, the count (now six), the catalogue row, and the `writer_loss` console description.