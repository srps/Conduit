# AppState test migration checklist

Pre-cut review at product checkpoint `3ed13fa`, 2026-10-27. This is a one-use
implementation checklist, not permission to remove tests or a completed coverage
claim. Subscription-backed Claude reviewed 15 named twin assertions; other twin
candidates must be compared before deletion. A write-first item means coverage
was not established by this review and must be checked or added before the cut.
The parent checked all 132 non-keep test names occur below and generated the
remaining 46 keep-only identities from source. The disposition tally totals 178.
Current execution remains in [ROADMAP](../ROADMAP.md).

**What each label means**
- **T(V):** the named host test exists and I compared its assertions with the app test.
- **T(N):** the host test matches by name or doc comment only. Compare the assertions before deleting the app test.
- **C:** keep the coverage, repointed as a thin test of the app over its client.
- **W:** no host test covers this. Write the host test before the single cut.
- **O:** obsolete, with the exact reason given.
- **K:** the test doesn't construct AppState and stays as it is.
- Short names: `D` = `DaemonRuntimeHostTests`, `CO` = `RuntimeHostControlOwnerTests`, `IN` = `RuntimeHostInteractiveTests`, `PF` = `RuntimeHostPreflightTests`.

**One caveat applies everywhere.** The `D` tests start and stop through the whole-host shortcut (`startRuntime`/`stopRuntime`). That shortcut runs the same owner and effect path as a module Start, so it's an acceptable twin for effect-level invariants. After the switch, though, the app sends per-module commands. Wherever the module scope changes the outcome, I marked the test W.

## AppStateHarnessTests: 111 tests

**Launch and load failure (7)**
- C: `testDeletedConfigInEstablishedStateCannotBecomeFirstRunDefaults`; `testCorruptConfigurationCannotStartOrOverwriteTheFile`; `testMalformedPlatformSidecarBlocksActivationAndSaving`; `testMalformedPreferencesSidecarBlocksActivationAndSaving`. The client test: a refused load means no client and no controls, the banner shows, and the bytes are kept.
  - The loader refusal itself is already pinned by `ConfigSidecarBoundaryTests.testARefusedSidecarKeepsItsBytesThroughEveryLoad` and `ConfigurationFileGateTests.testAMissingFileIsDefaultsWhenAllowedAndNamedWhenNot`.
- T(V) + C: `testCorruptConfigStillRestoresJournaledProxyOnLaunch` → `D.testABrokenConfigStillRestoresTheJournaledProxyBeforeExiting` (same recovery events, bypass, idle journal, bytes kept). The client test adds that the app composition calls `recoverWithoutConfiguration`.
- T(V): `testAJournalFromANewerConduitIsReportedAndKeptAtLaunch` → `D`, same name.
- T(N): `testLaunchRestoresTheProxyACrashedRunLeftBehind` → `D`, same name.

**App-log identity and lease (2): both C, keep.** `testAnAppLogAliasOfTheConfigIsRefusedThroughTheCompositionEventLog`; `testAnAppLogAliasOfTheWriterLeaseIsRefusedAndTheLeaseKeepsItsAuthority`. The app log stays app-owned; the host tests cover only the events and snapshot sinks. The lease-fingerprint and second-writer-busy assertions must survive.

**Credentials and listener host (3)**
- T(N) + W: `testProxyStartReadsASavedPasswordOnce` → `D.testRuntimeStartReadsASavedPasswordOnce`, which goes through the whole-host Start. Add a host test that warms the cache through the `.start(.proxy)` command.
- W: `testProxyStartDoesNotReadWithoutASavedPassword`, which asserts zero reads with no saved password. No host test does.
- W: `testLocalhostIsPinnedInListenersAndAdvertisedClientSettings`, which checks bindings, Wi-Fi and launchd environment all show 127.0.0.1.

