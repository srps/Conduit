# 0016: Isolated ad-hoc development app bundle

- Date: 2026-10-24
- Decision: accepted (owner, 2026-10-24, #186 implementation checkpoint and #23)
- Implementation: planned
- Validation: none
- Supersedes: none
- Superseded by: none

## Context

Runtime convergence needs repeated tandem checks beside the serving app. The
existing --dev fake composition needs launch arguments and the ordinary bundle
shares production identity and may select a personal signing key. Development
checks produced repeated keychain prompts. The owner authorized the staged plan
in [#186](https://github.com/srps/Conduit/issues/186), beginning with
[#23](https://github.com/srps/Conduit/issues/23).

## Decision

Provide a debug-only Conduit Dev.app with distinct display/bundle/helper identity
and ad-hoc signing without personal identity lookup. Its exact development bundle
identifier selects existing FakeMachine, fake helper/lifecycle and in-memory
credential composition with scratch state even when opened without arguments.
Keep --dev supported. Refuse development identity/flags in release builds rather
than silently launching production composition.

Reject --dev combined with install/share/release before building or performing
system operations. Never quit/replace the serving app, install a helper or hand
off development updates to production. Keep the product version unchanged.
Validate scratch overrides against production-state aliases. Keep a clear dev
menu marker and distinguish the display name from the SwiftPM executable name.

## Alternatives

Always passing launch flags leaves Finder/Spotlight identity ambiguous. Signing
with a personal key adds prompts without providing dev-mode safety. Changing key
ACLs or replacing the installed bundle adds machine risk and is unnecessary.

## Consequences

The first implementation checkpoint is safe to inspect alongside production.
Ad-hoc development identity does not satisfy production helper authentication;
all such collaborators remain fakes. Notification/network observation seams
already tracked separately are not claimed complete by bundle isolation.

## Invariants and verification

Execute argument-order rejection and packaging tests with temporary fixtures and
stubbed build/sign/install tools; no real production install is tested. Cover
exact identity selection, fake composition, scratch-state separation and release
refusal. Build and inspect the actual ad-hoc bundle before launch verification.
Run required repository checks and preserve the serving process throughout.

## Implementation evidence

None yet. Claude is implementing this independently bounded first slice.

Does not prove: all remaining platform observation seams are fake, installed
production validation or helper admission for ad-hoc code.

## Open questions

None for this slice. Broader fixture/observation seam work stays separately scoped.
