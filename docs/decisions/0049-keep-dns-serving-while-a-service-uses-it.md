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
- **Uninstall Helper** checked that system DNS was released, then removed the helper. Between that check and the removal, the app could still send a DNS Start, a Restart with a DNS companion, a reload, or a Settings save that turns **Manage system DNS** on. Any of them could point a service back at the relay the removal was about to take away.
- An unreadable first release check still sent the DNS Stop before refusing.
- `uninstall-helper.sh` read a failed `scutil` query as "no DNS", and both uninstallers removed the helper's files after a failed `launchctl bootout` whenever `launchctl print` failed, for any reason.

## Decision

- **A Stop that cannot restore keeps DNS serving.** When a non-terminal DNS Stop or a switch-off cannot restore system DNS, and a service still uses the loopback resolver (or the settings cannot be read to prove otherwise), the relay and the forwarder keep serving. The host emits `platform.dns_restore_kept_serving` with the reason, keeps the journal for the retry, reports the Stop as `cleanupIncomplete`, and the app shows DNS as still running. The relay never outlives a stopped forwarder: both stay or both stop.
- **The Stop's durable intent is unchanged.** The Stop still saves DNS as disabled before it applies (decision [0015](0015-save-before-apply.md)). A launch after a kept Stop does not start DNS; launch recovery restores the records it finds.
- **Uninstall Helper is fenced in the app.** From the click until the removal ends, the app refuses a Start or Restart of DNS or with a DNS companion and **Reload from Disk**, and defers a Settings save that has **Manage system DNS** on until the removal ends. Each one emits `helper.uninstall_fenced`. Before the last release check, the app waits for the Settings save and the commands already sent. That check is the last step before the privileged removal.
- **An unreadable check refuses at once.** The app sends the restoring Stop only after a check that read the settings found residue.
- **The uninstallers go on after a failed bootout only when launchd has no such job.** That is `launchctl print` exiting 113. A loaded job, or any other `print` failure, stops the removal before anything is deleted.
- **`uninstall-helper.sh` refuses when it cannot read.** A missing `DNS` key means no servers. A failed query or unexpected output refuses, unless the user passes `--force`. The script has no fixture seam that could reach the removal steps; its test stubs `scutil`, `id`, `launchctl`, `rm` and `rmdir` on `PATH`. The refusal for a resolver on `127.0.0.1` stays. Both it and the app's refusal tell a user who runs their own resolver there to use `sudo ./uninstall-helper.sh --force`.

## Alternatives

- **Stop the relay and leave the restore to launch recovery.** Rejected: DNS stays dead until the next launch, which may be a restart.
- **Mark the Stop as not saved, so a later launch starts DNS again.** Rejected for now: it changes decision 0015's Stop exception. Keeping the forwarder serving covers the running session, and launch recovery covers the next one.
- **Fence in the host, for every client.** Not chosen here: the host has no notion of an uninstall in flight, and the privileged removal runs in the app.

## Consequences

- A failed restore no longer kills DNS during a session. The user sees DNS still running and an error that says to stop DNS again.
- The editor ledger drops its runtime baseline after a Stop that fails with `cleanupIncomplete`, as it does for any failed own DNS Stop. The next save rebuilds it.
- A Settings save with **Manage system DNS** on waits until the uninstall ends.

## Invariants and verification

- After a non-terminal Stop, either system DNS was restored, or the relay and the forwarder both still serve. `DaemonRuntimeHostTests.testADNSStopWhoseRestoreFailsKeepsTheRelayAndTheForwarderServing`, `testASystemDNSSwitchOffWhoseRestoreFailsKeepsTheRelay`, `SystemDNSManagerTests.testAFailedLocationRestoreKeepsTheRelayOnlyWhenAskedAndWhileAServiceUsesIt`, and the `runtime-host-effects` pm-sim exercise of a kept Stop and its retry.
- A quit still stops both. `DaemonRuntimeHostTests.testTheQuitStopsTheRelayEvenWhenTheRestoreFails`.
- No service points at the relay when the helper is removed. `AppStateHarnessTests.testNothingTheAppSendsDuringTheRemovalPointsAServiceAtTheRelay`, `testHelperUninstallIsRefusedWhileAServiceStillUsesTheRelay`, `testAnUnreadableReleaseCheckRefusesTheUninstallWithoutStoppingDNS`.
- A removal deletes nothing unless launchd confirms the job is gone. `HelperContractTests` and `scripts/test-uninstall-helper-args.sh`.

The design is disproved by a Stop that leaves a service on `127.0.0.1` with no relay, or a removal that runs while a service points at the relay.

## Implementation evidence

- Keep-serving restore: [`SystemDNSManager.swift`](../../Sources/PlatformMac/SystemDNSManager.swift), [`RuntimeHostLifecycle.swift`](../../Sources/ConduitRuntime/RuntimeHostLifecycle.swift), [`RuntimeHostSystemDNSRelease.swift`](../../Sources/ConduitRuntime/RuntimeHostSystemDNSRelease.swift), [`RuntimeHost.swift`](../../Sources/ConduitRuntime/RuntimeHost.swift), [`RuntimeHostControlOwner.swift`](../../Sources/ConduitRuntime/RuntimeHostControlOwner.swift); pm-sim in [`RuntimeHostEffectsScenarios.swift`](../../Sources/pm-sim/RuntimeHostEffectsScenarios.swift).
- Fence and early refusal: [`AppState.swift`](../../Sources/Conduit/App/AppState.swift), tested in [`AppStateHarnessTests.swift`](../../Tests/ConduitTests/AppStateHarnessTests.swift).
- Uninstallers: [`HelperPrivilegeClient.swift`](../../Sources/PlatformMac/HelperPrivilegeClient.swift), [`uninstall-helper.sh`](../../uninstall-helper.sh), [`test-uninstall-helper-args.sh`](../../scripts/test-uninstall-helper-args.sh).

Does not prove: behaviour on an installed build with a real helper, or a real `scutil` failure on a real machine.

Out of scope:

- A terminal teardown (quit) still stops the relay when the restore fails. A planned follow-up, a fail-open fallback in the helper's `:53` relay, covers that case.
- The networksetup restore path, which only tests and pm-sim use, still stops the relay before it restores.
- Commands from clients outside the app, such as `pmctl`, are not fenced during Uninstall Helper.
- The app cannot check again after the administrator prompt: the prompt and the removal run in one `osascript` call.

## Open questions

- Should a kept Stop leave DNS enabled in the saved intent, so the next launch starts DNS again instead of relying on launch recovery?
