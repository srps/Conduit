# 0041: Decide DNS launch recovery from the helper's relay witness

- Date: 2026-11-05
- Decision: accepted (owner, 2026-11-05, [#275 comment](https://github.com/srps/Conduit/pull/275#issuecomment-6648861923): chose design B now and design C later, with the #270 notice kept as the fallback)
- Implementation: implemented
- Validation: pending
- Supersedes: none
- Superseded by: none

## Context

With "Manage system DNS" on, the machine's DNS points at the helper's relay on
`127.0.0.1:53`, which forwards to the session's DNS forwarder
([#201](https://github.com/srps/Conduit/issues/201)). The helper is a
`KeepAlive` LaunchDaemon and outlives the app. After the app crashes, the relay
still holds `:53` and forwards to a port nothing serves, so it answers clients
nothing. Launch recovery asked `:53` whether a session still lives, and silence
cannot tell a dead session from a slow one. The user was left to notice that DNS
was broken and click.

The owner asked for the proper fix: the next launch restores the user's DNS on
its own, with no notice or click, and never restores under a live session.

Observed: the relay's forward socket is connected to its target, so when nothing
listens there, loopback answers with a port-unreachable and the kernel reports
`ECONNREFUSED` at once (`UDPRelayTests`, `pm-sim dns-relay-witness`). Only the
helper knows which port the relay feeds; the app's configured forwarder port is
only this launch's guess at it.

## Decision

Recovery takes ownership of the DNS surface from OS evidence the helper
reports, not from a timed probe of `:53`.

- The helper answers `dns-relay-status` with whether its relay holds `:53`, the
  relay's target port, and what one query on a fresh connected socket to that
  port found: `refused`, `answered`, `silent` within a 100 ms bound, or
  `notRunning`.
- The command and its two optional reply fields (`dnsRelay`, and `features` on
  the ping reply) are added within helper protocol v5, without a version bump.
- The relay's forwarding is unchanged. An orphaned relay never answers clients
  in its target's place.
- Launch recovery restores on `refused`, or on `notRunning` with `:53` refusing.
  It declines as a live listener on `answered`. On `silent`, or when the helper
  gives no status, it keeps the fallback the #270 notice provides: decline,
  and offer Start DNS and Restore DNS Settings ([0042](0042-fall-back-to-the-probe-and-a-notice.md)).
- Design C, a helper that tracks its caller and restores on that caller's exit
  (the DNS slice of [#48](https://github.com/srps/Conduit/issues/48)), follows
  later under its own decisions. Its owner verdict is a further optional field.

## Alternatives

- **A version bump to v6:** every installed v5 helper would refuse every v6
  frame, and the client's exact-match guard would send every privileged
  operation to an admin prompt until a reinstall, except location-scoped
  writes, which would fail outright.
- **Probe the configured forwarder port from the app:** that port is a guess at
  the relay's target, which the helper alone knows.
- **Have the orphaned relay answer SERVFAIL:** an older app's `:53` probe reads
  any reply as a live session and would decline forever.
- **Restore under the state-root writer lease alone:** misses a pre-lease binary
  or a second root that is still live on the relay.
- **Design C now:** the full answer for #48, but it needs helper persistence of
  priors and owner timings first.

## Consequences

A crash with "Manage system DNS" on is repaired at the next launch with no
click, once the helper is reinstalled. Until then a v5 helper that predates the
command answers "Invalid request", which the app reads as no witness and the
#270 fallback handles. Old apps never send the command and ignore the new keys.
A status read adds at most the 100 ms probe bound to the time it holds the
helper's single accept loop. A forwarder port another process takes between the crash and the
relaunch reads `answered` or `silent`, so recovery declines rather than
restoring wrongly.

## Invariants and verification

- A target nobody serves reads `refused` without waiting the bound; a held,
  silent port reads `silent`; a replying port reads `answered`.
- A helper that answers without a status yields no witness, never the
  AppleScript fallback and never an unreachable error.
- Recovery never restores on `answered`, `silent` or a missing witness.

Disproved by a restore while a session's forwarder still answers, or by a
crash that a reinstalled helper reports as anything but `refused`.

## Implementation evidence

The helper and contract side:
[`UDPRelay.status`](../../Sources/ProxyKernel/Network/UDPRelay.swift),
[`HelperContract.swift`](../../Sources/ConduitShared/HelperContract.swift),
[`HelperDaemon.swift`](../../Sources/ConduitHelper/HelperDaemon.swift) and
`HelperToolPrivilegeClient.dnsRelayStatus` in
[`HelperPrivilegeClient.swift`](../../Sources/PlatformMac/HelperPrivilegeClient.swift),
with [`UDPRelayTests`](../../Tests/ConduitTests/UDPRelayTests.swift),
[`HelperDNSRelayStatusTests`](../../Tests/ConduitTests/HelperDNSRelayStatusTests.swift)
and [`pm-sim dns-relay-witness`](../../Sources/pm-sim/DNSRelayWitnessScenarios.swift).

Launch recovery reads it in #270: `SurfaceOwnership` in
[`LaunchRecovery.swift`](../../Sources/PlatformMac/LaunchRecovery.swift) and
`SystemDNSManager.ownership` in
[`SystemDNSManager.swift`](../../Sources/PlatformMac/SystemDNSManager.swift).
A refused target is read again after half a second and must still refuse on
the same port, because a live forwarder that rebinds its port reads refused
for that moment; the writer lease (0017) would settle only same-root sessions,
and its role in recovery is still the open question below. Recovery that acts on
a witnessed refusal also stops the orphaned relay, whatever it then ends in: a
restore, leftover settings cleared with no records, or a failure such as an
unreadable journal. Where the witness does not decide and the `:53` probe does,
the restore or decline event names why in `witness=`, and a machine with no
helper binary reads `witness=no_status` without asking the socket. A helper whose ping lists no
`dns-relay-status` feature shows as "Installed, update available" in Settings
(`HelperToolPrivilegeClient.Status.updateAvailable`), and the same feature list
tells a helper that predates the command from one that failed it. The ping's
`features` decode strictly: a value that is not an array of strings breaks the
frame, since only a foreign or broken helper sends one; unknown names in the
array are dropped. Tests:
[`SystemDNSManagerTests`](../../Tests/ConduitTests/SystemDNSManagerTests.swift)
`testLaunchRecoveryDecidesSystemDNSOwnershipFromTheRelayWitnessFirst` and
`testAProbeDecisionNamesWhyTheWitnessDidNotDecide`,
[`NetworkLocationRecoveryTests`](../../Tests/ConduitTests/NetworkLocationRecoveryTests.swift)
`testAWitnessedRefusalStopsTheRelayWhateverTheRestoreEndsIn`,
[`AppStateHarnessTests`](../../Tests/ConduitTests/AppStateHarnessTests.swift)
`testACrashedRunsSystemDNSIsRestoredAtLaunchWhenTheHelperFindsItsRelayTargetRefused`,
`testALocationScopedCrashIsRestoredAtLaunchWhenTheHelperFindsItsRelayTargetRefused`,
`testARefusalThatTheSecondReadingContradictsDeclinesAsALiveListener` and
`testARelayTargetThatAnswersDeclinesAsALiveListener`, and
[`pm-sim launch-recovery-ownership`](../../Sources/pm-sim/LaunchRecoveryScenarios.swift),
which includes a real `UDPRelay` aimed at a closed port.

Does not prove: the installed helper on `:53` as root, or recovery on a real
machine after a crash. A Mac that suppresses ICMP port-unreachable replies
(`net.inet.udp.blackhole`) is inferred to read every dead target as `silent`
and so always takes the 0042 fallback; not observed.

## Open questions

- Whether the state-root writer lease ([0017](0017-exclusive-state-directory-writer.md))
  is accepted as same-root authority in recovery, with pre-lease binaries left to
  the witness.
- Owner validation is due once recovery uses the witness: installed build,
  helper reinstalled, DNS managed, `kill -9` the app, relaunch, DNS restored with
  no click.