**Observers (13)**
- T(V): `testLocationSwitchWithoutVPNOrPathChangeRestoresInactiveStateAndPreservesExternalEdits`; `testLatePACRewriteRepairsOnSettingsNotificationWithoutAnotherVPNOrPathReport`; `testContendedRepairRetriesWhenTheWindowReopensWithoutAnotherNotification`; `testVPNReconcileRetriesDNSInSameLocationAfterInitiallyDisabledService` (all `D`, same names). Also `testVPNRewriteOfPACInSameLocationIsRepairedWithoutRestartingProxy` → `D.testVPNReportRepairsFailedPACApplicationAndLaterRewriteWithoutRestartingRuntime`.
- T(N): `testABurstOfVPNReportsEndsOnTheLastOneAndDropsNone`; `testVPNInterfaceNameIsTheOneDeliveredWithTheState`; `testAVPNDropWhileTheStartAppliesLeavesNoEntryFile` (all `D`, same names).
- W: `testHelperBecomingAvailableRepairsFailedPACApplicationWithoutRestartingProxy`. Its host lookalike repairs through a VPN report, and `PF` only observes the environment repair. Needed: a conclusive preflight repairs a refused PAC location write with bindings unchanged and a `platform.location_reconcile` event.
- W, module-scoped Stop variants:
  - `testLocationNotificationDuringDNSStopCannotRepinStoppedListener`;
  - `testVPNNotificationDuringProxyStopCannotRepinStoppedListener`;
  - `testSettingsNotificationDuringProxyStopCannotRepinStoppedListener`.
  
  The host versions stop the whole runtime while held on `stopDNSRelay`. The app versions hold `.stop(.proxy)` on `launchctl unsetenv` with the environment switch on, or hold `.stop(.dns)`. Keep their journal assertions and the cap of at most two `settings_observed` under 1,000 notifications.
- W: `testEntryFilesFollowTheVPN`. Proxy running with resolvers managed: a VPN drop removes the entry file, a reconnect restores it. The existing coverage is unit-level only.

**Helper status (5)**
- T(V) + C: `testABusyHelperKeepsItsVerdictAndIsReadAgain` and `testAReinstalledHelperThatIsBusyDoesNotKeepTheOldVerdict` → `PF.testABusyReadKeepsTheHeldVerdictAndOnlyAConclusiveInstallRepairs`. The client test: one re-read on `helperReadBusy`, install sends `helperReplaced: true`, and the repair action is hidden.
- C: `testABusyHelperAtLaunchShowsBusyWithoutARepair`; `testHelperUninstallRunsOffTheMainActorAndReportsFailure`; `testHelperInstallReportsTheCallerPolicyItLeft`. Install and uninstall stay in the app.

