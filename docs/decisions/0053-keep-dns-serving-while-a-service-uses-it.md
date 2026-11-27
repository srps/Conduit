# 0053: Keep DNS serving while a service still uses it, and fence Uninstall Helper

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
- `uninstall-helper.sh` read a failed `scutil` query as "no DNS", accepted output that carried a diagnostic beside or inside a dictionary, and read a scalar `ServerAddresses` as no servers. Both uninstallers removed the helper's files after a failed `launchctl bootout` whenever `launchctl print` failed, for any reason.

A later release replaces this approach with a helper-held temporary DNS key. This record is that release's safety fix.

## Decision

- **A Stop that cannot restore keeps DNS serving.** When a non-terminal DNS Stop or a switch-off leaves a service on the loopback resolver, because the restore failed, because a service it had no record of still uses `127.0.0.1`, or because the settings cannot be read back, the relay and the forwarder keep serving. The host emits `platform.dns_restore_kept_serving` with the reason, keeps the journal for the retry, reports the Stop as `cleanupIncomplete`, and the app shows DNS as still running. The relay never outlives a stopped forwarder: both stay or both stop.
- **A kept Stop leaves DNS enabled in the saved settings**, so a relaunch serves DNS again. The Stop's own owed save carries it, through the intent owner: once the teardown kept DNS serving, and while the Stop is still DNS's latest admission, DNS's configured intent goes back to on and the one save the Stop makes writes the enable. It is the same conditional runtime-only write that saves a Stop's disable (decision [0015](0015-save-before-apply.md)), so a newer DNS Start or Stop keeps its own intent and an edit of the runtime file that lands first is kept. While a Stop's save is owed, DNS's configured intent is the bit it owes: any verified runtime write of that bit ends the obligation, and a write of the other bit, from a save that staged the disable before the teardown kept DNS serving, changes neither. The host emits `config.dns_stop_kept_enabled` with `save=saved`, `owed` or `superseded`.
- **A kept Stop forms no new dependency.** While DNS is fenced by a Stop and the forwarder still runs, no VPN or path reconcile and no location switch points another service at the relay. The health probe keeps the relay up for the services already on it.
- **Uninstall Helper is fenced in the app.** From the click until the removal ends, the app refuses a Start or Restart of DNS or with a DNS companion, **Reload from Disk**, and a Settings save. Each one emits `helper.uninstall_fenced`. A refused save stays in the editor, and the message says it can be saved again once the uninstall ends. Before the last release check, the app waits for the Settings save, a reload already out, and the commands already sent.
- **The uninstall decides from what the host applies.** The release check reports whether the host applies system DNS: **Manage system DNS** on in what it applied, the forwarder running, and no Stop fencing DNS. When it does, the app sends the restoring Stop even when the first check finds nothing, so no forwarder is left for a notification to apply. The check after that Stop must find system DNS released and no longer applied; a Stop that never ran, or ran and was undone, refuses the removal with `reason=dns_still_applied`. That check is the last step before the privileged removal. An unsaved **Manage system DNS** checkbox stops nothing.
- **An unreadable check refuses at once.** The app sends the restoring Stop only after a check that read the settings.
- **The uninstallers go on after a failed bootout only when launchd has no such job.** That is `launchctl print` exiting 113. A loaded job, or any other `print` failure, stops the removal before anything is deleted.
- **`uninstall-helper.sh` refuses what it cannot parse exactly.** A missing `DNS` key means no servers. A failed query, a diagnostic anywhere in the output, a dictionary line that is not an entry at its level or a brace, or a `ServerAddresses` that is not an array of addresses refuses, unless the user passes `--force`. The script has no fixture seam that could reach the removal steps; its test stubs `scutil`, `id`, `launchctl`, `rm` and `rmdir` on `PATH`. The refusal for a resolver on `127.0.0.1` stays. Both it and the app's refusal tell a user who runs their own resolver there to use `sudo ./uninstall-helper.sh --force`.

## Alternatives

