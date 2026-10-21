# Decision records

A decision record says which choice the owner made, who authorized it and how far it has got. `ROADMAP.md` stays the only execution queue, `docs/planning.md` the rationale and `docs/design-*.md` the subsystem designs; a record links to them instead of repeating them. The format follows overalls' [ADR-0001](https://github.com/ghuntley/overalls/blob/trunk/docs/architecture/decisions/0001-architecture-governance.md), with a separate validation status (#185).

## Status

Each record carries three statuses, because merged does not mean it works:

- **Decision:** `proposed`, `accepted`, `rejected` or `superseded`. An accepted or superseded decision names its authorization in parentheses: who, the date, and the issue, PR or commit that records it. A chat session is never a source.
- **Implementation:** `planned`, `partial` or `implemented`. `partial` and `implemented` link to evidence outside `docs/`: code, tests, scripts or pm-sim scenarios.
- **Validation:** `none`, `pending` or `passed`. This is the owner or real-machine check that unit tests and pm-sim cannot give. `none` means no such check has been recorded or is due yet; `pending` means one is due and has not passed; `passed` links to where the result is recorded.

`Supersedes` and `Superseded by` name record IDs or `none`, and are kept reciprocal. A superseded record names its successor.

## Rules

- Copy [`template.md`](template.md) to the next free number. IDs are never reused, and records are never deleted: a rejected or superseded record stays.
- An accepted decision is never edited into a different one. Replacing it takes a new record and supersession links. Facts and evidence are corrected in place.
- A change that makes or replaces an owner decision adds or updates a record in the same PR. A change that implements part of one, or records a validation result, updates its statuses and evidence.
- Update the index below in the same change.
- `scripts/check-decisions.py` checks the structure in CI (#177): IDs, and from git history that no record was deleted or its ID reused; statuses, the index, supersession links, evidence and relative links. It cannot judge whether the evidence is enough; review does that.

## Index

| ID | Title | Decision | Implementation | Validation |
| --- | --- | --- | --- | --- |
| [0001](0001-one-runtime-host.md) | One runtime host for the app and the daemon | accepted | planned | none |
| [0002](0002-daemon-first-ownership.md) | Daemon-first runtime ownership | accepted | partial | pending |
| [0003](0003-thin-appstate-harness.md) | Thin AppState harness over FakeMachine | accepted | implemented | none |
| [0004](0004-staged-host-policy-sharing.md) | Share app and daemon platform policy piece by piece | superseded | partial | none |
| [0005](0005-kernel-import-fence.md) | Kernel import fence, Linux paused | accepted | implemented | none |
| [0006](0006-module-boundaries.md) | Module boundaries for the helper, shared contracts, Keychain codec, spool and paths | accepted | partial | none |
| [0007](0007-kernel-file-split-first.md) | Split large kernel files before any target split | accepted | planned | none |
| [0008](0008-pac-no-usable-answer-and-strict-mode.md) | PAC answers with no usable entry and strict mode | accepted | implemented | none |
| [0009](0009-helper-caller-identity.md) | Helper caller identity by code signature | accepted | implemented | passed |
| [0010](0010-self-update.md) | Self-update with a nested Sparkle updater | accepted | implemented | pending |
| [0011](0011-vpn-path-based-socket-sweeps.md) | Path-based socket sweeps for VPN transitions | accepted | implemented | pending |
| [0012](0012-commit-attribution.md) | Optional attribution trailers, no session URLs | accepted | implemented | none |
