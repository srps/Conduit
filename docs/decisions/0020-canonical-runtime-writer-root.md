# 0020: Keep runtime persistence within one canonical writer root

- Date: 2026-10-24
- Decision: accepted (owner, 2026-10-24, #186 canonical writer-root checkpoint)
- Implementation: planned
- Validation: none
- Supersedes: none
- Superseded by: none

## Context

[0017](0017-exclusive-state-directory-writer.md) selects an exclusive OS-backed
writer lease per state directory. That does not protect an authoritative file
outside the directory when another host reaches it through a different root.
The executable/persistence inventory found one such writer case: ConduitDaemon
combines `--state-dir` (or PM_CONFIG_DIR) with an outside `--config`, then may save
migrations to that config. pm-proxy loads/migrates its config in memory without
saving it. The app already keeps these persistence components together.

Claude reviewed the alternatives using the owner's claude.ai Max subscription;
Codex checked the actual parsers and persistence entry points. The owner accepted
the simpler root-based shape after reviewing its compatibility effects and the
limitations of a later extension, recorded in
[#186](https://github.com/srps/Conduit/issues/186). The fuller comparison is in
[the state-root review](../design-runtime-state-root-review.md).

## Decision

Keep authoritative runtime configuration, platform settings, app preferences
and the platform recovery journal within one canonical state root. Custom
in-root config names remain valid; containment, not a fixed basename, is the
rule. Acquire the root's writer authority before migration writes or machine
recovery/reconciliation, as 0017 requires. Retain it until physical writes are
quiescent or process exit. Keep path resolution and lease mechanics behind the
persistence/platform boundary rather than exposing them through the client.

Refuse the daemon's writable split-path case explicitly before those actions.
`ConduitDaemon --config /path/custom.json` remains valid because its parent is
the root. An outside `--config` combined with a separate state directory fails
with migration guidance. Do not silently re-import an outside file every launch
and overwrite newer client-saved intent.

Preserve pm-proxy's outside read-only configuration inputs and the read-only
configuration behavior of pm-dns/pm-tunnel. Their runtime resources still obey
the already-selected exclusive host ownership rule. Constrain package-level
writer composition as well as CLI parsing; preserve safe isolated fixtures.

This is authority for the cooperating runtime persistence writers, not a claim
that every file under the root has the same owner. Runtime control/ready
resources need a unique host but are not component commit receipts. Updater
metadata has a separate writer; do not silently move it into the daemon.
Diagnostic destinations are not mutation authority and their failures cannot
gate control. The unsafe audit-target bug is tracked separately in
[#222](https://github.com/srps/Conduit/issues/222).

## Alternatives

- **Root plus component leases:** preserves authoritative external files, but
  every participating writer, including in-root writers, must acquire the
  appropriate stable component leases. Adds acquisition ordering, permissions,
  canonical alias handling and lock-file lifetime/cleanup obligations. Limiting
  active descriptors does not bound an accumulating on-disk registry.
- **Process-local queue:** does not exclude another process.
- **PID checks or launch ordering alone:** leaves exclusion to every launch path;
  useful for old-version handoff but not the selected long-term authority.
- **Lock the data inode:** atomic replacement can leave the lock on the old file.
- **One global lock:** excludes otherwise independent isolated state roots.
- **Global ownership registry:** can represent overlaps but adds synchronization,
  stale-entry recovery, retention and compatibility state without a demonstrated
  need in the selected daemon shape.
- **Copy an outside config every launch:** risks replacing newer saved intent.
  A deliberate one-time import remains a viable separate feature if needed.

## Consequences

The root is a coherent ownership unit and a direct fit for one daemon writer
with draft-holding clients. The daemon split-path write behavior changes;
ordinary `--config` and read-only headless inputs remain supported. A root lease
does not make multi-file saves atomic, exclude nonparticipating old binaries or
editors, establish power-loss durability, or solve exclusive ownership of machine
settings. Those remain separate obligations.

## Invariants and verification

Test actual root authority with owned subprocesses and scratch directories:
two-owner attempts, canonical aliases, missing paths, atomic replacement,
descriptor inheritance, timeout, late writes and process exit. Verify busy or
invalid-root startup cannot reach migration writes or machine recovery. Check
all mutating entry points, not only the normal save method. Exercise the CLI
compatibility cases above and preserve in-memory-only headless migration.

Probe supported filesystem and link semantics before relying on them; no blanket
symlink, hardlink or network-filesystem ban is selected here. Diagnostic collision
handling must preserve protected bytes and continued control. Unit/model evidence
does not establish behavior on the owner's deployment storage.

## Implementation evidence

None yet. The inventory and scratch audit reproduction do not implement writer
coverage, the OS lease or the asynchronous store.

Does not prove: cross-process exclusion, complete writer coverage, startup
ordering or real-machine recovery.

## Open questions

Revisit this decision if an actual workflow requires authoritative writable
components shared across roots, or shared-resource coordination cannot be
expressed through one owner plus read-only input/explicit import. Evaluate a
bounded component-lease set first; a global registry is a possible mechanism,
not the target architecture by default.

That extension can preserve the client contract and most RuntimeHost code when
kept behind the persistence boundary. It is **not** a transparent protocol swap:
root-only old hosts cannot recognize new component/registry authority. Record a
new decision and prove versioned/quiescent handoff and mixed-version behavior
before enabling it. Keep the registry, if needed, bounded with explicit recovery
and retention rules.

Actual filesystem semantics, complete mutation inventory, total shutdown bounds
and later production-daemon machine ownership/recovery remain validation work.