- **Stop the relay and leave the restore to launch recovery.** Rejected: DNS stays dead until the next launch, which may be a restart.
- **Save the Stop's disable, then save the enable again once the teardown is kept.** Rejected: two writes leave a window in which an exit or a disk failure keeps the disable. The Stop already saves after its teardown, so its one save can carry the outcome.
- **Fence in the host, for every client.** Not chosen here: the host has no notion of an uninstall in flight, and the privileged removal runs in the app.
- **Point the relay at the forwarder's new port after a reload.** Tried and reverted: it needs the relay's target tracked apart from the journal, for a relay kept for a service the journal has no record of, and a target generation checked against health readings delivered late. Each is more state in the app-level design the redesign replaces, so a port change is a known limit.
- **Defer a Settings save made during the uninstall, and carry it over a fresh read when a refused restore cost the editor its baseline.** Tried and replaced with a refusal: putting the whole draft back over the fresh baselines reverted changes the host had already adopted and could lose an edit made during the read. Carrying only the edited fields would need a field-level merge with conflicts.
- **Decide the protective Stop from the draft and the saved settings.** Rejected: an unsaved checkbox stopped a forwarder that does not need the helper, and a kept switch-off leaves the saved settings off while the host still applies system DNS.
- **Refuse unless the protective Stop's outcome confirms it.** Not chosen: the host's own report at the last check covers a Stop that never ran and one undone after it ran, with no outcome to classify.
- **Give a kept Stop's enable its own intent revision, so a save staged before it fails its claim.** Not chosen: the revision is the host's one lifecycle counter, which reloads, settle joins and resumed Stops also compare, so advancing it outside an admission changes them too. The owed bit already orders the late write.
- **A kept Stop owes nothing, because its own disable was never written.** Rejected: a shared save admitted after the Stop stages the disable while the teardown runs, so the file can hold it.

## Consequences

- A failed restore no longer kills DNS during a session or after a relaunch. The user sees DNS still running and an error that says to stop DNS again.
- The editor ledger drops its runtime baseline after a Stop that fails with `cleanupIncomplete`, as it does for any failed own DNS Stop. The next save is refused until a reload.
- A Settings save is refused while Uninstall Helper runs. The draft stays, and saves once the uninstall ends.
- While the host applies **Manage system DNS**, Uninstall Helper stops DNS and saves it disabled, as **Restore DNS Settings** does.
- A user whose own resolver is on `127.0.0.1` cannot stop DNS while **Manage system DNS** is on: the read-back counts that service as Conduit's, so the Stop keeps DNS serving. They uninstall with `--force`.

Known limits, left for the helper-held temporary DNS key redesign because it removes the cause of each:

- A forwarder port change while DNS is managed can orphan the relay. A reload that rebinds the forwarder on another port leaves the helper's relay forwarding to the old port, where nothing answers, and its health probe restarts the relay at that port. A rebind that fails because another process holds the new port does the same. Stopping and starting DNS points the relay at the new port.
- A save that staged the disable while a Stop's teardown ran can still write it after the teardown kept DNS serving, and the Stop's own save then finds the store busy. The runtime file holds the disable until the next runtime write, which stages the enable. A relaunch before that write runs without the forwarder; launch recovery restores the journaled services, and a service it has no record of stays on `127.0.0.1`.
- A quit (terminal teardown) still stops the relay when the restore fails, so the services left on `127.0.0.1` have no resolver until a relaunch. After a crash, launch recovery can also stop an orphan relay whose restore then fails. A planned fail-open fallback in the helper's `:53` relay covers this.
- A kept switch-off keeps **Manage system DNS** off in the saved settings, because that is the user's own Settings save. A relaunch runs the forwarder without pointing anything at the relay, and launch recovery restores the records.
- A verified restore to a user's own `127.0.0.1` resolver is still counted as Conduit's residue.

Out of scope:

- The networksetup restore path, which only tests and pm-sim use, still stops the relay before it restores.
- Commands from clients outside the app, such as `pmctl`, and the standalone script are not fenced during Uninstall Helper.
- The app cannot check again after the administrator prompt: the prompt and the removal run in one `osascript` call.

## Invariants and verification

