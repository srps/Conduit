# 0049: Keep DNS serving while a service still uses it, and fence Uninstall Helper

- Date: 2026-11-27
- Decision: proposed
- Implementation: implemented
- Validation: none
- Supersedes: none
- Superseded by: none

## Context

The owner's requirement: no Conduit path may leave the Mac with dead DNS. A user who has to restart the Mac to get DNS back is the worst outcome.

Observed in the code before this change:

- `SystemDNSManager.clear` stopped the helper's relay in a `defer`, so it stopped even when the location restore threw. The host then stopped the forwarder. A service whose restore failed was left on `127.0.0.1` with nothing answering. The **Manage system DNS** switch-off took the same path.
- A restore that succeeded stopped the relay without reading the settings back. The journal names only the services Conduit wrote, so a copy of a managed location made while it pointed at the relay was left on `127.0.0.1`.
- **Uninstall Helper** checked that system DNS was released, then removed the helper. Between that check and the removal, the app could still send a DNS Start, a Restart with a DNS companion, a reload, or a Settings save that turns **Manage system DNS** on. A reload started before the click was not waited for. With **Manage system DNS** on and DNS running, a location or network notification could point a newly eligible service at the relay during the password prompt.
- An unreadable first release check still sent the DNS Stop before refusing.
- `uninstall-helper.sh` read a failed `scutil` query as "no DNS", accepted output that carried a diagnostic beside a dictionary, and read a scalar `ServerAddresses` as no servers. Both uninstallers removed the helper's files after a failed `launchctl bootout` whenever `launchctl print` failed, for any reason.
- A reload that rebound the forwarder on another port left the relay forwarding to the old port.

A later release replaces this approach with a session-scoped key design. This record is that release's safety fix.

## Decision

- **A Stop that cannot restore keeps DNS serving.** When a non-terminal DNS Stop or a switch-off leaves a service on the loopback resolver, because the restore failed, because a service it had no record of still uses `127.0.0.1`, or because the settings cannot be read back, the relay and the forwarder keep serving. The host emits `platform.dns_restore_kept_serving` with the reason, keeps the journal for the retry, reports the Stop as `cleanupIncomplete`, and the app shows DNS as still running. The relay never outlives a stopped forwarder: both stay or both stop.
- **A kept Stop leaves DNS enabled in the saved settings**, so a relaunch serves DNS again. The Stop's own owed save carries it, through the intent owner: once the teardown kept DNS serving, and while the Stop is still DNS's latest admission, DNS's configured intent goes back to on and the one save the Stop makes writes the enable. It is the same conditional runtime-only write that saves a Stop's disable (decision [0015](0015-save-before-apply.md)), so a newer DNS Start or Stop keeps its own intent and an edit of the runtime file that lands first is kept. The Stop saves after its teardown, so the file holds the enable at every point of a kept Stop. The host emits `config.dns_stop_kept_enabled` with `save=saved`, `owed` or `superseded`.
- **A kept Stop forms no new dependency.** While DNS is fenced by a Stop and the forwarder still runs, no VPN or path reconcile and no location switch points another service at the relay. The health probe keeps the relay up for the services already on it.
- **The relay follows the forwarder.** A reload that rebinds the running forwarder on another port points the relay at the new port and re-arms the probe there (`dns.relay_retargeted`).
- **Uninstall Helper is fenced in the app.** From the click until the removal ends, the app refuses a Start or Restart of DNS or with a DNS companion and **Reload from Disk**, and defers a Settings save that has **Manage system DNS** on until the removal ends. Each one emits `helper.uninstall_fenced`. Before the last release check, the app waits for the Settings save, a reload already out, and the commands already sent. With **Manage system DNS** on and DNS running, it sends the restoring Stop even when the first check finds nothing, so no forwarder is left for a notification to apply. That check is the last step before the privileged removal. A deferred save that a refused uninstall's Stop cost its baseline is carried over a fresh read and saved.
- **An unreadable check refuses at once.** The app sends the restoring Stop only after a check that read the settings.
- **The uninstallers go on after a failed bootout only when launchd has no such job.** That is `launchctl print` exiting 113. A loaded job, or any other `print` failure, stops the removal before anything is deleted.
- **`uninstall-helper.sh` refuses what it cannot parse exactly.** A missing `DNS` key means no servers. A failed query, a diagnostic anywhere in the output, or a `ServerAddresses` that is not an array of addresses refuses, unless the user passes `--force`. The script has no fixture seam that could reach the removal steps; its test stubs `scutil`, `id`, `launchctl`, `rm` and `rmdir` on `PATH`. The refusal for a resolver on `127.0.0.1` stays. Both it and the app's refusal tell a user who runs their own resolver there to use `sudo ./uninstall-helper.sh --force`.

