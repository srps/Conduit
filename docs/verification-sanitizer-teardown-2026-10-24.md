# Sanitizer investigation: owned test teardown, 2026-10-24

Scope: a test-only prerequisite for #118 and the shared-runtime work. This does
not establish the cause of the intermittent continuation warning or close #118.
No runtime code, dependency, suppression, helper, installed app or system setting
changed. Claude Code implemented and checked the repair through the owner's
verified `claude.ai` Max subscription; API/provider overrides and hooks were
disabled. Codex reviewed the source and ran the isolated verification below.

## Repair

`DNSForwarderIntegrationTests` owns one forwarder per test, registers it before
start, and awaits its existing stop in async teardown. This replaces three
unawaited `defer { Task { ... } }` stops, including the historical allocation-stack
lead. Existing mid-test stops use the same ownership slot.

`PACRouteRevalidationTests` owns its fake evaluator, engine and explicitly started
refresh. Async teardown releases the fake's holds, awaits that refresh and checks
the existing pending-evaluation count with a bounded wait. Test methods observe
hold counters without blocking the cooperative pool on semaphores. The gates
remain inside the controlled synchronous fake evaluator. Superclass teardown
still runs when the drain throws, and the error is surfaced.

Focused verification exposed a separate assertion race: pending evaluation was
removed before `pac.revalidation_failed` was published. The positive-event test
now waits for that specific event before asserting it; the deadline bounds
failure and cannot count as success. No production ordering was changed.

## Evidence

The isolated branch starts at main `bba6ca3be7b60b187ffe4c852c4350df0c1e8a47`.
The checked code had only the two test files modified; its relevant-source
SHA-256 was
`ac9b8ef7ba8cf3b61275e02f9bf9d585b253f5419d75fcbd96cf94688bed00c9`.
It was unchanged through both sanitizer runs and the subsequent full gates.

- Claude's focused normal run: 19 tests (nine DNS, ten PAC), zero failures.
- Codex ran `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift
  test --sanitize=thread --filter
  'DNSForwarderIntegrationTests|PACRouteRevalidationTests'` twice: once with the
  workflow's existing suppression file, then with `TSAN_OPTIONS` unset. Both
  passed all 19 tests, with no TSan warning/summary in either full log.
- `otool -L` confirmed the executed XCTest binary linked
  `libclang_rt.tsan_osx_dynamic.dylib`. That binary's SHA-256 was
  `70242d7ab1936a29285d880a6b51a80ffd863fbf10f6fd821158f3f1db9b2a6f`.
- All 39 workflow-equivalent checks then passed on the normal build, including
  2,348 Swift tests (two skipped, zero failures), all 85 `pm-sim all` results,
  performance, signed/unsigned updater, protocol and structural checks.

Local full logs, commands, instrumentation and fingerprints are retained under
`/private/tmp/conduit-runtime-stage1-20261024/tsan-118/` and
`/private/tmp/conduit-runtime-stage1-20261024/teardown-full-gates/`.
The first sanitizer build also printed pre-existing compiler warnings outside
these two files; passing is not a claim that the repository is warning-free.

## Limits and next investigation

These are two focused samples, not the scheduled full sanitizer soak or a
before/after reproducer. The historical warning was intermittent, and neither
sample reproduced it. No suppression, dependency or toolchain change is proposed.

Forwarder stop still does not join all UDP/TCP resolution work, deferred DoH
invalidation or timer callbacks. Other test client/tarpit channel closes remain
success-path-only. PAC's pending count does not cover its delayed timeout blocks
or every internal refresh lifetime, and a negative-event assertion still depends
on that count. These existing limitations remain investigation leads.

The exact `defer { Task` source pattern still appears at 55 other test sites; this
is a heuristic inventory, not every possible unstructured lifetime. The patch
addresses the two historically named test families first. A future claim about
the original warning still needs complete racing/allocation stacks and a reduced
case that distinguishes confinement defects from library/toolchain behavior.
