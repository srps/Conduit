# 0037: Capture saved command input once at preparation

- Date: 2026-10-26
- Decision: accepted (owner, 2026-10-26, #186)
- Implementation: partial
- Validation: none
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
failed their intended assertions; restored tests passed. Every workflow gate and
fresh review of the later combined owner remain due.

Does not prove: module lifecycle/client integration, scoped cleanup, final
AppState activation, release readiness or real-machine behavior. These remain
incomplete at this checkpoint.

## Open questions

Production custody/deadline limits still require actual-adapter measurements.
Bring only material architecture choices back to the owner.
