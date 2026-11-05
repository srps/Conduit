# 0042: Fall back to the liveness probe and a notice when no evidence decides launch recovery

- Date: 2026-11-04
- Decision: accepted (owner, 2026-11-05, [#270 comment](https://github.com/srps/Conduit/pull/270#issuecomment-6655448179): accepted this record as the fallback that 0041 names)
- Implementation: implemented
- Validation: none
- Supersedes: none
- Superseded by: none

## Context

At launch, recovery asks whether another session still serves the system DNS or system proxy settings a crashed run left before it restores them. Before #201 the DNS probe (a 2 s UDP query to `:53`) and the proxy probe (a 0.25 s loopback connect) returned a Bool, so a timeout read as "nothing live" and recovery restored settings from under a session that was only slow ([liveness audit](../liveness-audit.md), finding 4, rows E1 and E2).

[0041](0041-dns-recovery-from-helper-relay-witness.md) decides system DNS from the helper's relay witness. It names this record as the fallback for what the witness cannot decide: a helper that predates `dns-relay-status`, a helper that cannot be asked, a relay target that stays silent, or a refusal a second reading does not confirm. The proxy surface has no witness. A crashed proxy's port refuses at once, so its probe decides almost every case, and this fallback covers the rest.

## Decision

- Both probes return live, not live or inconclusive. Only not live restores. Inconclusive declines with `platform.launch_recovery_declined reason=probe_inconclusive` and keeps the records for a later launch. For system DNS the event adds `witness=` with why the witness did not decide first.
- A declined system DNS restore that no evidence decided is host state carried in the control snapshot (`systemDNSRecoveryDeclined`). The app posts a notification and shows a notice on the menu and on Overview with Start DNS (the existing DNS Start) and Restore DNS Settings (the existing DNS Stop, whose teardown puts back the recorded servers). The user chooses that restore, so a timeout itself still restores nothing.
- The decline clears when system DNS is written (a DNS Start, a DNS Stop, a management change or a location reconcile's apply that fully lands) or when the current run's health timer finds the relay answering.
- System proxy gets no notice. A system proxy decline ends when this run takes system proxy: a proxy Start whose surfaces come up (whether or not its own apply landed, the up proxy's drift repairs and reapplies write this run's settings), a proxy teardown that runs its clear (a Stop, or a Start that failed and tore down: the user acted on the surface, so what a failed clear left is this run's to retry), or a management switch-off whose clear lands.
- The host keeps the declined surfaces (`RuntimeHost.declinedLaunchRecovery`), for an undecided owner and for a live listener alike, until they end as above. While one stands, the network-location reconcile does not restore that surface's records for a module that is not applying it; it emits `platform.location_restore_withheld reason=launch_recovery_declined` instead. The location observer reports the current location as it starts, right after recovery, so without this the decline would be undone one turn later. A module that is up and applying the surface reconciles as before.
- Settings shows the helper as "Installed, update available" with Update Helper when its ping lists no `dns-relay-status` feature, so the user can leave this fallback for 0041's path.

## Alternatives

- Restore on timeout (the old behaviour): undoes a slow live session's settings.
- Probe the configured forwarder port when `:53` times out: the configured port need not be the relay's target, which only the helper knows (0041).
- Decline silently: leaves a crashed run's DNS broken with no explanation.

## Consequences

- A crash with system DNS managed needs one user action only where 0041's witness cannot decide: the helper predates the witness (until the user updates it), cannot be asked, or sees its relay target stay silent. A Mac that suppresses ICMP port-unreachable replies (`net.inet.udp.blackhole`) is inferred to read every dead target as silent, so it always takes this path; not observed.
- Restore DNS Settings is a DNS Stop, so it also saves the DNS module off; the next proxy Start does not bring DNS with it. Start DNS turns it back on.
- One additive control snapshot field, absent on the wire when false.
- With a decline standing, a location switch while the module is down leaves the crashed run's settings on every location until the user acts, a write ends the decline, or a later launch restores them.
- The `:53` probe is needed only for helpers that predate the witness. It can go when the minimum helper version is raised past them.

## Invariants and verification

- A timed-out probe never restores: `SystemDNSManagerTests.testRestoreIfNeededLeavesASlowSessionAlone` (real silent UDP socket), `testLaunchRecoveryDecidesSystemDNSOwnershipFromTheRelayWitnessFirst` (each witness reading, and when the probe decides), `testAThrowingWitnessFallsBackToTheProbe`, the probe-fake recovery tests on both surfaces, and pm-sim `launch-recovery-ownership`.
- Without a witness a silent relay keeps the notice: `AppStateHarnessTests.testWithoutAWitnessASilentRelayKeepsTheNotice` (no status, and a helper that throws) and `testASilentRelayTargetKeepsTheNotice`.
- The location observer's first report keeps a declined restore: `AppStateHarnessTests.testTheFirstLocationReportKeepsADeclinedSystemDNSRecovery` and `testTheFirstLocationReportKeepsADeclinedSystemProxyRecovery` (the fake observer reports the current location on start, as `NetworkLocationMonitor` does), and pm-sim `runtime-host-effects`. A location reconcile that applies system DNS clears it: `testALocationReconcileThatRepointsTheRelayClearsADeclinedSystemDNSRecovery`. A live listener's decline holds too: `testTheFirstLocationReportKeepsSystemDNSThatALiveListenerServes`. A proxy decline ends on a Start that comes up or a teardown that runs its clear: `DaemonRuntimeHostTests.testAProxyStartEndsADeclinedSystemProxyRecoveryWhetherOrNotItsApplyLanded`, `testAProxyTeardownThatRunsItsClearEndsADeclinedSystemProxyRecovery`.
- The notice appears with no command and clears only on a write or an answering relay: `AppStateHarnessTests` declined-recovery tests, `RuntimeHostDNSHealthTests.testAnAliveReadingClearsADeclinedSystemDNSRecovery`, `testASupersededRelayRestartKeepsADeclinedSystemDNSRecovery`, `RuntimeHostInteractiveTests.testAFailedDNSStartWhoseRestoreKeptTheRecordKeepsTheDecline`.
- A helper without the feature is offered an update: `HelperCallerRefusalPresentationTests.testAHelperWithoutTheRelayWitnessIsOfferedAnUpdate`.
- Disproved by: a launch whose probe timed out, with no witness evidence, changing system DNS or proxy settings, or a notice that clears while system DNS still points at a relay that does not answer.

## Implementation evidence

Implemented in #270: `LoopbackLiveness` in [`LoopbackPortProbe.swift`](../../Sources/PlatformMac/LoopbackPortProbe.swift), `SurfaceOwnership` and the outcomes in [`LaunchRecovery.swift`](../../Sources/PlatformMac/LaunchRecovery.swift), the recovery decisions in [`SystemDNSManager.swift`](../../Sources/PlatformMac/SystemDNSManager.swift), [`SystemProxyManager.swift`](../../Sources/PlatformMac/SystemProxyManager.swift) and [`LocationSettingsRecovery.swift`](../../Sources/PlatformMac/LocationSettingsRecovery.swift), the host state in [`RuntimeHost.swift`](../../Sources/ConduitRuntime/RuntimeHost.swift), the notice in [`SystemDNSRecoveryNotice.swift`](../../Sources/Conduit/Views/SystemDNSRecoveryNotice.swift), and the helper status in [`SettingsSupport.swift`](../../Sources/Conduit/Views/Settings/SettingsSupport.swift). Tests: [`SystemDNSManagerTests.swift`](../../Tests/ConduitTests/SystemDNSManagerTests.swift), [`AppStateHarnessTests.swift`](../../Tests/ConduitTests/AppStateHarnessTests.swift), [`RuntimeHostDNSHealthTests.swift`](../../Tests/ConduitTests/RuntimeHostDNSHealthTests.swift), [`RuntimeHostInteractiveTests.swift`](../../Tests/ConduitTests/RuntimeHostInteractiveTests.swift), [`HelperCallerRefusalPresentationTests.swift`](../../Tests/ConduitTests/HelperCallerRefusalPresentationTests.swift); scenarios [`LaunchRecoveryScenarios.swift`](../../Sources/pm-sim/LaunchRecoveryScenarios.swift) and [`RuntimeHostEffectsScenarios.swift`](../../Sources/pm-sim/RuntimeHostEffectsScenarios.swift).

Does not prove: behaviour on an installed build after a real crash with an installed helper that predates the witness.

## Open questions

- The owner's authorization for this fallback and its notice still has to be recorded before this record is accepted. 0041's acceptance names the notice as kept for the fallback.