## Alternatives

- **Stop the relay and leave the restore to launch recovery.** Rejected: DNS stays dead until the next launch, which may be a restart.
- **Save the Stop's disable, then save the enable again once the teardown is kept.** Rejected: two writes leave a window in which an exit or a disk failure keeps the disable. The Stop already saves after its teardown, so its one save can carry the outcome.
- **Fence in the host, for every client.** Not chosen here: the host has no notion of an uninstall in flight, and the privileged removal runs in the app.

## Consequences

- A failed restore no longer kills DNS during a session or after a relaunch. The user sees DNS still running and an error that says to stop DNS again.
- The editor ledger drops its runtime baseline after a Stop that fails with `cleanupIncomplete`, as it does for any failed own DNS Stop. The next save is refused until a reload, except the save Uninstall Helper deferred, which is carried over a fresh read.
- A Settings save with **Manage system DNS** on waits until the uninstall ends.
- With **Manage system DNS** on, Uninstall Helper stops DNS and saves it disabled, as **Restore DNS Settings** does.
- A user whose own resolver is on `127.0.0.1` cannot stop DNS while **Manage system DNS** is on: the read-back counts that service as Conduit's, so the Stop keeps DNS serving. They uninstall with `--force`.

Known limits, left for the session-scoped key redesign because it removes the cause of each:

- A reload whose forwarder cannot bind its new port, because another process holds it, leaves the forwarder failed and the relay forwarding to the port the kernel closed. The kernel closes the old listener before it binds the new one.
- A quit (terminal teardown) still stops the relay when the restore fails, so the services left on `127.0.0.1` have no resolver until a relaunch. After a crash, launch recovery can also stop an orphan relay whose restore then fails. A planned fail-open fallback in the helper's `:53` relay covers this.
- A kept switch-off keeps **Manage system DNS** off in the saved settings, because that is the user's own Settings save. A relaunch runs the forwarder without pointing anything at the relay, and launch recovery restores the records.
- A verified restore to a user's own `127.0.0.1` resolver is still counted as Conduit's residue.

Out of scope:

- The networksetup restore path, which only tests and pm-sim use, still stops the relay before it restores.
- Commands from clients outside the app, such as `pmctl`, and the standalone script are not fenced during Uninstall Helper.
- The app cannot check again after the administrator prompt: the prompt and the removal run in one `osascript` call.

## Invariants and verification

