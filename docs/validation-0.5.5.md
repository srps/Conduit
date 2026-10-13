# 0.5.5 maintenance validation

Local validation on macOS with Xcode, 2026-10-13. These changes are prepared for
review; they have not replaced the installed 0.5.4 app or privileged helper.

## Scope and evidence

- **#77:** CI runs the import/Process fence before building. Positive/negative
  fixtures cover attributed, conditional, scoped, escaped and Unicode imports,
  comment/literal masking, process construction and missing sources.
- **#93:** `pacUsableRouteLimit` defaults to 32, validates 1–128 and persists in
  the flat config. Eight regressions cover mixed/rejected and oversized chains,
  DIRECT boundaries, native CFNetwork normalization, config compatibility,
  cached/in-flight policy changes and coalesced count-only events. The real
  `pac-route-bounds` CONNECT scenario limits attempts to two, excludes the
  healthy third proxy and trailing DIRECT, then admits the third proxy at cap 3.
- **#118 track B:** `pac-slow-host` uses evaluator gates, versioned answers and
  ordered event-loop completion markers. All background publication is joined
  before simulated clock advance; deadlines throw instead of passing. Twenty
  normal and twenty TSan repetitions each observed foreground steps `[0, 60]`,
  30 evaluations, 28 background evaluations and three coalesced slow reports.

## Sanitizer-discovered NTLM correction

The first full TSan unit run trapped in the existing
`NTLMAuthTests.testSecurityBufferLayout`: `load from misaligned raw pointer`.
The single-test run reproduced the same signal-5 crash. NTLM's UInt16/UInt32
readers used aligned loads on Data storage. Two unaligned loads fix that
assumption while preserving existing endian and range checks; an added regression
forces a base address misaligned by one byte and checks the decoded header and
payload. The original test and the forced fixture passed afterward.

The API contract is documented in [Swift's unaligned-load proposal](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0349-unaligned-loads-and-stores.md).
This was an alignment trap, distinct from #118 track A's continuation-race report.
Track A remains open; no suppression was added or widened.

## Completed checks

At the runtime-fix revision `f7280cc`:

- Normal and TSan full unit suites: **2,066 tests, 3 skipped, zero failures** each.
- All **64 simulator outcomes** passed in normal, TSan and ASan builds.
- The sanitizer workflow's separate websocket-upgrade runs passed in both modes.
- All Swift-workflow Python/shell checks passed, including the new fence checks.
- Both stand-in updater E2E modes passed. Hardened-runtime signing used only a
  disposable certificate/keychain with preconfigured codesign access; no personal
  signing key or installed Conduit identity was used and no signing prompts occurred.
- Performance gate passed: 10.18 seconds, 33.1 MiB maximum RSS, 101.6% measured CPU.

Final review then corrected the PAC policy-invalidation diagnostic to report the
actual script/fetch state and carry its reason through the next refresh.
The focused PAC/config/NTLM suite and TSan route-bound regressions validate that
metadata contract separately. The full matrix above remains the evidence for
routing, transport and NTLM behavior; this final correction changes diagnostics.

Sanitizer outputs use separate build trees. Serving processes remained the
installed app and helper; no installation, real VPN cycle, system proxy/DNS
mutation or helper replacement was performed. Installed-use acceptance follows
the eventual signed 0.5.5 release.

## Pre-PR regression review

The review reproduced a cap/cache race with deterministic gates: an older reader
held a cap-100 configuration, a newer cap-2 request reconciled its policy and
paused before cache lookup, then the older reader populated the shared cache
under cap 100. The newer request returned 100 routes before the fix.

Policy reconciliation now returns the admitted generation. Cache lookup,
foreground evaluation admission and background revalidation check that same
generation; a superseded request gets the existing configured-upstreams-only
answer rather than another policy's chain. Both synchronous and asynchronous
cache paths have gated regressions, with explicit failure on gate timeout.
Eight route-bound regressions passed under TSan after this correction.
