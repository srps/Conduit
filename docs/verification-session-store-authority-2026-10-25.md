# Session-owned configuration-store authority: verification

Status: implementation and independent review complete; all 40 local workflow
checks pass (2026-10-25). Hosted checks will follow publication. This is consumed
store preparation under decision 0031, not actual Host/AppState workflow adoption
or release readiness.

## One authority path

`StateRootSession` keeps its private lease and resolved plan. Its exhaustive map
accepts the existing kernel `ConfigurationComponent` and cannot name the journal.
Its synchronous component replacement delegates to the existing verified physical
primitive, with the same budgets, conditional pre-read and read-back classifier.
No raw lease, arbitrary path, new parser, generic lease callback, public access or
new dependency is introduced.

`ConfigurationStore` now requires that session rather than an independently
supplied plan and raw lease. The bootstrap is the authority boundary; a store
cannot pair a foreign plan with a held lease. The obsolete constructor refusals
are removed. Each existing store replacement consumes the session capability on
PlatformWork, and its closure retains the session through physical work. There
is one component-to-file map rather than parallel store/session switches.
Startup migration and the app/daemon's actual store construction remain later
integration work; no production composition is added here.

## Executed evidence

- 137 focused tests pass, including seven new session tests over production
  bootstrap: bad name/outside-root refusal, component isolation, stale-baseline
  no-write, real in-root alias preservation, store/session retention and a second
  bootstrap remaining busy during physical reads. The existing store models and
  preservation suites use the migrated fixture and remain intact.
- `pm-sim config-session-replacement` passes 14 assertions over scratch OS files:
  all three component mappings, persisted bytes, external-edit conflict, preserved
  journal, busy root, reacquisition after capability release and cleanup. Existing
  conditional-replacement and runtime-replacement scenarios also pass.
- All **40** steps equivalent to `.github/workflows/swift.yml` pass: **3,307 tests,
  two skips, zero failures; all 101 simulator records and the existing performance
  gate**. The relevant source/test/workflow fingerprint stays unchanged:

`30e4736d559b99636dc3d7dc389a7904e5ad65930ca7e3f5032c1384f15408b2`

Raw full-run commands/results/logs are retained in the task scratch directory
`runtime-session-seam-full-gates/`. The actual unit and simulator assertions are
committed in `StateRootSessionConfigurationTests.swift` and
`ScenarioConfigSessionReplacement.swift`; these are not projected results from a
second store or model implementation.

## Review and provenance

Official Claude Code implemented and verified the slice and separately reviewed
the source, using verified `claude.ai` Max subscription authentication with API
provider overrides removed. Codex reviewed the production diff and failure paths.
The final independent review found no semantic blockers.

Focused passes 1–3 all passed; the first two are archived. Review restored the
fixture's original preservation on unconfirmed close, retained the first scenario
close errno, and corrected the gate fixture's early-return cleanup. It now
explicitly releases only after owned work is confirmed quiescent; uncertain work
keeps its directory and retains the session until the operation finishes. A
worker-release signal alone is not treated as logical operation completion.

The internal `releaseForTesting` capability is used only by tests after quiescence;
ordinary production callers cannot close the session's lease through this seam.
ARC-only test cleanup still reports close errors through its callback; generic
failed-cleanup hardening remains test-harness follow-up. No held-state query,
registry or second ownership counter is claimed.

## Limits

No actual framed host adapter, configuration workflow, private editor reply,
shipping profile, AppState activation or RuntimeActor move is delivered. The
explicit reload policy remains proposed in `design-runtime-reload-review.md`.
No serving app/helper was stopped, replaced or installed over; no VPN was needed.
Scratch OS tests do not establish installed-app, real auth/PAC, daemon ownership
or release validation. Decision 0031 keeps those acceptance gates explicit.
