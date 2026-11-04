# 0041: Decline a launch restore on an inconclusive liveness probe, and tell the user

- Date: 2026-11-04
- Decision: proposed
- Implementation: implemented
- Validation: none
- Supersedes: none
- Superseded by: none

## Context

At launch, recovery checks whether another Conduit session is still live before it restores system DNS or system proxy settings. The DNS probe is a 2 s UDP query to port 53; the proxy probe is a 0.25 s loopback connect. Before #201 both returned a Bool, so a timeout read as "no live session" and recovery restored settings from under a session that was only slow ([liveness audit](../liveness-audit.md), finding 4, rows E1 and E2).

#48's ownership leases are the full fix. #201 asked for an interim: a timeout declines the restore with an event, and only a refusal, or a definite "not ours", restores.

Observed while implementing it: the privileged helper's DNS relay outlives a killed session. It keeps port 53 and forwards to the dead forwarder, dropping every query, so it reads as a slow session. With "Manage system DNS" on, a crash then leaves the Mac's DNS pointing at a relay that does not answer, and every launch declines. A fix that asked the configured forwarder port instead was tried and dropped: that port is only this launch's guess at the relay's target, so it could restore under the live session the interim protects.

## Decision

- Both probes return live, not live or inconclusive. Only not live restores. Inconclusive declines with `platform.launch_recovery_declined reason=probe_inconclusive` and keeps the records for a later launch.
- A declined system DNS restore is host state carried in the control snapshot (`systemDNSRecoveryDeclined`). The app posts a notification and shows a notice on the menu and on Overview with Start DNS (the existing DNS Start) and Restore DNS Settings (the existing DNS Stop, whose teardown puts back the recorded servers). The user chooses that restore, so a timeout itself still restores nothing.
- The decline clears when system DNS is written (a DNS Start, a DNS Stop or a management change that fully lands) or when the current run's health timer finds the relay answering.
- System proxy gets no notice: a crashed proxy port refuses connections, so its recovery still restores at launch.

## Alternatives

- Restore on timeout (the old behaviour): undoes a slow live session's settings.
- Probe the configured forwarder port when the relay times out: the configured port need not be the relay's target, and under the writer lease (0017) the only live session recovery can run beside is another root's, whose port the configuration cannot name.
- Decline silently: leaves a crashed run's DNS broken with no explanation.
- A helper relay that refuses when its forward target is gone: removes the user action, but needs a helper change and a reinstall. It is the follow-up.

## Consequences

- After a crash with system DNS managed, DNS needs one user action until the helper follow-up lands.
- Restore DNS Settings is a DNS Stop, so it also saves the DNS module off; the next proxy Start does not bring DNS with it. Start DNS turns it back on.
- One additive control snapshot field, absent on the wire when false.

## Invariants and verification

- A timed-out probe never restores: `SystemDNSManagerTests.testRestoreIfNeededLeavesASlowSessionAlone` (real silent UDP socket), the probe-fake recovery tests on both surfaces, and pm-sim `launch-recovery-inconclusive-probe`.
- The notice appears with no command and clears only on a write or an answering relay: `AppStateHarnessTests` declined-recovery tests, `RuntimeHostDNSHealthTests.testAnAliveReadingClearsADeclinedSystemDNSRecovery`, `testASupersededRelayRestartKeepsADeclinedSystemDNSRecovery`, `RuntimeHostInteractiveTests.testAFailedDNSStartWhoseRestoreKeptTheRecordKeepsTheDecline`.
- Disproved by: a launch whose probe timed out changing system DNS or proxy settings, or a notice that clears while system DNS still points at a relay that does not answer.

## Implementation evidence

Implemented in #270: `LoopbackLiveness` in [`LoopbackPortProbe.swift`](../../Sources/PlatformMac/LoopbackPortProbe.swift), the recovery decisions in [`SystemDNSManager.swift`](../../Sources/PlatformMac/SystemDNSManager.swift), [`SystemProxyManager.swift`](../../Sources/PlatformMac/SystemProxyManager.swift) and [`LocationSettingsRecovery.swift`](../../Sources/PlatformMac/LocationSettingsRecovery.swift), the host state in [`RuntimeHost.swift`](../../Sources/ConduitRuntime/RuntimeHost.swift), and the notice in [`SystemDNSRecoveryNotice.swift`](../../Sources/Conduit/Views/SystemDNSRecoveryNotice.swift). Tests: [`SystemDNSManagerTests.swift`](../../Tests/ConduitTests/SystemDNSManagerTests.swift), [`AppStateHarnessTests.swift`](../../Tests/ConduitTests/AppStateHarnessTests.swift), [`RuntimeHostDNSHealthTests.swift`](../../Tests/ConduitTests/RuntimeHostDNSHealthTests.swift), [`RuntimeHostInteractiveTests.swift`](../../Tests/ConduitTests/RuntimeHostInteractiveTests.swift); scenario [`LaunchRecoveryScenarios.swift`](../../Sources/pm-sim/LaunchRecoveryScenarios.swift).

Does not prove: behaviour on an installed build after a real crash with the installed helper's relay.

## Open questions

- The owner's authorization for 5A and for the notice still has to be recorded on #201 or #270 before this record is accepted.
- The helper follow-up: a relay that answers with a refusal once its forwarder is gone.
