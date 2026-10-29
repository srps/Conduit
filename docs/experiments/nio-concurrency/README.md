# NIO concurrency investigation

See [verification status](../../verification-nio-concurrency-2026-10-29.md).
The serving application was not stopped, installed or replaced by these runs.

## Application and fixture controls

The JSON reports preserve exact source-restoration checks and the semantic
failures of deliberately broken implementations. A process timeout or crash is
not counted as a semantic failure.

- `auth-reset-controls.json`: stale auth completion fails exactly two real-pool
  simulator assertions; exact source restoration passes.
- `streaming-reset-controls.json`: reverting only streaming completion fails the
  streaming regression while buffered tests still pass; restoration passes.
- `semantic-controls.json`: close-before-retirement, dedicated classification
  after publication, missing retirement/cleanup, route-judging flap recovery,
  address-only owed sweeps, and closing after cancellation all fail their
  corresponding assertions. Both source files are restored exactly afterwards.

Strict NIO mode also traps on the original embedded auth-limit fixture. The
repaired inventory passed 178 strict tests. The broader affected surface passed
264 unsuppressed ThreadSanitizer tests before the additional streaming case.
These counts describe those checkpoints, not final release acceptance.

## Independent Swift continuation report

The full unsuppressed TSan run reported a write/read in
`withUnsafeThrowingContinuation` / `UnsafeContinuation.resume` through NIO's
`EventLoopFuture.get()`. `continuation-app-report.txt` preserves the report. There
is no Conduit access in the conflicting frames.

`continuation-handoff.swift` removes both Conduit and NIO. Its single pending
callback is protected by `NSCondition`; values are Sendable, each continuation
resumes once, and the worker has a bounded join. It reproduces the same report
with Apple Swift 6.4 on the owner's Mac:

| Mode | Maximum iterations requested | Outcome |
| --- | ---: | --- |
| Handoff | 200,000 | Same continuation diagnostic; stopped at the first report |
| Resume first | 100,000 | Same continuation diagnostic; stopped at the first report |
| Await first | 50,000 | Completed without a report |
| Inline | 200,000 | Completed without a report |

The complete standalone report and mode results are in
`continuation-runtime-report.txt` and `continuation-controls.json`. No TSan
suppression was active. Ten isolated repetitions of the existing physical-ordering
class also passed without a report; they do not erase the full-run finding.

This supports classification as an independently reproducible Swift continuation /
TSan finding, rather than a Conduit ownership defect. It does not prove whether
the underlying Swift issue is instrumentation alone or a runtime bug. The
[upstream report](https://github.com/swiftlang/swift/issues/57803) has the same
two access patterns and 1016-byte task allocation, but was closed in 2023; that
historical closure is not evidence that today's runtime is unaffected.

Reproduce from this directory (the binary is scratch output):

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcrun swiftc -swift-version 6 -parse-as-library -sanitize=thread -g -Onone \
  continuation-handoff.swift -o /tmp/conduit-continuation-probe
TSAN_OPTIONS=halt_on_error=1:exitcode=66 \
  /tmp/conduit-continuation-probe handoff 200000 0 actor
```

The full TSan run remains a failed run. No test is quarantined, no dependency is
forked and no second future/continuation bridge is added to hide the report.

## Hosted deadline follow-up

`hosted-workflow-checkpoints.json` retains both the passing Release and failed
Swift checkpoints. The latter is not rewritten as passed: its no-stream Quit
assertion depended on a near-deadline wall-clock read. `quit-fallback-review.md`
reviews the narrow wait injection and controlled store/host ordering used to
remove that race. See the verification page for subsequent controls and gates.

`quit-semantic-controls.json` removes the one final lookup and records both
intended assertion failures plus exact restoration and passing controls.
`quit-failure-control.json` injects an early setup exception after teardown
registration and confirms normal bounded failure and restoration.
`quit-strict-repeat.json` records 20 strict isolated trials of both repaired tests.

`local-workflow-gates-quit-followup.json` records the second complete 20-step
local workflow on the final code/test tree, preserving the earlier receipt.
Documentation-only receipts/status updates were added afterwards and checked.
