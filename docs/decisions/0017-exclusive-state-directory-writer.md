# 0017: Exclusive writer authority per state directory

- Date: 2026-10-24
- Decision: accepted (owner, 2026-10-24, #186 writer-authority checkpoint)
- Implementation: partial
- Validation: none
- Supersedes: none
- Superseded by: none

## Context

Decision 0015 requires generation-ordered verified persistence before ordinary
apply, with Stop/Quit exceptions and bounded waiting. A started asynchronous write
can outlive its caller's deadline. If a replacement process writes B while an old
process can still finish A, A can overwrite B. This is a migration hazard, not a
reproduced late-write bug in today's synchronous save calls.

The owner selected the exclusive writer lease alternative in
[#186](https://github.com/srps/Conduit/issues/186), following Claude's subscription
review and Codex's source check. The reviewed alternatives and failure history
are in [the writer-lifetime design](../design-runtime-config-writer-lifetime.md).

## Decision

Use one exclusive OS-backed advisory writer lease per state directory. Acquire
without blocking the runtime owner before startup writes or reconciliation.
A competing host reports that the state directory is already owned and refuses
runtime startup; it must not reconcile machine state. The future daemon owns this
authority while app clients keep editor drafts and send explicit intent.

Keep authority until queued and started writes are quiescent, or let process exit
release it. Timeout cancels waiting, not a physical write or its authority. The
lease owns a close-on-exec descriptor and a stable lock inode: do not unlink,
replace the lock file or delete/replace its state directory while it is held.
All cooperating configuration, platform-preference and platform-journal writers
must share the authority; composition must not leave an unlocked writer.

Keep the machine effect behind a PlatformMac protocol with a fake. A busy or
failed acquisition is explicit. This is exclusion across processes, separate
from 0015's expected-prior revisions and authoritative read-back. This decision
does not select a new persisted generation schema or a snapshot history registry.

Older binaries and external editors ignore this advisory protocol. The first
lease-bearing upgrade still requires the old process to exit before handing off.
Do not substitute PID observations for proof of quiescence. RuntimeHost extraction
preserves current behavior; adopt the lease with the affected persistence paths.

## Alternatives

Relying only on old-writer quiescence/process-exit ordering avoids a lock adapter,
but every manual launch and relaunch path must enforce it. A process-local serial
queue or content digest cannot exclude another process. A durable snapshot
registry adds history/lifetime state and does not itself provide writer exclusion.

## Consequences

Writer ownership can move from the in-process host to the daemon without changing
the rule. Busy startup needs an honest error. Advisory filesystem locking has
platform/filesystem failure modes and cannot exclude nonparticipants. This does
not implement helper leases, power-loss durability, atomic multi-file commits,
listener handoff or cancellation of already-issued machine effects.

## Invariants and verification

Drive the actual writer against an independent bounded model through delayed
writes, caller deadline, Stop/Quit, stale expected revisions, ambiguous read-back,
a second-owner attempt, late completion and release after quiescence. Test the OS
adapter with owned subprocesses and scratch directories, including process exit
and descriptor inheritance. Join fixtures before deleting their state directories.
Verify busy startup cannot reach persistence or machine reconciliation. Keep the
serving Conduit and helper unchanged. Validate filesystem semantics on deployment
storage; select bounded drain behavior with measured shutdown budgets.

## Implementation evidence

Partial: the OS lease primitive, its typed outcomes and a fake exist. The configuration
store core borrows a held root lease and refuses a root it does not hold. App and
daemon startup now acquire authority through StateRootSession; neither constructs
the store yet. Read-only tool and complete journal/workflow adoption remain open. See [the store verification note](../verification-configuration-store-2026-10-25.md). Code: [`StateWriterLease.swift`](../../Sources/PlatformMac/StateWriterLease.swift)
(protocol, opaque lease, typed outcomes), [`StateWriterLeaseOS.swift`](../../Sources/PlatformMac/StateWriterLeaseOS.swift)
(non-blocking `flock` on a fixed `O_NOFOLLOW` lock file, close-on-exec, no unlink,
no `LOCK_UN`). Release is terminal: an unconfirmed close is returned to every later caller and never retried, a call during an in-flight close waits for its outcome, and a dropped lease reports an unconfirmed close once. The fake is in [`PlatformFakes.swift`](../../Sources/PlatformMac/PlatformFakes.swift).
Tests: [`StateWriterLeaseTests.swift`](../../Tests/ConduitTests/StateWriterLeaseTests.swift)
and [`StateWriterLeaseProcessTests.swift`](../../Tests/ConduitTests/StateWriterLeaseProcessTests.swift)
(owned `python3 -I` contenders, process-exit release, descriptor inheritance with a
positive control). pm-sim: [`ScenarioStateWriterLease.swift`](../../Sources/pm-sim/ScenarioStateWriterLease.swift),
run as `pm-sim state-writer-lease` over a scratch directory. Results and limits are in
[the verification note](../verification-state-writer-lease-2026-10-24.md).

Does not prove: legacy upgrade ordering, cross-process exclusion on the owner's
storage, complete writer coverage, asynchronous write quiescence, Stop/Quit or deadline
behavior, or real-machine cleanup after a deadline.

Startup adoption (2026-10-25): `StateRootBootstrap` takes the root's lease before any load, migration, seed, journal restore or host construction, in the app (`PreparedAppLaunch`) and in `ConduitDaemon`. A busy root exits with `config.state_root_busy` before anything under it is read. Before the lease, a missing root and its missing ancestors are created owner-only, outermost first, and an existing directory is never changed; a pure name check runs before that, so a refused name creates nothing. The held lease is carried by a `StateRootSession`, which `AppState`, `RuntimeHost` and the dev composition require. Code: [`StateRootSession.swift`](../../Sources/PlatformMac/StateRootSession.swift). Tests: [`RuntimeStartupOwnershipTests.swift`](../../Tests/ConduitTests/RuntimeStartupOwnershipTests.swift). The configuration store is not constructed; its legacy writers run under the session, which is not the store workflow this decision still requires. Read-only tool inputs, `pm-proxy`, `pm-dns` and `pm-tunnel`, do not take the lease yet.

The verified runtime-file replacement takes a held `StateWriterLease` and refuses a file outside that lease's root before any I/O ([`VerifiedConfigurationFileReplacement.swift`](../../Sources/PlatformMac/VerifiedConfigurationFileReplacement.swift)). The configuration store core is its only caller, and only in the focused checks, and the lease still excludes only cooperating writers. The lease has no held-state query, so the caller proves that it still holds the root. See [the verification note](../verification-runtime-file-replacement-2026-10-24.md).

Diagnostic adoption (local, 2026-10-25): the session exposes its actual lease-file
URL without exposing the lease object. App log/audit and host events/snapshot/recovery
guards receive it through the shared inventory. Code: [StateRootSession.swift](../../Sources/PlatformMac/StateRootSession.swift),
[the shared inventory](../../Sources/ProxyControlBridge/ProxyControlBridgeProtectedDiagnosticResources.swift).
Actual app-log and host composition witnesses preserve lock bytes/inode and keep a
second writer busy; audit composition remains source-reviewed plus guarded-sink
coverage. [Verification and limits](../verification-protected-log-2026-10-25.md).
This does not establish complete non-owning-tool coverage or production shutdown.

The startup handoff correction for [#237](https://github.com/srps/Conduit/issues/237) restores a synchronous GUI entry while keeping actual bootstrap effects on `PlatformWork`, before AppState composition. Real built-entry busy/name/root refusal probes preserve original bytes, and a separate FakeMachine dev launch delivers the background file-log failure and a network-path callback. The prior window-only smoke missed the async-main starvation. See [the scoped startup handoff evidence](../verification-gui-startup-handoff-2026-10-25.md). This does not complete store/workflow adoption, bounded shutdown or installed-version handoff.

## Open questions

Concrete lease/store APIs, acquisition failures and writer inventory are
implementation obligations. Prove the old-version upgrade ordering and select
measured total shutdown/helper budgets before adoption. Config field projection,
coupled receipts and listener handoff remain separate affected-slice gates.
