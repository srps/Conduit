# Configuration source authority and canonical value comparison

This unreleased store correction follows merged PR245. Claude Code implemented and reviewed the
shape through the owner's verified claude.ai Max subscription, without API authentication. The serving
0.5.8 app was untouched. No private host writer or AppState activation is exposed.

## Implemented boundary

A missing sidecar keeps its source runtime baseline beside its own absent baseline, even when its
values are defaults. First creation verifies those source bytes in the same worker step as replacement.
A changed source writes nothing and latches both authorities; unreadable source holds with its typed
error and retains authority for another check. Coupled platform refusal holds runtime behind it.
Present sidecars remain independent.

Reload retires a missing sidecar token when its effective value changes, with version-exhaustion
preflight. Harmless runtime changes can keep that token after explicit reload while refreshing its
source. Verified canonical runtime writes move the source of sidecars still missing; verified sidecar
creation clears it.

Canonical persisted-value comparison stays separate from raw-file conflict identity. Swift String
equality can alias byte-distinct URLs/text. Existing stagers compare current/candidate canonical bytes
on the store worker; candidate values still come from shared decode. Raw baselines still detect
external formatting/unknown-field edits, while a no-op preserves those bytes. There is no second
parser, field inventory, hash history, registry or writer.

Known unrepresentable loaded values cannot authorize equality reuse, so valid candidates can repair
them. Unexpected failures retain closed codes and refuse before writing. Load comparisons return
fixed change flags; first load performs no comparison encoding.

## Executed verification

Before production changes, eight source witnesses had six failing tests and 20 assertion failures.
They reproduced stale legacy-value tokens and shadowing first sidecar writes, including external
creation of an absent runtime file. After that correction, Unicode witnesses reproduced three further
failures with eight assertions: stale URL tokens and unchanged receipts while memory/disk bytes
diverged. Canonical comparison fixes those paths. Actual PAC URL bytes, verified handover, reload
and valid repair remain tested; a library-only String equality test was removed.

Focused checks passed 169 tests, catalogue/decisions and actual-host pm-sim. Existing sequential
models were extended: eight seeds with 24 runtime/platform steps, and eight seeds with three
five-operation preference segments. They assert reached outcomes, not exhaustive interleavings.
The workflow model covers 1,459 fixed breadth-first traces plus 150 seeded walks, including the new
source read's admission points, with fixed frontier/coverage bounds.

Codex executed five actual source mutations; each failed its intended XCTest assertion without a
compiler failure or crash:

| Mutation | Witness |
| --- | --- |
| Skip source check before first creation | Runtime/platform reference model |
| Ignore missing-sidecar value movement | Legacy URL reload token |
| Retain old source after verified runtime write | First preferences write |
| Compare canonical JSON as Swift Strings | PAC URL save and handover |
| Reject an unrepresentable current value during valid repair | Repair candidate |

Restored targeted tests and both sequential models passed; exact committed bytes were restored.
The [mutation manifest and patches](experiments/configuration-source-guards/README.md) also compare
all changed production sources at the immutable review head, workflow head and restored tree:

    ConfigurationStore.swift ac8d47f48241bacac647b87b4d966b8b5bc215a4d74c632c7980b0fecae56597
    ConfigurationStoreIO.swift 6ff40088a66abeb0b10204cc308648b19cf7a72b5855d99492d687b947624f11

Intermediate failed checkpoints remain recorded: the fake's 16-call log overflowed across test phases,
corrected by clearing after asserted boundaries rather than raising its global limit; a draft used a
non-Error refusal in Result, corrected with a private typed wrapper. Neither counts as mutation evidence.

## Independent review and full workflow

Independent subscription-backed Opus review of immutable 0090a6b returned READY with no blocking
finding. It was static, not execution evidence. Subsequent source changes only removed stale test
comment wording; production bytes remain those reviewed. All 40 required workflow checks plus the targeted DNS scenario passed on unchanged source at 3f6b80f:
3,432 Swift tests, zero failures and four skips (two live GSS tests without a ticket and two opt-in memory
diagnostics); all 103 simulator records and the performance gate passed. The relevant source/test/
script/resource/package fingerprint was:

    d570312d980fd480333161276521e06d13728e4d56c7781462a21e7053cd0b3c

Exact-head hosted CI and review disposition belong to the integration PR; local checks do not claim them.

Coverage limits noted by review: legacy platform value movement is a focused witness, not a variant
in the runtime/platform seeded model. The workflow model does not delete a sidecar after load.
A refused runtime-source path is classified by existing replacement-refused vocabulary, but the
store-owned role cannot reach that refusal without an invalid capability or a new hook. None is added.
Unexpected canonical sidecar-staging failures could make repeated reloads refuse if a future field
makes them possible; current bounded Bool/enum/URL fields cannot reach that branch.

## Limits and remaining gates

An external edit after the source check remains possible; a witness pins that race. This is not a
multi-file compare-and-swap or power-loss durability proof. Reverse preservation and partial
persistence facts remain. Preferences have unit/model coverage until their private caller exists;
actual host and pm-sim cover coupled first-platform-write refusal.

Canonical comparison adds staging of the current runtime value, including its round-trip decode,
and bounded sidecar work on the separate store worker. Actual-adapter memory and Stop/status
measurements must include that cost before service-profile selection; earlier codec-only RAM
numbers do not cover it.

Apply/reconciler equality is separate [#246](https://github.com/srps/Conduit/issues/246), to reproduce
and fix before private apply. Ordered admission, per-module fences, final Quit flush, AppState writer
deletion, RuntimeActor and release acceptance remain open.