**Saves and editor (34)**
- C (draft, debounce, commit, banner, quit producer and app-side login-item behaviour):
  - `testAnEditMadeAfterASaveSurvivesTheSavesPass` (a receipt rebases only an unchanged draft); `testASettingsEditSavesAndReconcilesWhenEditsPause`; `testAPauseOnANonBlockingProblemStillSaves`; `testAPauseOnAnInvalidEditWaitsForTheSectionToClose`;
  - `testAnOverlimitBypassCountIsRefusedAndKeepsTheFile` (the refusal moves to the client's mapping step, which reports `resourceLimit` before anything is sent, so the event assertion changes); `testAnImportOfANewerFileLeavesTheEditorUnchanged`; `testAnInvalidSavedConfigDoesNotHoldBackAPlatformEdit`; `testLeavingASectionSavesAWaitingEditAtOnce`;
  - `testQuittingRetriesALoginItemRegistrationThatFailed`; `testQuittingWithAnUnsavedLoginItemFlipRegistersIt`; `testQuittingWithAPartialWriteStillRegistersTheLoginItem`; `testAFailedWriteKeepsTheEditUnsaved`;
  - `testTypingAPortDoesNotRebindUntilTheSectionCloses`; `testReturnCommitsAHeldPortEdit`; `testFixingAnInvalidEditClearsItsConfigurationProblem`; `testFixingAnInvalidEditLeavesALaterErrorShown`; `testApplyCommitsTheTextAFieldWritesWhenEditingEnds`; `testTypingBackToTheCommittedPortRebindsNothing`; `testAListenerSwitchWaitsForApply`; `testAnEditThatReplacesNoListenerReachesTheRuntimeOnItsPause`;
  - `testQuittingDiscardsAHeldEditThatWouldBlockAStart`; `testQuittingDiscardsAnInvalidEditWhoseCommitFailedToWrite`.
- C + T(N):
  - `testASaveThatOnlyRespellsThePACURLReachesTheRuntime` → `D.testAReloadThatOnlyRespellsThePACURLAppliesAndFetchesTheNewBytes` and `RuntimeReconcilerTests.testASaveThatOnlyRespellsTheInputPushesTheNewBytes`. Reload and update share `adoptHostView` plus `reconciler.reconcile`.
  - `testQuittingPersistsAWaitingEditWithoutReconcilingIt` and `testQuittingWritesAHeldPortEditWithoutBindingIt` → `CO.testTheClientQuitFencesFirstThenFlushesOnceTheEarlierUpdateReleasesItsInput`, `CO.testTheClientQuitRefusesANonSaveOnlyFinalSaveLocally`.
  - `testStartingWithAHeldPortEditBindsTheCommittedPort` → `CO.testASavedDNSStartRunsTheSavedPairAndItsReceiptRebasesOnlyTheDraftAtItsPrior` (decision 0037: a saved Start uses the saved pair).
- T(N) + O:
  - `testStartingTheDNSForwarderAbsorbsItsOwnSave`. The app no longer writes `dnsForwarderEnabled`; the saved DNS Start writes that intent on the host (twin: the `CO` saved-DNS-Start test above). Before deleting, check the twin asserts there's no `config.dns_restart`.
  - `testTheDNSLifecycleFlagReachesTheRuntimeOverAQueuedPass`. The race it guarded (the app's in-memory flag against its own queued pass) no longer exists. The intent is written only by the host store (twins: `CO.testASaveMergesTheDNSStopsDisableOverTheDraftsEnable`, `RuntimeModuleIntentTests`).
- O: `testALifecycleSaveDoesNotCarryAStartBlockingEdit`. The client no longer saves on Start/Stop; saved Start and Stop carry no draft values (decision 0037), so a held draft can't ride along by construction.
- T(N) + O (the section-close trigger): `testLeavingASectionRetriesAnActionThatDidNotLand`; `testLeavingASectionDuringAPassRetriesWhenItFails`; `testLeavingASectionWithANewerEditDuringAPassStillRetries`; `testThePostDrainCheckRetriesTheCloseAndLeavesALaterEdit`. The client can't see reconciler lag; retrying a failed switch is the host's job (`D.testASystemProxySwitchThatFailsToApplyOnReloadIsRetried`, `ConfigReapplyRetryTests`). The last one's "a later edit stays under its own debounce" part → C.
- W: `testCommittingAListenHostLeavesTheDNSForwarderOnLoopback`. A `localHost` update keeps DNS on loopback and keeps the relay target.

**Reapply and drift (15)**
- T(N), via the reload twins:
  - `testABypassEditReachesTheAdvertisedSurfacesInManualMode`; `testABypassEditInPACModeLeavesTheSystemProxyAlone`; `testALocalPACPortEditRepointsTheSystemProxy`; `testABypassEditReappliesOffTheMainActor`;
  - `testAFailedSystemProxyReapplyIsReportedAndRetried`; `testASystemProxySwitchThatFailsToApplyIsRetried`; `testAFailedSystemProxyModeChangeIsReportedAsOne`; `testAPartialEnvironmentReapplyIsReportedAndRetried`; `testAStopAfterAFailedReapplyAbandonsTheRetry` (each → the `D` "…Reload…" counterpart);
  - `testAWipedEnvironmentIsRepairedOnTheNextSettingsNotification` → `D`, same name;
  - `testARetryThatKeepsFailingIsAbandonedAfterItsAttempts` → `ConfigReapplyRetryTests.testARetryStopsAfterItsAttempts`.
- W:
  - `testAPartialEnvironmentReapplyRecoversOnTheRetry`;
  - `testThePeriodicTickRepairsAWipeNoNotificationReports` (no host test sets `environmentDriftInterval`);
  - `testTheDriftPassLeavesTheEnvironmentAloneWhenTheSwitchIsOffOrTheProxyStopped`;
  - `testADriftPassRepairsToTheAppliedConfigNotAHeldDraft`. The draft framing is obsolete, but the invariant remains: drift repairs to the applied input, not to a held one.

**Lifecycle concurrency (12)**
- T(V): `testAFailedLivenessProbeRestartsTheRelayOffTheMainThread`; `testARelayRestartThatFindsSystemDNSReleasedStartsNothing` (both `D`, same names).
- T(V) + C: `testAStopIssuedWhileTheStartAppliesLandsLastAndTheStartGoesNoFurther` → `D`, same name. The client test: an overtaken Start produces no login-item repair and no "Proxy Enabled".
- T(V) partial + W: `testProxyAndDNSStartAndStopWaitOnTheHelperOffTheMainThread` → `D.testStartAndStopWaitOnTheHelperOffTheMainThread`. The host test lacks the VPN-connected resolver file and `.applyDNS`/`.removeDNS`; extend it.
- T(N):
  - `testAStopIssuedBeforeTheBindLeavesNoListenerAndTheNextStartComesUp` → `D.testAStopAdmittedBeforeTheBindLeavesNoListenerRunning`;
  - `testAStaleStartReleasedWithANewerStartLeavesTheNewerListenerRunning` → `D.testAStaleStartReleasedAfterANewerStartLeavesTheNewerListenerRunning`;
  - `testRepeatedDNSStopsWhileTheFirstIsHeldRunOneTeardown` → `D.testRepeatedStopsWhileTheFirstIsHeldRunOneTeardown` and `CO.testARepeatedStopJoinsThePendingStopWhileItsFenceStands`;
  - `testQuitWhileAStartIsHeldProceedsAfterTheDeadline` and `testQuittingWhileAStartAppliesClearsAfterTheApply` → `IN.testQuitLatchesFirstKeepsAPredatingOwedSaveAndJoinsEveryLane` and `CO.testTheClientQuitKeepsItsCallerToTheTotalDeadlineWhileAnUnobservedTeardownIsHeld`. If neither asserts the resolver file is cleared, these become W.
- O, deliberately replaced: `testASettingsChangeWhileTheStartAppliesIsReconciledAfterIt`. Decision 0037 changed the behaviour; its replacements are `D.testAReloadReplacingTheInputWhileTheStartAppliesHoldsTheRestOfTheStart`, `CO.testASavedPairReplacedWhileAnApplyIsParkedHoldsTheRestOfThatApply` and `CO.testAReplacementAfterASavedStartsCaptureHoldsItsRemainingEffects`.
- C + W: `testARestartOvertakenByAStopDoesNotReportARestart`. Needs a host Restart overtaken by a Stop that reports no success.
- W: `testADNSStopIssuedWhileTheStartAppliesLandsLast`. Module DNS Start against DNS Stop: interfaces restored afterwards, no "DNS on" persisted, no health timer left running.

**Flags and machine (7)**
- C: `testFlippingLaunchAtLoginRegistersBeforeThePassRuns`.
- T(N) + C: `testTheSystemProxyFollowsItsSwitch` → `D.testASystemProxySwitchFlippedOffOnReloadClearsItWithoutAStop`.
- T(N), `D` same names: `testStopClearsASystemProxyTheSwitchNoLongerNamesWhenTheJournalOwnsIt`; `testStopRemovesAResolverFileTheSwitchNoLongerNamesWhenTheJournalOwnsIt`; `testStopLeavesAResolverFileTheUserWroteWhenTheSwitchIsOff`.
- W: `testQuittingBeforeAQueuedPassRunsStillClearsTheSurface`; `testAFailedStartRevertsEverySurfaceItFindsApplied` (unrecorded leftovers are reverted).

**Split-DNS repair (10)**
- T(N):
  - `testThePendingRepairsHelperCheckFindsAHelperInstalledOutsideTheApp` → `D.testAFailedRemovalIsRetriedWhenTheHelperCheckFindsTheHelperAvailable`. Check that it covers "a check that finds the helper still refusing retries nothing";
  - `testARefusedRemovalOnAConfigEditIsRetriedWhenTheHelperIsAvailable`, `testAFailedSwitchOffTeardownIsRetriedWhenTheHelperIsAvailable`, `testASwitchOnSettledByAVPNFlipIsTornDownWhenTheSwitchTurnsOff` → their `D` "…Reload…" counterparts.
- W:
  - `testAFailedRemovalIsRetriedWhenAnInstallMakesTheHelperAvailable` (the new path is install → `refreshPreflight(helperReplaced:)` → `observeHelperForSplitDNS`);
  - `testAFailedStartWriteIsRetriedWhenThePreflightFindsTheHelperAvailable`;
  - `testARetriedSwitchOnIsTornDownWhenTheSwitchTurnsOffAgain`;
  - `testAnInterceptRefreshThatStillFailsDoesNotStrandARetriedEntry`;
  - `testANewFailureGetsAFreshHelperCheckRatherThanAnEarlierBackOff`;
  - `testABusyHelperReadingDoesNotRetryUntilTheRecheckFindsItAnswering`, which also needs a client part for the busy re-read.

**Updates (3): C, keep.** `testCheckForUpdatesStartsTheInjectedUpdater`; `testTheFirstLaunchOfANewVersionRecordsTheChange` (the event source becomes the app-local log); `testAutomaticChecksFollowThePreference`.

## The other six files: 67 tests

**ConfigSaveGateTests (11)**
- C + W: `testRefusedSaveIsNotReconciledAndEmitsSaveRejected`. W: when the store refuses an update, it emits `config.save_rejected`, applies nothing and keeps the files.
- T(N) + W, the update path saves but applies nothing:
  - `testBlockingCommitIsWrittenButHeldOutOfTheRuntime` (`PrivateConfigBridgeTests.testBlockingDraftsMapBothWaysAndAreClassifiedNotRefused` covers the mapping only);
  - `testMappedOutOfRangePortIsSavedAndHeldOutOfTheRuntime` (`PrivateConfigBridgeTests.testOutOfRangePortMapsBothWaysAndIsHeldNotRefused`, `ProxyStartGateTests.testAnOutOfRangePortStillRefusesToStart`).
- T(N) + C:
  - `testValidCommitIsReconciledWithoutAGateEvent` → `CO.testAnApplyWhileRunningUpdateAppliesOnlyToTheModuleStillRunningAtItsRevision`;
  - `testLaunchWithAPersistedUnholdableDurationRefusesToStartTheRuntime` → `D.testAStartRefusedForAStartBlockingConfigAppliesNothing`, `ConfigRuntimeRangeRefusalTests`;
  - `testPlatformWriteFailureKeepsTheEditUnsavedUntilACommitRetriesIt` → `ConfigurationStoreTests.testAnAuthorizedRuntimeIsHeldBehindARefusedPlatformWithItsOwnReason`;
  - `testPreferencesWriteFailureKeepsTheEditUnsavedUntilQuitRetriesIt` → `CO.testAPreferencesUpdateWritesOnlyThePreferencesFileAndSettlesWithItsReceipt`;
  - `testQuitWritesThePlatformFlagWhenTheRuntimeSaveIsRefused` and `testQuitDoesNotWriteABlockingDraftButStillWritesThePlatformFlag` → `CO.testTheClientQuitFlushesASidecarEditBesideTheCleanRuntimeValueAndWritesNoDisable`;
  - `testMappedNonBlockingDraftSavesAndReconcilesUnrelatedProgress` → `PrivateConfigBridgeTests.testNonBlockingInterceptProblemsMapAndDoNotBlockApply`.
- W + C, must survive: `testMappedUserInfoDraftIsHeldAndItsCredentialIsAbsentFromEveryPresentation`. The redaction must hold across events, logs, the snapshot and receipts on the update path.

**PACPreviewTests (5)**
- C, keep: `testEmptyTargetIsRejectedBeforeFetching`; `testInvalidTargetsAreRejectedWithoutCrashing`; `testPreviewShowsChainAndCapturesTargetWithOneOperationInFlight`; `testInvalidScriptShowsFailureAndReleasesPreviewSlot`. These use the app-owned evaluator. The comment at lines 90-91 saying the evaluator is "shared with the runtime" becomes false.
- K: `testPreviewTargetDefaultsAndRepairsLegacyEmptyPreference` is a pure `AppPreferences` decode.

**AppStateHarnessSidecarRefusalTests (2)**
- T(N) + C, must survive "names only the file": `testARefusedPreferencesSaveKeepsTheRuntimeSaveAndApplyAndNamesOnlyTheFile` → `CO.testAPreferencesUpdate…`.
- C + T(N): `testARefusedStartupPreferencesSidecarBlocksEverySaveAndKeepsItsBytes` → `ConfigSidecarBoundaryTests.testARefusedSidecarKeepsItsBytesThroughEveryLoad`, plus the refused-load composition client test.

**DiagnosticWriterLeaseProtectionTests (2): K.** They test the guard directly. Update the comment at line 13 to point at the retained composition tests.

**RuntimeStartupOwnershipTests (28)**
- K (25): the state-root and layout tests construct no AppState.
- C, keep; the refusal must still come before any seed or host open: `testASessionForAnotherRootRefusesBeforeAnyWrite`; `testAProtectedSessionRootRefusesBeforeAnyWrite`; `testAChildAliasOutsideTheRootIsFoundBeforeAnySeed`.

**DevLaunchOptionsTests (19)**
- K (18): parsing, state directory and alias tests.
- C: `testTheDevCompositionRunsOverTheFakes`. It becomes a host over the fakes, install through the app-side lifecycle, and Quit through `RuntimeClientQuit` until stopped.

## Write-first list (W) before the single cut

1. **Observers during a module Stop:** the three notification-during-Stop tests.
2. **Helper becoming available:** PAC repair after a conclusive preflight; split-DNS retry after an install or a preflight; the busy reading gating the retry.
3. **Split-DNS repair family:** retried switch-on torn down; intercept refresh still failing; fresh helper check after a new failure; entries following the VPN.
4. **Drift:** periodic tick; switch off or proxy stopped; repairs go to the applied input; partial environment recovering on retry.
5. **Lifecycle:** module DNS Start against DNS Stop; Restart overtaken by Stop; Quit with a queued pass; a failed Start reverting unrecorded leftovers; extending the off-main-thread test with VPN and resolver files.
6. **Config gate on the update path:** store refusal; saved but not applied (start-blocking, out-of-range port); the user-info redaction.
7. **Credentials and listener:** cache warmed through the `.start(.proxy)` command; zero reads without a saved password; localhost pinning; a listen-host update keeping DNS on loopback.

## Tally: 178

| Disposition | Count | What it covers |
|---|---|---|
| T only | 31 | named host twin is the whole cover |
| T + C | 23 | host twin, plus a client-side repoint |
| T + O | 6 | twin plus an obsolete app trigger; check the twin before deleting |
| T + W | 4 | twin exists but is partial; extend or add a host test |
| C only | 50 | |
| C + W | 3 | |
| W only | 13 | |
| O only | 2 | |
| K | 46 | |

- The 5 tests marked T(V) partial + W, T(N) + W or C + W also count toward the W list.
- Of the T rows, I compared assertions on 15 (T(V)). The rest are T(N): verify each before deleting.
- The parent checked the final total of 178 against the source lists; this remains a pre-cut candidate map.

## Keep-only identities

These do not construct AppState and remain independent of the cut.

- PACPreviewTests: `testPreviewTargetDefaultsAndRepairsLegacyEmptyPreference`.
- DiagnosticWriterLeaseProtectionTests: `testAnAliasOfTheWriterLeaseIsRefusedByAnAdoptedGuardAndTheLeaseKeepsItsAuthority`, `testEveryAdoptingSinkRefusesAnAliasOfTheWriterLease`.
- RuntimeStartupOwnershipTests: `testBusyRootRefusesBeforeAnyReadAndLeavesTheConfigurationBytes`, `testBusyRefusalIsCountedOnceAndTakesNoOtherAuthority`, `testFreshRootReportsNoPriorConfiguration`, `testConfigPresenceIsReadOnlyAfterTheLeaseIsHeld`, `testFreshNestedRootWithACustomNameIsRefusedBeforeAnyEffect`, `testAnOverlongRootIsRefusedBeforeAnyEffect`, `testEveryWriterRoleRefusesAnArbitraryNameBeforeAnyEffect`, `testAFoldAliasOfASlotIsDecidedAfterTheLeaseByTheVolume`, `testFreshNestedRootIsCreatedWithItsAncestorsOwnerOnly`, `testDirectoriesAreMadeOutermostFirstAndAllBeforeTheLease`, `testANonDirectoryAncestorIsRefusedAndNothingBeneathItIsCreated`, `testADanglingAncestorLinkIsRefusedAndNothingIsCreatedThroughIt`, `testRacedRootCreationIsAcceptedWhenTheRaceProducedADirectory`, `testRacedRootCreationIsRefusedWhenTheRaceProducedAFile`, `testRacedAncestorCreationIsAcceptedWhenTheRaceProducedADirectory`, `testRacedAncestorCreationIsRefusedWhenTheRaceProducedAFile`, `testADanglingFixedSlotLinkIsRefusedAndItsTargetIsNotCreated`, `testFixedLeafCaseAliasResolvesToTheSlotOnACaseFoldingVolume`, `testFixedLeafCaseVariantIsRefusedOnACaseSensitiveVolume`, `testConfigSymbolicLinkToAContainedTargetWithAnyNameIsTheAuthority`, `testConfigSymbolicLinkToAReservedResourceIsRefused`, `testCustomConfigNameIsRefusedAndItsBytesArePreserved`, `testSplitRootRefusesAnOutsideConfigurationBeforeAnyWrite`, `testRootReplacedAtTheSamePathDuringTheLayoutIsRefused`, `testHeldAuthorityEndsWithItsSessionAndNotBeforeTheOwnerDrops`.
- DevLaunchOptionsTests: `testWithoutTheFlagTheLaunchIsProduction`, `testTheFlagAloneTakesTheDefaults`, `testEveryFlagLands`, `testVPNOffReportsDisconnectedWithNoInterface`, `testADevFlagWithoutDevIsRefused`, `testBadValuesAreRefusedByName`, `testTheDevBundleIsTheDevInstanceWithoutAnyFlag`, `testOnlyTheExactDevIdentifierSelectsTheDevInstance`, `testTheRequestIsMadeByFlagOrByBundle`, `testADevRequestRefusesTheWorkerModesByFlagOrByBundle`, `testAReleaseBuildRefusesTheDevInstanceByFlagOrByBundle`, `testTheStateDirectoryCannotReachTheInstalledAppsFiles`, `testTheProductionDirectoriesAreTheInstalledAppsConfigAndLog`, `testAChildAliasOutsideTheStateRootIsRefused`, `testADanglingChildAliasIsRefused`, `testAliasesThatStayInsideTheStateRootAreKept`, `testACaseVariantIsRefusedOnlyWhenTheVolumeResolvesItToTheInstalledDirectory`, `testTheStateRootRefusesAnAliasBeforeAnyWrite`.


## Addition after the 178-test checkpoint

`AppStateHarnessTests.testAHealthReadingFromASupersededDNSRunActsOnNothing` was
added with the minimum twin-host DNS guard. It checks that run A cannot restart
run B's relay, while B's own failed observation still acts. Compare it with the
shared-host DNS-health witnesses before retiring the legacy harness at activation.
It does not claim the legacy transient UI overlay stays visible.
