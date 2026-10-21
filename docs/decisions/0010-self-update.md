# 0010: Self-update with a nested Sparkle updater

- Date: 2026-10-06
- Decision: accepted (owner, 2026-10-06, #111, #119, #120, #122)
- Implementation: implemented
- Validation: pending
- Supersedes: none
- Superseded by: none

## Context

Conduit 0.5 updates itself from GitHub Releases (#111). Three constraints shaped how:

- A hardened-runtime app signed with a self-signed certificate (no Team ID) cannot load Sparkle.framework; dyld refuses it as a different Team ID (#122).
- Ad-hoc releases have no certificate the helper's caller pin can admit, so an update could never keep helper admission ([0009](0009-helper-caller-identity.md), #120).
- The Intel release runner doubled every release, and macOS 26, Conduit's minimum, is the last macOS for Intel Macs (#119).

## Decision

- **Sparkle 2 in a nested updater process (#122).** `ConduitUpdater` is the only target that links Sparkle. It ships as `Conduit.app/Contents/Helpers/Conduit Updater.app` with library validation off and an identifier the helper pin refuses. Conduit itself keeps library validation on. Installing uses Sparkle's own flow: a normal quit, so termination cleanup restores proxy and DNS, then replacement and relaunch.
- **EdDSA-signed archives**, with each signature published in a per-release appcast and the public key embedded in the app.
- **A release certificate held in CI (#120).** Tag builds sign the app, helper and `pm-dns` with a self-signed Conduit Release Signing certificate and the hardened runtime, from a tag-only `release` environment. The helper pin admits that certificate beside the installed app's own.
- **Apple Silicon only (#119).** 0.4.1 was the last x86_64 package.
- Developer ID signing, notarization and zero-downtime handoff do not gate this feature.

## Alternatives

- Load Sparkle in the app with library validation off: anyone who can write the bundle could swap the framework and run code in the process the helper pin admits.
- Keep shipping ad-hoc releases: every update would lose helper admission.

## Consequences

- Sparkle is a dependency, limited to `ConduitUpdater` (AGENTS.md "Ask first").
- The owner holds the release identity and update key; their backup and recovery are part of the release process ([`release-signing.md`](../release-signing.md)).
- Local builds signed with the local identity prompt for the key about five times per build.
- Intel Macs get no updates after 0.4.1.

## Invariants and verification

- Only the updater has library validation off, and the pin admits the app but refuses the updater, the helper and `pm-dns` (`verify-release-signing.sh`).
- An archive signed with another key is refused and the host left alone (`test-updater-e2e.sh`, unsigned and `--signed`).
- Downloads, staging and retries are bounded, and a refused candidate leaves the old app serving (#137).

## Implementation evidence

- [`ConduitUpdater`](../../Sources/ConduitUpdater/UpdaterController.swift) and the app-side [`AppUpdates`](../../Sources/PlatformMac/AppUpdates.swift) and [`UpdatePreflight`](../../Sources/PlatformMac/UpdatePreflight.swift), with [`UpdatePreflightTests`](../../Tests/ConduitTests/UpdatePreflightTests.swift) and the `update-coordinator` scenario in [`UpdateScenarios`](../../Sources/pm-sim/UpdateScenarios.swift).
- [`scripts/test-updater-e2e.sh`](../../scripts/test-updater-e2e.sh) in [`swift.yml`](../../.github/workflows/swift.yml); [`scripts/verify-release-signing.sh`](../../scripts/verify-release-signing.sh) and [`release.yml`](../../.github/workflows/release.yml) for tag builds.
- Owner-installed 0.5.0→0.5.1→0.5.2 updates and a 0.5.3→0.5.4 preflight and replacement are logged ([`validation-0.5.3.md`](../validation-0.5.3.md), #111).

Does not prove: the negative paths on an installed Mac (interrupted replacement, relaunch failure, absent or conflicting helper, quarantined download), macOS 27, the corporate-proxy feed paths, or key-backup recovery. #111 lists them as remaining owner acceptance.

## Open questions

None beyond #111's remaining checklist.