- After a non-terminal Stop, either system DNS was restored and nothing is on `127.0.0.1`, or the relay and the forwarder both still serve. `DaemonRuntimeHostTests.testADNSStopWhoseRestoreFailsKeepsTheRelayAndTheForwarderServing`, `testADNSStopKeepsServingAServiceItHasNoRecordOf`, `testASystemDNSSwitchOffWhoseRestoreFailsKeepsTheRelay`, `SystemDNSManagerTests.testAFailedLocationRestoreKeepsTheRelayOnlyWhenAskedAndWhileAServiceUsesIt`, `testARestoreThatLeavesAnUnrecordedServiceOnTheRelayKeepsIt`, and the `runtime-host-effects` pm-sim exercise of a kept Stop and its retry.
- A kept Stop leaves DNS enabled on disk, whatever an exit, a disk failure or a newer edit does, and a newer Stop that restores saves the disable. `DaemonRuntimeHostTests.testAKeptStopLeavesDNSEnabledInTheSavedSettings`, `testAKeptStopUnderAFailingDiskKeepsDNSEnabledForTheNextWrite`, `testAnEditWhileAKeptStopSavesWins`, `RuntimeModuleIntentTests.testAKeptStopOwesTheEnableOnlyWhileItIsDNSsLatestAdmission`, and the pm-sim exercise. A save that staged the disable before the teardown kept DNS serving cannot undo the kept enable, and any write of the enable ends the obligation: `RuntimeModuleIntentTests.testASaveStagedBeforeAKeptStopDoesNotUndoTheKeptEnable` and `testAnyVerifiedWriteOfTheKeptEnableEndsTheObligation`.
- A kept Stop points no new service at the relay. `DaemonRuntimeHostTests.testAKeptStopPointsNoNewServiceAtTheRelay`.
- A quit still stops both. `DaemonRuntimeHostTests.testTheQuitStopsTheRelayEvenWhenTheRestoreFails`.
- No service points at the relay when the helper is removed, or after. `AppStateHarnessTests.testNothingTheAppSendsDuringTheRemovalPointsAServiceAtTheRelay`, `testUninstallJoinsAReloadStartedBeforeTheClick`, `testAServiceThatBecomesEligibleDuringTheRemovalIsNotPointedAtTheRelay`, `testHelperUninstallIsRefusedWhileAServiceStillUsesTheRelay`, `testAnUnreadableReleaseCheckRefusesTheUninstallWithoutStoppingDNS`. The release check reports whether the host applies system DNS, and stops reporting it once a Stop fences DNS: `DaemonRuntimeHostTests.testTheReleaseCheckSaysWhetherTheHostStillAppliesSystemDNS`. An unsaved checkbox stops nothing: `testAnUnsavedManageSystemDNSCheckboxDoesNotStopTheForwarder`. A Settings save during the uninstall is refused and saves after it: `testASettingsSaveDuringTheUninstallIsRefusedAndSavesOnceItEnds`.
- A removal deletes nothing unless launchd confirms the job is gone, and the script refuses output it cannot parse, an indented diagnostic inside a dictionary included. `HelperContractTests` and `scripts/test-uninstall-helper-args.sh`.

The design is disproved by a Stop that leaves a service on `127.0.0.1` with no relay, a kept Stop that saves DNS disabled, or a removal that runs while a service points at the relay.

## Implementation evidence

- Keep-serving restore and read-back: [`SystemDNSManager.swift`](../../Sources/PlatformMac/SystemDNSManager.swift), [`RuntimeHostLifecycle.swift`](../../Sources/ConduitRuntime/RuntimeHostLifecycle.swift), [`RuntimeHostSystemDNSRelease.swift`](../../Sources/ConduitRuntime/RuntimeHostSystemDNSRelease.swift), [`RuntimeHost.swift`](../../Sources/ConduitRuntime/RuntimeHost.swift), [`RuntimeHostControlOwner.swift`](../../Sources/ConduitRuntime/RuntimeHostControlOwner.swift); pm-sim in [`RuntimeHostEffectsScenarios.swift`](../../Sources/pm-sim/RuntimeHostEffectsScenarios.swift).
- Kept intent: [`RuntimeModuleIntent.swift`](../../Sources/ConduitRuntime/RuntimeModuleIntent.swift), [`RuntimeConfigurationWorkflow.swift`](../../Sources/ConduitRuntime/RuntimeConfigurationWorkflow.swift), tested in [`DaemonRuntimeHostTests.swift`](../../Tests/ConduitTests/DaemonRuntimeHostTests.swift) and [`RuntimeModuleIntentTests.swift`](../../Tests/ConduitTests/RuntimeModuleIntentTests.swift).
- Fence and early refusal: [`AppState.swift`](../../Sources/Conduit/App/AppState.swift), tested in [`AppStateHarnessTests.swift`](../../Tests/ConduitTests/AppStateHarnessTests.swift).
- Uninstallers: [`HelperPrivilegeClient.swift`](../../Sources/PlatformMac/HelperPrivilegeClient.swift), [`uninstall-helper.sh`](../../uninstall-helper.sh), [`test-uninstall-helper-args.sh`](../../scripts/test-uninstall-helper-args.sh).

Does not prove: behaviour on an installed build with a real helper, or a real `scutil` failure on a real machine. The app's refusal of a last check that still finds DNS applied has no app-level test: in-process, a protective Stop is always admitted, and making one fail to run needs a test-only seam in the app harness. The host's report it rests on is tested.

The stricter dictionary check accepted every dictionary the script reads on one real Mac (41 location, service, DNS, interface, IPv4 and proxy dictionaries), read with `scutil --prefs` and no change, on 2026-11-27.

## Open questions

None.
