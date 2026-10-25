# 0028: Fixed writable state filenames within the canonical root

- Date: 2026-10-25
- Decision: accepted (owner, 2026-10-25, #186 fixed writable filenames checkpoint)
- Implementation: planned
- Validation: none
- Supersedes: 0020
- Superseded by: none

## Context

Decision [0020](0020-canonical-runtime-writer-root.md) retained custom in-root
writable config names for daemon CLI compatibility. The app already uses
`config.json`; the future client submits typed values rather than file paths.
The owner chose fixed writable filenames after reviewing that compatibility
cost and the simpler ownership shape, recorded in
[#186](https://github.com/srps/Conduit/issues/186).

A scratch headless run also demonstrated a configuration named `snapshot.json`
being overwritten by diagnostic output ([#233](https://github.com/srps/Conduit/issues/233)).
Fixed writable names remove that direct writable-name case, but aliases and
arbitrary read-only inputs still require diagnostic destination protection.

## Decision

Keep authoritative runtime configuration, platform settings, app preferences and
the platform recovery journal within one canonical state root, using the fixed
logical filenames `config.json`, `platform.json`, `preferences.json` and
`platform-state.json`, respectively. The app and daemon cannot select arbitrary
writable component names through CLI or package composition. Safe isolated
fixtures use the same layout beneath their own scratch root.

Carry forward 0020's remaining rules: acquire the root's exclusive writer
authority before migration writes or machine recovery/reconciliation; retain it
until physical writes are quiescent or process exit. Resolve containment,
reserved-resource collisions and canonical identities behind the persistence
boundary. Write resolved authoritative targets, preserving supported aliases;
fixed logical names are not a blanket symlink or hardlink ban. Clients receive
no persistence-path authority.

The daemon may keep `--config /path/config.json` as a compatibility spelling
that derives its root from the parent when no root is otherwise selected.
Refuse an unsupported custom writable filename or an outside config combined
with an explicit root before migration writes or recovery. Explain how to move
or rename the intended file to `config.json` beneath the selected root. Do not
silently copy, import, overwrite or rename it. Stop an existing host before a
manual move; explicit one-time import remains a separate possible feature.

Retain arbitrary read-only `--config` inputs for diagnostic tools, including
pm-proxy's in-memory-only migration and pm-dns/pm-tunnel reads. Their runtime
resources still obey exclusive host ownership where applicable. Diagnostic
failures cannot gate control or grant mutation authority; protect snapshot,
audit, events and rotating-log destinations against authoritative files and
aliases. Updater metadata retains its separate writer. This does not assign all
files under the root to one persistence component.

## Alternatives

- **Keep arbitrary in-root writable names:** preserves daemon compatibility but
  adds layout variants without a demonstrated product workflow or future-client
  requirement. Not selected.
- **Automatically copy or rename a custom config:** adds implicit mutation,
  conflict and repeat-import behavior; it can overwrite newer saved intent.
  Explicit guidance is sufficient for this compatibility change.
- **Remove arbitrary read-only inputs too:** unnecessarily restricts safe
  diagnostics and scratch testing without simplifying writable authority.
- **Treat fixed names as sufficient protection:** misses symlink/hardlink aliases
  and read-only inputs colliding with diagnostics. Existing identity checks and
  guarded writers remain necessary.
- **Component leases or a global registry:** preserve writable sharing across
  roots at the acquisition, recovery and compatibility cost recorded in 0020.
  No demonstrated need justifies those mechanisms now.

## Consequences

One root has one stable writable layout, matching the future sole-writer daemon.
This deliberately removes existing custom-name daemon compatibility. Old files
are preserved on refusal and can be deliberately moved by the operator.

Root authority still excludes only cooperating processes. It does not make
multi-file saves atomic, prevent an external editor racing after a check,
establish power-loss durability, or establish exclusive machine-setting
ownership. Old binaries do not recognize a new protocol merely because names
are fixed. Versioned handoff and actual writer adoption remain required.

## Invariants and verification

Test default and isolated app roots, daemon `--config` with the fixed name,
custom-name and split-root refusal before any migration/recovery, and byte
preservation on refusal. Exercise package composition, canonical symlink and
hardlink aliases, reserved-resource collisions, missing paths and atomic
replacement. Preserve arbitrary read-only tool inputs and in-memory migration.

Use scratch subprocesses for competing owners, alias roots, descriptor
inheritance and exit. Diagnostic collision tests must preserve protected bytes
while control continues. No claim about deployment filesystem behavior follows
from fixture tests alone.

## Implementation evidence

None yet for the fixed writable-name requirement. Existing resolver/store and
lease foundations implement portions of the carried-forward root policy; their
bounded evidence and outstanding startup adoption are recorded in 0020.

Does not prove: startup naming enforcement, complete writer adoption, installed
version handoff, real-machine recovery or deployment-storage semantics.

## Open questions

Revisit only for a demonstrated writable layout/sharing workflow that one
canonical root plus read-only input or explicit import cannot serve. Keep any
extension behind the persistence boundary; evaluate bounded component leases
before a registry and prove mixed-version/quiescent handoff. An importer needs
its own conflict, preservation and authorization policy before implementation.
