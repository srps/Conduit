# Writer authority: canonical state-root checkpoint

Status: owner selected this shape on 2026-10-24;
[0020](decisions/0020-canonical-runtime-writer-root.md) records the decision.
It refines 0017 writer-lease coverage before persistence adoption; no lease or
asynchronous store is implemented yet.

## Recommendation

Keep authoritative runtime configuration, platform settings, app preferences and
the platform recovery journal within one canonical state root. Acquire its lease
before migration writes or recovery/reconciliation. Custom in-root config names
remain valid: the rule is containment, not a requirement to use `config.json`.
Two cooperating hosts cannot write that root concurrently. The future daemon
owns it while clients retain drafts and submit private updates.

Refuse a **daemon** configuration outside its selected state root with an
explicit error and migration guidance. Do not silently import it on every launch:
that could overwrite settings subsequently saved through the daemon client.
A deliberate import operation can be designed separately if needed.

This has a narrow compatibility effect:

| Invocation or caller | Proposed behavior |
| --- | --- |
| App using its default or isolated state directory | Unchanged paths |
| `ConduitDaemon --config /somewhere/custom.json` | Remains valid: the file's parent is its state root |
| Daemon with `--state-dir X --config Y`, where Y is outside X | Refuse before migration writes or machine recovery |
| Daemon with `PM_CONFIG_DIR=X` and outside `--config Y` | Same refusal |
| `pm-proxy --state-dir X --config Y` | Keep Y as read-only input; runtime artifacts remain in X |
| `pm-dns` / `pm-tunnel` configuration reads | Unchanged |
| Package-only mutable-file overrides | Constrain actual writer composition to the root; preserve safe isolated fixtures |

`ProxyConfigPersistence.load` used by pm-proxy migrates in memory without saving;
the daemon uses `loadAllMigrating`, which can save to its configured path.
That distinction matters: an external input does not automatically require
external write authority. Competing runtime hosts refusing an owned state root
is already selected in 0017, not a new decision here.

## Alternative

Preserve writable external components using a bounded set of stable per-component
sidecar leases **in addition to** the root lease. Acquire all required authority
in a consistent order or release the whole attempt; retain it until physical
writes are quiescent. Coordination must survive atomic data-file replacement.
This preserves the daemon split-path case but adds lock-file placement,
permissions, alias resolution and cleanup obligations. Locking the replaceable
data inode does not supply that guarantee. A permanent hashed registry is not
bounded merely because active descriptors have a fixed cap.

Every participating writer needs those component leases, including writers with
in-root files. Locking only an external file in the split-path host would not
conflict with an in-root writer that took only its root lease.

Other approaches do not meet the same requirement:

| Approach | Limitation |
| --- | --- |
| Process-local serial queue | Does not exclude a second process |
| PID checks and launch ordering | Leaves every launch path responsible for avoiding overlap; no shared write authority |
| Locking the data inode | Atomic replacement leaves the lock attached to the old file |
| One global runtime lock | Also excludes otherwise independent isolated state roots |
| Global component ownership registry | Adds synchronization, stale-entry recovery and bounded retention obligations |
| Re-import an external config every launch | May replace newer client-saved intent; deliberate import remains a separate viable operation |

Neither finalist makes multiple file commits atomic, excludes old binaries that
ignore the protocol, or proves exclusive machine-setting ownership. The later
production-daemon ownership/recovery milestone remains separate.

## Boundaries and evidence

Claude reviewed the inventory through the owner's claude.ai Max subscription;
Codex checked the actual executable parsers and persistence entry points.
The review initially overstated the compatibility change: `--config` alone
already derives its root from the parent and pm-proxy does not save migrations.
The table above reflects those corrections. No split-path production usage was
found in checked docs/scripts; that is not proof nobody uses it.

The root lease also establishes which host may own runtime resources such as
control/ready files. Those resources are not component commit receipts.
Diagnostic destinations are not configuration write authority; their failure
cannot gate control. App updater metadata has its own writer and is not silently
assigned to the future daemon by this proposal.

The audit-path collision reproduced in an owned scratch directory is tracked in
[#222](https://github.com/srps/Conduit/issues/222). Disable an unsafe sink with a
structured diagnostic while preserving control; do not reject all external audit
destinations or make that failure a startup gate.

Verify canonical aliases, missing paths, replacement and supported filesystem
semantics with owned subprocesses/fixtures. No blanket symlink, hardlink or
network-filesystem ban is selected. Older binaries and external editors remain
nonparticipants in the advisory protocol. This proposal does not establish
power-loss durability or helper-owned recovery.

## Revisit and future work

Revisit when a demonstrated workflow needs authoritative writable components
shared across roots and read-only input or deliberate import cannot meet it.
Evaluate bounded component leases before a global registry. Preserve the client
contract by keeping coordination behind the persistence boundary, but require
versioned/quiescent handoff and mixed-version checks: old root-only hosts cannot
recognize new component or registry authority. A later change needs a new record,
bounded recovery/retention and deployment evidence; it is not a transparent swap.
