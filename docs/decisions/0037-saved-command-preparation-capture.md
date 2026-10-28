# 0037: Capture saved command input once at preparation

- Date: 2026-10-26
- Decision: accepted (owner, 2026-10-26, #186)
- Implementation: implemented
- Validation: pending
- Supersedes: none
- Superseded by: none

## Context

Private editor requests carry frozen values and exact baselines (0035). Saved
commands, including ordinary Restart and the daemon Start facade, carry no editor
values. The existing records select required-input verification, but not when such
a command binds its saved configuration. Legacy preparation read current store
values and could then follow a newer eligible reload through the Start push.

After subscription-backed Claude review, the owner selected preparation-time
capture and directed completion of the shared owner and removal of duplicated
paths, with simple store/load ownership and only material architecture questions.
Authorization is recorded in [#186](https://github.com/srps/Conduit/issues/186).
The comparison remains in the [input-binding review](../design-saved-runtime-input-binding.md).

## Decision

A saved command captures the current required runtime/platform pair once when
preparation obtains capacity, before staging or writing. It retains no captured
configuration while queued. Verify required inputs and defaults through the sole
store/workflow, then use that same prepared pair for the command's effects.
A newer observation replacing the captured input before affected effects holds or
supersedes remaining work. Report an explicit typed result; do not rebind or retry.
Already-completed persistence and physical effects remain reported facts.

Private editor requests retain their submitted frozen values and exact baselines.
Both input sources use one store/load/write pipeline and one runtime owner.
Stop still fences immediately and Quit preserves its selected exceptions.
The rule adds no registry, parallel loader, per-client execution path or compatibility
mode matrix. Complete shared ownership, then activate AppState once and delete its
replaced runtime/save paths as selected in 0031.

## Alternatives

- Pin saved input at admission: gives the click a stronger meaning but retains
  queued captures and holds even when a new verified configuration arrives before
  work begins. The local prototype explored this; remove it rather than retaining a mode.
- Follow newer eligible reloads through startup: preserves more legacy progress,
  but needs a later rebind point and receipt rules for prepared A / used B. It was
  not selected; there is no need for an automatic retry loop to preserve it.

## Consequences

The binding point is explicit and uses the existing preparation boundary. A
reload before preparation can supply the saved input; one replacing it afterwards
can hold remaining effects. This intentionally changes legacy late-reload behavior.
Make the hold observable rather than returning apparent Start success.

No file-schema change is selected. Preserve compatible readers and existing
canonical codecs. Further breaking behavior must be called out explicitly; do
not preserve accidental interleavings through additional maintenance modes.

## Invariants and verification

Exercise reload before capture (use the new pair), reload after capture (hold,
no rebind), capacity refusal, external-file conflicts, default/sidecar verification,
Stop at suspensions and coherent proxy/DNS inputs. Use the actual workflow/host,
an independent bounded model and headless actual-host scenarios. A superseded
Start must not report success or leave new activation permission behind.

## Implementation evidence

The saved process facade now uses
[`commitCapturedRuntimeAndPlatform`](../../Sources/ConduitRuntime/ConfigurationStore.swift)
to take the sole store slot before the workflow captures values.
[`RuntimeConfigurationWorkflow`](../../Sources/ConduitRuntime/RuntimeConfigurationWorkflow.swift)
returns a prepared pair whose receipts must remain current;
[`RuntimeHost`](../../Sources/ConduitRuntime/RuntimeHost.swift) holds remaining
effects when it is replaced and reports a typed refusal. The admission pin and
late-follow path are removed.

[`ConfigurationCaptureModelTests`](../../Tests/ConduitTests/ConfigurationCaptureModelTests.swift)
drives the actual workflow/store through 93 bounded histories and 165 transitions,
including six changed-then-restored cases. At checkpoint `2912670`, independent
verification passed 259 focused tests, the actual-host simulator and the complete
Swift suite (3,488 tests, four skips). A subscription-backed static Claude review
supported the capture shape and identified integration obligations.
[Three executed production guard mutations](../experiments/preparation-capture-guards/README.md)
failed their intended assertions; restored tests passed. The subsequent full workflow and fresh combined-owner review are recorded in the shared-owner verification below.

The subsequent [shared module owner](../verification-runtime-module-owner-2026-10-27.md) adds scoped lifecycle cleanup, member/companion outcomes and completion ordering over that same capture path. It introduces no alternate writer or rebind loop.

Does not prove: actual framed-client/private-editor adoption, final AppState activation, RuntimeActor isolation, production profile selection, release readiness or real-machine behavior.

The local [actual-client checkpoint](../verification-runtime-client-owner-2026-10-27.md) connects [`RuntimeHostControlOwner`](../../Sources/ConduitRuntime/RuntimeHostControlOwner.swift) to the actual framed client while retaining this single preparation-time capture. Private Starts retain their frozen submissions. No admission snapshot registry or late rebind path is introduced; final integration review and AppState deletion remain open.

The native-client completion adds ordinary saved Start and gives saved Start and
Restart the same causal receipt as private Start.
[`ControlRuntimeCommand`](../../Sources/ConduitShared/ControlRuntimeCommands.swift)
requires the exact module revision;
[`prepareStart`](../../Sources/ConduitRuntime/RuntimeConfigurationWorkflow.swift)
captures prior component baselines in the sole store capture turn. A submitting
draft can advance only while it still matches that prior. Private frozen receipt
encoding, v1 control, helper IPC and schema-two files remain unchanged. The
unshipped v2 Restart result now reports persisted facts and member outcomes
instead of generic success. The
[native-client verification](../verification-runtime-native-client-2026-10-27.md)
records the 125-history saved-Start model, its executed causal-prior guard,
focused checks and workflow results.

### Activation compatibility clarification (2026-10-27)

The app activation exposes a concrete legacy difference already covered by this
decision and 0035: enabling DNS while a proxy Start is still applying commits a
new input and can supersede that unfinished proxy Start. Its partial resources
are torn down; it does not silently rebind or retry. The user must explicitly
Start again. The legacy AppState path could follow the later configuration.

Independent review of the interim app activation confirmed this interpretation
against the existing host lifecycle; the host policy was not changed by that
activation. The owner was notified of this user-visible consequence. The app
must explain the typed input_replaced result, and the actual-client witness
must cover DNS progress, partial cleanup and no automatic proxy retry. The
RuntimeActor activation evidence below records that witness; this note records
no new owner decision or completed release acceptance.

### Activation and isolation (2026-10-28)

The single AppState activation (0031) and RuntimeActor isolation complete this
decision's integration: the app's saved Start and Restart use the sole
store/workflow capture through its framed clients, and AppState's replaced
runtime/save paths are deleted. No rebind, retry or admission pin was added.
[`AppStateActivationParityTests.testADNSStartCommittedWhileAProxyStartAppliesHoldsThatStartAndSaysWhy`](../../Tests/ConduitTests/AppStateActivationParityTests.swift)
asserts the app's interruption message, the host's `input_replaced` hold, DNS
running, cleanup of the held Start's surfaces and journal records, no automatic
retry or login-item repair, and the next explicit Start. It passed in the
3,768-test workflow recorded in the
[RuntimeActor activation verification](../verification-runtime-actor-activation-2026-10-28.md).
The race is covered by this actual-client harness; no second, forced race on
the installed app or real helper is required. Ordinary real-helper and app
acceptance of the release remains due and has not been recorded.

Does not prove: installed-app or real-helper behavior, release packaging or release readiness.

## Open questions

The collection count/byte policy is selected in [0038](0038-bounded-runtime-collection-capture.md).
Remaining custody/deadline limits still require complete actual-adapter measurements.
Bring only material architecture choices back to the owner.
