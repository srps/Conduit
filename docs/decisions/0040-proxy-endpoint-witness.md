# 0040: Witness a port-0 session's advertised proxy endpoint beside the journal

- Date: 2026-11-04
- Decision: proposed
- Implementation: implemented
- Validation: none
- Supersedes: none
- Superseded by: none

## Context

With the proxy port set to 0, the system proxy advertises the port the listener
bound, not port 0 ([#251](https://github.com/srps/Conduit/issues/251)). The
journal records that port per service, so a readable journal restores it. When
the journal is unreadable at the next launch, launch recovery matched HTTP and
HTTPS residue only by the configured client host and port. Port 0 names no
endpoint on the machine, so `127.0.0.1:<ephemeral>` stayed on every service,
pointing at a listener that no longer exists
([#269](https://github.com/srps/Conduit/issues/269)).

The owner's constraint: recovery must never clear a loopback proxy another tool
owns (px, Charles, a corporate agent on 127.0.0.1). "The port is 0, so any
loopback proxy is ours" is out unless positive evidence says the setting is
Conduit's, and fixed-port behaviour must not change.

Decision [0028](0028-fixed-writable-state-filenames.md) fixes four writable
leaves under the canonical root and denies diagnostic artifacts any mutation
authority, which rules out reading `snapshot.json` for the bound port.

## Decision

Keep a fifth fixed leaf, `platform-state.proxy-endpoint.json`, beside the
journal. It holds one bounded CanonicalJSON record, version 1, of the loopback
host and port a port-0 manual apply advertises. The proxy-surface apply writes
it before its first commit and fails, writing nothing, if it cannot. A PAC
apply, a fixed-port apply, a release, a launch recovery that leaves no proxy
records, and a residue sweep that used it all remove it.

A residue sweep (unreadable journal or legacy records) clears an HTTP or HTTPS
endpoint only on an exact host and port match with the configured fingerprint
or with that record. An absent or unreadable record adds nothing, so a foreign
loopback proxy is never cleared on its say-so. Each sweep reports the evidence
it used as `platform.location_residue_identity`. The name is reserved in the
state-root layout and protected from every diagnostic destination.

## Alternatives

- **Read `bindings.proxyPort` from `snapshot.json`:** no new file, but 0028
  denies diagnostics mutation authority, its drain is unordered against the
  proxy write, and recovery would decode the kernel snapshot schema.
- **Treat any loopback proxy as ours when the port is 0:** rejected by the
  owner; other tools live there.
- **Probe the port and clear it when nothing listens:** a stopped foreign proxy
  is dead too, and clearing it is the forbidden act.
- **Tag Conduit's proxies dictionary on the machine:** changes the helper IPC
  validation and cleanup allowlists, needs a helper reinstall, and the marker
  would sit in the user-visible bypass list.

## Consequences

A crashed port-0 session no longer strands the machine's proxy on an
unreadable journal, and the sweep's choice is observable. The root holds one
more fixed file of at most 1 KiB. A port-0 apply now also fails when that file
cannot be written, the same policy the journal's capture failure sets. Fixed
ports never write the record, so their recovery is unchanged.

A stale record whose exact host and ephemeral port another tool later took,
together with an unreadable journal, would clear that tool's setting. The
record is retired at every release and recovery, which keeps that window to
a session that crashed.

## Invariants and verification

- Only an exact host and port match clears an HTTP or HTTPS endpoint; a foreign
  loopback proxy on another port stays.
- The record exists only while a port-0 manual apply is outstanding, and is
  written before the first commit of that apply.
- An unreadable record is reported with a closed reason and is never used.

Disproved by a sweep that clears a loopback endpoint the record does not name
while the configured port is 0, or by a port-0 session whose crash leaves
ephemeral residue with no record.

## Implementation evidence

[`ProxyEndpointWitness.swift`](../../Sources/PlatformMac/ProxyEndpointWitness.swift)
holds the record, its bounded read and atomic write;
[`LocationSettingsRecovery.swift`](../../Sources/PlatformMac/LocationSettingsRecovery.swift)
records, retires and matches it. The fake is `InMemoryProxyEndpointWitness` in
[`PlatformFakes.swift`](../../Sources/PlatformMac/PlatformFakes.swift).
[`StateRootLayout.swift`](../../Sources/PlatformMac/StateRootLayout.swift)
reserves the name and
[`ProxyControlBridgeProtectedDiagnosticResources.swift`](../../Sources/ProxyControlBridge/ProxyControlBridgeProtectedDiagnosticResources.swift)
protects it. [`NetworkLocationRecoveryTests.swift`](../../Tests/ConduitTests/NetworkLocationRecoveryTests.swift)
covers ours cleared and foreign kept, no record, unreadable records, a refused
write, retirement and the live-listener decline; the
[`network-location-recovery`](../../Sources/pm-sim/NetworkLocationScenarios.swift)
pm-sim scenario checks the same under a corrupt journal.

Does not prove: a crash and relaunch of an installed build with a real network
location and a real foreign proxy beside it.

## Open questions

- Whether a gateway-mode port-0 session, whose client host is not loopback,
  should be witnessed too. It is not today.
