# Shared RuntimeHost extraction: verification checkpoint

Date: 2026-10-24. Scope: behavior-preserving extraction after the client/event
foundation in [PR #220](https://github.com/srps/Conduit/pull/220).

## Identity and complete checks

Verified commit `c0cb18ebec83ba5e44aa461ee2c6407446432c88`, relevant-source SHA-256
`bc77e6e81a5489c71e015a43cb862e256fa1ebb70dbfddf783d8a28a4ddc695e` before and after all 39 workflow-equivalent gates.
All checks passed: build, compiler import fences/fixtures, notices/events/decisions,
full tests, worker and argument/signing/dev-bundle scripts, both stand-in updater
variants, security/routing/HTTP/resource/shutdown regressions, simulator outcomes,
all 85 simulator results and perf. XCTest ran 2509 tests, with 2 skips
and 0 failures. Rebase afterward added only foundation documentation;
Codex recomputed the source fingerprint and confirmed it was unchanged.

Commands follow [swift.yml](../.github/workflows/swift.yml), with Xcode's
DEVELOPER_DIR. Complete per-check logs and results.json are local under
`/private/tmp/conduit-runtime-stage1-20261024/host-full-gates/`; the command manifest
is `host-full-gates.py` beside it. No serving app/helper was stopped or replaced,
no helper installed, and no VPN was needed. Temporary logs are local evidence.

## Change and review

`DaemonRuntimeHost` moved into ConduitRuntime as `RuntimeHost`. The daemon keeps
arguments, configuration loading, signals, status output and process exit. It
injects process start time and a terminal-exit hook at the original exit position,
before the lifecycle defer. The reported start now comes from main entry rather
than a lazy static first read. MainActor and current lifecycle/recovery/reconcile
policy remain. The app and updater gain no host dependency; AppState is still a twin.

NetworkPathObserving lives in PlatformMac, with a lock-guarded fake in
PlatformFakes. Setup/start/stop remain confined to the runtime owner; callback
values may cross queues through the existing delivery adapter. No unchecked
Sendable conformance was added to NetworkMonitor. The migrated FakeMachine suite
explicitly injects the fake, including an explicit initial report where a test
previously waited for the machine's ambient notification.

Claude implemented and verified on the owner's claude.ai Max subscription.
Codex compared the actual move after normalizing names: code changes are access,
composition and the observer seam. Independent subscription-backed Claude review
found no demonstrated extraction regression. Review corrected the new exit-order
test to delete the prior snapshot before asserting a newly written terminal one;
the status test joins launch recovery and stops before scratch cleanup. The
185-test focused suite and three lifecycle/repair scenarios passed, followed by
the complete 39-gate run above. These checks do not prove every terminal overlap.

## Remaining limits

- No async client/admission/subscription engine, AppState adoption, RuntimeActor
  migration, persistence lease or save-before-apply behavior is implemented here.
- Wake input and app/host observer-start differences remain adoption work. Keep
  the twin suites until parity; do not infer parity from moving a file.
- Review flagged existing monitor cancel/restart semantics for verification before
  repeated-host start adoption, signal installation after startup, and the broken-
  config resolver-recovery limitation. These were not changed or causally proved
  by extraction. Existing terminal-over-in-flight-stop behavior has no new proof.
- Real network-monitor tests elsewhere still observe the OS. This does not claim
  the entire test suite has no ambient reads, nor establish user-session auth/PAC,
  production daemon exclusivity, real VPN behavior or sanitizer #118's cause.
