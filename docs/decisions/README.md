# Decision records

A decision record says which choice the owner made, who authorized it and how far it has got. `ROADMAP.md` stays the only execution queue, `docs/planning.md` the rationale and `docs/design-*.md` the subsystem designs; a record links to them instead of repeating them. The format follows overalls' [ADR-0001](https://github.com/ghuntley/overalls/blob/trunk/docs/architecture/decisions/0001-architecture-governance.md), with a separate validation status (#185).

## Status

Each record carries three statuses, because merged does not mean it works:

- **Decision:** `proposed`, `accepted`, `rejected` or `superseded`. An accepted or superseded decision names its authorization in parentheses: who, the date, and the issue, PR or commit that records it. A chat session is never a source.
- **Implementation:** `planned`, `partial` or `implemented`. `partial` and `implemented` link to evidence outside `docs/`: code, tests, scripts or pm-sim scenarios.
- **Validation:** `none`, `pending` or `passed`. This is the owner or real-machine check that unit tests and pm-sim cannot give. `none` means no such check has been recorded or is due yet; `pending` means one is due and has not passed; `passed` needs a paragraph starting `Validation:` in Implementation evidence that links where the result is recorded: a GitHub issue, PR or comment, or a file in the repository.

`Supersedes` and `Superseded by` name record IDs or `none`, and are kept reciprocal. A superseded record names its successor.

## Rules

- Copy [`template.md`](template.md) to the next free number. IDs are never reused, and records are never deleted: a rejected or superseded record stays.
- An accepted decision is never edited into a different one. Replacing it takes a new record and supersession links. Facts and evidence are corrected in place.
- A change that makes or replaces an owner decision adds or updates a record in the same PR. A change that implements part of one, or records a validation result, updates its statuses and evidence.
- Update the index below in the same change.
- `scripts/check-decisions.py` checks the structure in CI (#177): IDs, and from git history that no record was deleted or its ID reused; statuses and authorization dates, the index, supersession links, implementation and validation evidence, and relative links. It cannot judge whether the evidence is enough; review does that.

## Index

| ID | Title | Decision | Implementation | Validation |
| --- | --- | --- | --- | --- |
| [0001](0001-one-runtime-host.md) | One runtime host for the app and the daemon | superseded | planned | none |
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
| [0013](0013-runtime-module-isolation.md) | Shared runtime modules and control isolation | superseded | partial | none |
| [0014](0014-runtime-client-stream.md) | Async runtime client and bounded observation contract | accepted | partial | none |
| [0015](0015-save-before-apply.md) | Save durable intent before apply, with Stop and Quit exceptions | accepted | partial | none |
| [0016](0016-isolated-development-bundle.md) | Isolated ad-hoc development app bundle | accepted | implemented | passed |
| [0017](0017-exclusive-state-directory-writer.md) | Exclusive writer authority per state directory | accepted | partial | none |
| [0018](0018-private-configuration-request.md) | Private configuration request with frozen explicit values | accepted | partial | none |
| [0019](0019-private-configuration-frame-budget.md) | One private configuration frame capped at eight MiB | superseded | partial | none |
| [0020](0020-canonical-runtime-writer-root.md) | Keep runtime persistence within one canonical writer root | superseded | partial | none |
| [0021](0021-bounded-configuration-at-all-boundaries.md) | Bound configuration resources at update and startup boundaries | accepted | partial | none |
| [0022](0022-configuration-identity-path-and-host-bounds.md) | Complete identity, path and host configuration bounds | accepted | partial | none |
| [0023](0023-exact-schema-two-persistence.md) | Keep schema two and refuse inexact committed durations | accepted | partial | none |
| [0024](0024-strict-configuration-file-grammar.md) | Strict syntax and Unicode throughout configuration files | accepted | implemented | none |
| [0025](0025-hold-mixed-configuration-apply.md) | Hold a mixed configuration apply until required inputs verify | accepted | partial | none |
| [0026](0026-bounded-platform-and-preferences-files.md) | Bound platform and preferences files through the shared file contract | accepted | implemented | none |
| [0027](0027-refuse-external-configuration-edits.md) | Refuse ordinary saves over changed configuration files | accepted | partial | none |
| [0028](0028-fixed-writable-state-filenames.md) | Fixed writable state filenames within the canonical root | accepted | partial | none |
| [0029](0029-bound-runtime-display-text.md) | Bound runtime display text with explicit notices | accepted | partial | none |
| [0030](0030-ordinary-runtime-reply-frame-cap.md) | Ordinary v2 replies and stream frames capped at 64 KiB | accepted | planned | none |
| [0031](0031-incremental-runtime-development-single-activation.md) | Incremental runtime development with one AppState activation | accepted | partial | none |
| [0032](0032-explicit-reload-and-reconcile.md) | Explicit configuration reload adopts and reconciles eligible changes | accepted | partial | none |
| [0033](0033-headless-real-host-simulation.md) | Headless real-host simulation with explicit effect injection | accepted | implemented | none |
| [0034](0034-private-editor-reply-frame-cap.md) | Complete private editor replies capped at eight MiB | accepted | partial | none |
| [0035](0035-whole-request-lifecycle-validation.md) | Validate combined editor lifecycle intent as one request | accepted | planned | none |
| [0036](0036-conditional-dns-activation.md) | Explicit host-checked conditional DNS activation | accepted | planned | none |
