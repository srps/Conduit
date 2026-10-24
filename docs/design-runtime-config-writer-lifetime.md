# Configuration writer lifetime: selected shape

Status: selected by the owner, 2026-10-24; recorded in
[decision 0017](decisions/0017-exclusive-state-directory-writer.md). This resolves
the writer-lifetime gate in decision 0015. Implementation is planned. The current client/event foundation
and behavior-preserving host extraction can proceed independently.

## Required invariant

Under the planned asynchronous writer, a save that has started can outlive the
caller's deadline. This is a design hazard before that migration, not a reproduced
late-overwrite bug in today's synchronous persistence call. A newer Conduit process
must not save B while an older process can still replace the same component with
A. A process-local serial queue and revision-tagged completions cannot establish
that invariant across process lifetimes.

Planned failure history: the old app starts saving enabled intent, Quit stops waiting at its total
deadline, the replacement app saves disabled intent, then the old save completes.
Without a handoff rule, disk can end up enabled while the replacement believes it
saved disabled. Stop/Quit still fence runtime apply immediately; file ownership
must also prevent the late overwrite.

## Alternatives

| Shape | Guarantee and cost |
| --- | --- |
| **A. Exclusive OS-backed writer lease (recommended)** | The configuration store acquires a nonblocking advisory file lock for its state directory. Keep it while queued/started writes may still complete. A competing modern instance cannot become the writer; process death releases the kernel lock. Adds a lock adapter/fake and explicit busy/startup behavior, with no snapshot history or TTL registry. |
| **B. Relaunch handoff only** | Start a new writer only after the old writer is proved quiescent or its process has exited. No new lock file. Every launch/relaunch path must enforce this; concurrent manual launches remain unsupported until the later daemon-ownership milestone. |

A supports the later daemon-side store: transfer which process owns the lease,
while clients keep editor drafts. It does not make config/platform/prefs atomic,
provide power-loss durability, stop external editors that ignore the lock, or
implement #48's helper leases and durable machine recovery.

## Proposed A lifecycle

- Acquire before the instance can become a writer or start runtime reconciliation.
  Busy is an explicit result; never block MainActor waiting for another process.
  The proposed initial behavior is to report that another host owns this state
  directory and refuse runtime startup; attaching to that host becomes possible
  with the future daemon client. Do not silently run a second host in read-only mode.
- A second in-process-host instance for the same state directory does not start
  another runtime when it cannot acquire authority. A later daemon client joins
  the existing owner instead of trying to become a writer.
- One authority serializes the configuration component writes and checks expected
  prior revisions (already required by 0015). The lock and revision checks solve
  different problems: exclusion across processes and stale/ambiguous saves.
  A lease does not choose a new persisted generation schema; use authoritative
  component receipts and settle their concrete representation with the store.
  A caller timeout detaches its wait; it does not cancel a started physical write
  or release authority underneath it.
- Release only after owned writes are quiescent, or let process exit release it.
  Do not explicitly unlock while a timed-out write still runs.
- The descriptor is close-on-exec so spawned workers cannot retain authority after
  the owner exits. Keep the lock inode; deleting/recreating a held lock file would
  permit two leases on different inodes. State-directory deletion/replacement
  while a host owns it is likewise forbidden, including scratch-test cleanup: join
  the owning fixture before deleting its directory.
- Upgrading from a version that does not honor this lease still needs the existing
  old-process-exit handoff. An advisory lock cannot exclude an older binary or an
  external editor that does not participate.

The state-directory authority must be shared by every cooperating writer, including
configuration, platform preferences and platform-state journal composition. This
does not move the journal into the config store: each keeps its existing owner.
Audit all entrypoints before adoption; one unlocked writer defeats the guarantee.
The lock gates entry to machine effects but does not fence an already-issued helper
request or solve external machine ownership. Unsupported locking must fail explicitly;
network-filesystem semantics need validation if the owner uses such storage.

Put the machine effect behind a PlatformMac protocol with a fake. The store owns
its lease; RuntimeHost receives verified immutable inputs and does not become a
second persistence writer. Dev scratch aliases must include the new coordination
path if this shape is selected. No lease or lock has been implemented yet.

## Review checkpoint

Claude reviewed this proposal through the owner's claude.ai Max subscription.
Codex cross-checked the current AppState save/quit calls: configuration writes
are synchronous today and Quit can invoke immediate reconciliation. The review
clarified that exclusion is not revision checking, old binaries do not participate,
and no busy instance may reach reconciliation. It did not validate Sparkle's old-process-exit ordering or network filesystem behavior.

The owner selected A, including explicit busy-startup refusal and legacy upgrade
ordering, in [#186](https://github.com/srps/Conduit/issues/186). No lock is implemented
yet, and the decision does not select a new persisted generation schema.

## Verification before adoption

Drive the actual store adapter against an independent bounded model: delayed
writes, caller timeout, Stop/Quit, failed/unknown read-back, second-owner attempt,
late old completion, release after quiescence and process exit. Test the real OS
adapter using owned subprocesses and scratch directories. Preserve the serving
Conduit and helper. Select bounded acquisition/drain behavior with measured
shutdown budgets; a lock does not replace save/apply supersession checks.
