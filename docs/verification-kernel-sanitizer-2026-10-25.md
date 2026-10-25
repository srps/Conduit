# Kernel sanitizer lifetime and runtime profile verification

Status: source/test review complete and all 40 local checks pass (2026-10-25).
Hosted Swift and CodeQL passed on exact reviewed head
`765c4ab0f86aa1705006229ed625415cfcee2f7b`;
[PR #241](https://github.com/srps/Conduit/pull/241) merged at
`8b00af6cea20e0e11932622ba74afddf99228741`. Optional automated code/security
reviews failed to complete and Devin skipped; no actual review submissions or
inline findings were present at merge. Runner notices concern capacity/OS
migration. Those optional services supply no clean-review evidence. This does not select a shipping resource
profile or establish release readiness.

## Change and evidence

Repeated fresh connection-record construction exposed Foundation temporaries
accumulating without a caller autorelease pool. The correction scopes the kernel
sanitizer's existing regex/URL work synchronously where Objective-C is available,
with one unchanged private implementation and a direct path elsewhere. Returned
strings retain their storage through ARC; the change adds no normal-path copy,
dependency, public API or alternative redaction path. Direct event/log callers
and observable targets use that same entry point.

The [direct Release control](experiments/runtime-service-profile/kernel-sanitizer-release/README.md)
compiles the pinned baseline and corrected actual source. Four short synthetic
input shapes grow by 1.66–2.91 MB across ten additional batches before the fix;
all four corrected cases stay at zero additional malloc in-use bytes through 101
batches. Output checksums and byte counts match. The committed reproduction was
run independently with matching growth/checksums. This is a scoped lifetime
measurement, not RSS, steady-state app RAM, a universal allocation limit or a
latency/performance-speedup claim.

The [test-only profile experiment](experiments/runtime-service-profile/README.md)
uses the actual limits constructor, Bridge projection, frame codec and packer.
It follows the owner's 64 KiB reply/stream selection. Other candidate values
remain experimental. The strong all-NUL row fixture measures 12,768 bytes:
657 rows fit the experimental 8 MiB capture bound and the next row causes whole
capture refusal. Typical 10,000-row projection is about 0.64–0.70 seconds in the
Debug test process; actual-host scheduling and latency remain adoption gates.
Pressure checks verify typed lane refusals, admitted Stops and independent
status capacity, then release tasks, subscriptions and lane/effect ownership.
These are transport/manual-owner counts, not actual RuntimeHost latency.

## Review and checks

Official Claude Code implementation and independent read-only review used verified
`claude.ai` Max subscription authentication with API-provider overrides removed.
The final review found no semantic blockers. Codex reviewed source and evidence.
Review corrections include exact admission/failure classification, explicit
parked-task cleanup, correct all-zone malloc interpretation, and qualified
measurement claims. Optional fixture-throw-path hardening is not a production
contract change or a release-readiness claim.

The final targeted pass runs 68 tests with no failures. All 40 steps equivalent
to `.github/workflows/swift.yml` then pass: **3,301 tests, two skips, zero failures;
all 100 simulator records and the existing performance gate**. Relevant source,
tests, scripts and workflow fingerprint stayed unchanged throughout:

`dece2621a8184dfbb0f1dfa9dfefb793f41d532c59c26fe6d9db30713f5cb0a9`

The full check runner/results and raw logs are preserved in the task scratch
`runtime-profile-full-gates/`; the checked-in experiment includes focused raw
measurement excerpts and standalone reproduction sources/results.

Attempts 5 and 6 of the new pressure fixture stalled and were stopped only in
the task-owned XCTest process. Both logs are preserved, including the first
sample. The cause was interleaving stream opening and starting pulls under a
manual scheduler. The final fixture opens all streams before starting pulls and
uses bounded owner pumping during cleanup. This was a new test-helper defect,
not a production transport failure; the corrected tests pass in both targeted
and full runs. Earlier test-expectation and interim-scope evidence is retained
and distinguished in the experiment, rather than relabelled as final success.

The installed serving Conduit process and helper were not stopped, replaced or
installed over. VPN was not required. AppState/store/client adoption, RuntimeActor,
the remaining profile and the pending activation-boundary owner choice remain
open. Decisions 0029/0030 are unchanged, and 0030 production enforcement remains
planned.