- After a non-terminal Stop, either system DNS was restored and nothing is on `127.0.0.1`, or the relay and the forwarder both still serve. `DaemonRuntimeHostTests.testADNSStopWhoseRestoreFailsKeepsTheRelayAndTheForwarderServing`, `testADNSStopKeepsServingAServiceItHasNoRecordOf`, `testASystemDNSSwitchOffWhoseRestoreFailsKeepsTheRelay`, `SystemDNSManagerTests.testAFailedLocationRestoreKeepsTheRelayOnlyWhenAskedAndWhileAServiceUsesIt`, `testARestoreThatLeavesAnUnrecordedServiceOnTheRelayKeepsIt`, and the `runtime-host-effects` pm-sim exercise of a kept Stop and its retry.
- A kept Stop leaves DNS enabled on disk, whatever an exit, a disk failure or a newer edit does, and a newer Stop that restores saves the disable. `DaemonRuntimeHostTests.testAKeptStopLeavesDNSEnabledInTheSavedSettings`, `testAKeptStopUnderAFailingDiskKeepsDNSEnabledForTheNextWrite`, `testAnEditWhileAKeptStopSavesWins`, `RuntimeModuleIntentTests.testAKeptStopOwesTheEnableOnlyWhileItIsDNSsLatestAdmission`, and the pm-sim exercise.
- A kept Stop points no new service at the relay. `DaemonRuntimeHostTests.testAKeptStopPointsNoNewServiceAtTheRelay`.
- The relay targets the forwarder's bound port after a reload. `DaemonRuntimeHostTests.testAReloadThatMovesTheForwarderPointsTheRelayAtItsNewPort` and the pm-sim exercise.
- A quit still stops both. `DaemonRuntimeHostTests.testTheQuitStopsTheRelayEvenWhenTheRestoreFails`.
- No service points at the relay when the helper is removed, or after. `AppStateHarnessTests.testNothingTheAppSendsDuringTheRemovalPointsAServiceAtTheRelay`, `testUninstallJoinsAReloadStartedBeforeTheClick`, `testAServiceThatBecomesEligibleDuringTheRemovalIsNotPointedAtTheRelay`, `testHelperUninstallIsRefusedWhileAServiceStillUsesTheRelay`, `testAnUnreadableReleaseCheckRefusesTheUninstallWithoutStoppingDNS`. A save the fence deferred lands after a refused removal: `testASaveHeldByARefusedUninstallIsSaved`.
- A removal deletes nothing unless launchd confirms the job is gone, and the script refuses output it cannot parse. `HelperContractTests` and `scripts/test-uninstall-helper-args.sh`.

The design is disproved by a Stop that leaves a service on `127.0.0.1` with no relay, a kept Stop that saves DNS disabled, or a removal that runs while a service points at the relay.

## Implementation evidence

- Keep-serving restore and read-back: [`SystemDNSManager.swift`](../../Sources/PlatformMac/SystemDNSManager.swift), [`RuntimeHostLifecycle.swift`](../../Sources/ConduitRuntime/RuntimeHostLifecycle.swift), [`RuntimeHostSystemDNSRelease.swift`](../../Sources/ConduitRuntime/RuntimeHostSystemDNSRelease.swift), [`RuntimeHost.swift`](../../Sources/ConduitRuntime/RuntimeHost.swift), [`RuntimeHostControlOwner.swift`](../../Sources/ConduitRuntime/RuntimeHostControlOwner.swift); pm-sim in [`RuntimeHostEffectsScenarios.swift`](../../Sources/pm-sim/RuntimeHostEffectsScenarios.swift).
- Kept intent: [`RuntimeModuleIntent.swift`](../../Sources/ConduitRuntime/RuntimeModuleIntent.swift), [`RuntimeConfigurationWorkflow.swift`](../../Sources/ConduitRuntime/RuntimeConfigurationWorkflow.swift), tested in [`DaemonRuntimeHostTests.swift`](../../Tests/ConduitTests/DaemonRuntimeHostTests.swift) and [`RuntimeModuleIntentTests.swift`](../../Tests/ConduitTests/RuntimeModuleIntentTests.swift).
- Fence and early refusal: [`AppState.swift`](../../Sources/Conduit/App/AppState.swift), tested in [`AppStateHarnessTests.swift`](../../Tests/ConduitTests/AppStateHarnessTests.swift).
- Uninstallers: [`HelperPrivilegeClient.swift`](../../Sources/PlatformMac/HelperPrivilegeClient.swift), [`uninstall-helper.sh`](../../uninstall-helper.sh), [`test-uninstall-helper-args.sh`](../../scripts/test-uninstall-helper-args.sh).

Does not prove: behaviour on an installed build with a real helper, or a real `scutil` failure on a real machine.

## Open questions

None.
