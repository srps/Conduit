# RuntimeActor preparation — 2026-10-28

This is preparation for [0031](decisions/0031-incremental-runtime-development-single-activation.md). The control cluster still runs on MainActor. The whole RuntimeActor move, native AppKit acceptance and applicable real-machine checks remain due. No release readiness is claimed.

## Changes

LaunchRecovery receives the host's existing PlatformWork rather than running blocking recovery on a Swift cooperative-pool thread. Configless recovery owns one scoped worker because no host exists. There is one recovery execution path; eligible surface work joins it. Recovery can defer later work on that serial worker, preserving ordering.

DispatchSource timer handlers are explicitly Sendable and hop from global dispatch queues to the owner under their captured generation. Repeating timers admit one pending hop per arm; uptime scheduling is preserved. Owner-created Tasks inherit isolation only in compiler-checked contexts. NIO callbacks and nonisolated ingress retain explicit hops. The terminal-exit hook and injected effect bundle become Sendable without changing entry-point policy.

Review also found [#260](https://github.com/srps/Conduit/issues/260): after Stop, the retained adapter restarted a cancelled NWPathMonitor and received no initial report. Three fresh-process probes observed the failure and a fresh monitor succeeding. The adapter now creates a monitor/debouncer per active lifetime, using its existing queue and one lock for generation/callback claims. Callbacks, start and cancellation run outside that lock. Read-only actual-adapter tests exercise restart; pm-sim separately exercises the fake host's observer lifecycle. There is no new factory, protocol, registry or test hook.

HeldCall's test-only tickets preserve a legitimate handover: a test can arm the next platform call before releasing the earlier one. An unheld call no longer releases another arm. Queue-label self-tests distinguish cooperative-pool work, and three harness teardowns reject that placement. The bounded MainThreadPark supports later isolation witnesses. Actual loopback audit tests exercise mixed-priority surrounding load, without claiming forced NIO callback reordering.

## Evidence

The [A2 author manifest](experiments/runtime-actor-preparation/stage-a2-author.json) records exact files, attempts, fixture correction and limits. The [snapshot](experiments/runtime-actor-preparation/stage-a2-snapshot.json) is stable: `674661b6b266852903bd31b90e254789929ea13b0f7f3bba40b0f6e3541757ad`; [raw artifact hashes](experiments/runtime-actor-preparation/stage-a2-run-artifacts.json) identify local logs.

- Old-adapter baseline: both restart assertions fail after the first report succeeds.
- Guard-removal control XURVaD: two coalescing assertions fail causally; a separate legitimate rearm exposed an unsuitable fixture restriction. The generation guard was restored and that restriction replaced with ticket handover.
- Restored mtaLd9: 643 tests and simulator runs pass, then catalogue validation rejects a prefix string. This is an incomplete gate, preserved separately.
- Corrected ZFzM5n: 643 focused tests, three simulator scenarios, imports, catalogue, decisions and diff checks pass.
- Scoped strict Q5sH02: 39 tests, two simulator scenarios and boundary checks pass with `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1`.

The earlier [A1 review](experiments/runtime-actor-preparation/stage-a1-source-review.md) and [all-41 workflow](experiments/runtime-actor-preparation/stage-a1-full-workflow.json) are historical evidence for the pre-correction source (3,738 tests, four existing skips, 103 simulator scenarios). The [A2 independent review](experiments/runtime-actor-preparation/stage-a2-source-review.md) accepts Source under the serialized-owner/concurrent-callback contract, with no P0/P1/P2 finding. It identifies three test-quality improvements for the actor slice: terminal release of every held fixture call, an owner-appropriate coalescing ordering witness, and a distinct callback/log for the restarted monitor. A stale timer-queue description is corrected alongside that slice.

The [complete A2 workflow](experiments/runtime-actor-preparation/stage-a2-full-workflow.json) passes all 41 checks on stable fingerprint `a871b84459561357b0871c4e81a025e7629e3c50c99fc8ed820dfa940ba096bb`: 3,741 tests, four existing skips and 103 simulator scenarios. It ran in an isolated checkout at `569f192`, with strict-pool mode explicitly removed from the environment. The [commit link](experiments/runtime-actor-preparation/stage-a2-commit-link.json) mechanically matches the frozen source/test/script blobs to source commit `345af207`; `569f192` adds only the already-merged AppState branch ancestry. Hosted checks and whole-actor acceptance remain separate. The earlier broad strict attempt used primitive fixtures that block their own sole cooperative thread; it does not establish a production failure, and caused no timeout widening or suppression.

## Limits

The 100 ms coalescing guard has an executed negative control under the current MainActor owner. That FIFO witness must change when isolation moves. The 0.1/0.2-second reprobe tests fire the changed timer; fixed 30-second relay and DNS-health timers are inspected rather than observed firing. NetworkMonitor's stale callback generation is inspected because the real adapter cannot be forced to deliver a late callback. A callback claimed before Stop may finish using its captured callback; the host's own token fence still applies.

Mixed-priority ordering must be checked again after the actor move. The three harness teardown checks do not cover every locally created hold. These results do not prove the whole actor cluster, parked-main framed progress, fair Stop/status under a full collection capture, shipping app memory, native AppKit termination or real-helper timing.
