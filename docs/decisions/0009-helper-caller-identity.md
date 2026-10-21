# 0009: Helper caller identity by code signature

- Date: 2026-09-25
- Decision: accepted (owner, 2026-09-25, #46)
- Implementation: implemented
- Validation: passed
- Supersedes: none
- Superseded by: none

## Context

The privileged helper admitted any process running as the console user. Socket permissions, protocol versions and argument validation limited what a caller could do, but not which program it was (#46). The app and helper were signed ad hoc, with no Team ID.

## Decision

Recorded on #46 on 2026-09-25:

- The helper enforces a local signing identity. A script the owner runs once creates a self-signed code-signing certificate; `bundle-app.sh` signs with it and the hardened runtime.
- `install-helper.sh` writes a root-owned pin: the certificate's leaf plus the app and daemon identifiers.
- The helper checks the peer's audit token (`LOCAL_PEERTOKEN`, `SecCodeCopyGuestWithAttributes`, `SecCodeCheckValidity`) before reading the request, on top of the console-uid rule.
- App updates signed with the same identity need no helper reinstall.
- With no pin the helper stays in uid-only mode and says so. A pin it cannot trust refuses every caller.
- The wire protocol is unchanged.

[0010](0010-self-update.md) later added the release certificate to the pin.

## Alternatives

A reusable secret readable by same-uid processes. #46 rules it out: any process running as the user could read it.

## Consequences

- An unexpected same-uid process cannot invoke privileged mutations once the pin is installed.
- Owners must create a signing identity and reinstall the helper once to turn enforcement on; an ad-hoc build leaves the helper unenforced.
- Hardened runtime is required, so a same-uid process cannot inject code into the genuine signed app.

## Invariants and verification

- The verdict is the pure function `HelperAdmission.callerVerdict`, unit-tested over every pin state.
- Audit lines carry a closed outcome category and never echo request values.
- The `helper-caller-identity` scenario exercises admission and refusal.

## Implementation evidence

Landed in #89; #121 made Settings' Install Helper write the pin.

- [`HelperCallerIdentity`](../../Sources/ConduitShared/HelperCallerIdentity.swift) and [`HelperAdmission`](../../Sources/ConduitShared/HelperAdmission.swift), used by [`HelperDaemon`](../../Sources/ConduitHelper/HelperDaemon.swift).
- [`HelperCallerIdentityTests`](../../Tests/ConduitTests/HelperCallerIdentityTests.swift) and the [`helper-caller-identity`](../../Sources/pm-sim/HelperCallerIdentityScenarios.swift) scenario.
- [`install-helper.sh`](../../install-helper.sh) writes the pin; [`scripts/create-signing-identity.sh`](../../scripts/create-signing-identity.sh) makes the identity, and [`scripts/test-create-signing-identity.sh`](../../scripts/test-create-signing-identity.sh) checks that it keeps the key secret.

Does not prove: enforcement on an installed helper; the owner's validation covers that.

Validation: the owner ran #89's manual checklist on a real install on 2026-09-26 and 2026-09-28, and confirmed the result on 2026-10-21. It is recorded on [#89](https://github.com/srps/Conduit/pull/89#issuecomment-6327604980).

- **Passed:** the pin and its ownership, admission, refusal of an unsigned same-uid process, an ad-hoc build and a build without the hardened runtime, daemon identity, tamper and reinstall, logout teardown, an app update without a helper reinstall, and the hardened-runtime smoke test for PAC and Kerberos.
- **Not recorded:** fast user switching, rollback to an ad-hoc helper install, and NTLM with Keychain-stored credentials under the hardened runtime.

## Open questions

None.
