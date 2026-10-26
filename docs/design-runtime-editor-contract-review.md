# Private editor and client integration: next-cut review

Status: proposal for review, 2026-10-26. No new owner decision or implementation
is implied. The shared-host workflow slice is verified separately; AppState
still owns its runtime and writers. Accepted decisions 0014/0015/0018/0025/0027/
0031/0032 govern this proposal. The production daemon socket remains later work.

## One owner, one client path

RuntimeHost and its private workflow/store serve the app through the actual framed
RuntimeClient. Add no AppState save coordinator or direct in-process mutation
shortcut. The service adapter consumes the host instead of becoming a second
runtime owner. Use one host incarnation across host, workflow, service and
observations; the store's baseline namespace has a separate authority purpose.

An editor observation captures current runtime, platform and preference values
with matching per-component baselines in one owner turn. Its component state must
distinguish verified, permitted absence and retained last-known values; it must
not manufacture authority for a failed observation. A baseline carries its exact
namespace, component and UInt64 version, without narrowing it into Int-based
control ordinals. The existing v1 configuration generation keeps its accepted-view
meaning and is not reused as a persistence or applied-state token.

Ordinary editor reads use this memory observation. Only explicit reload observes
disk and reconciles eligible changes. A different client's reload cannot replace
a dirty draft or refresh its original save preconditions.

## Private values and operations

Extend the existing explicit private codec rather than putting frozen configuration
values or private URLs in ordinary control messages. Use the same private exchange
through the real in-memory transport now and a later socket. Its work and capacity
must remain independent of Stop/status. Ordinary operation lookup/events retain
bounded safe metadata and handles, not the configuration body.

Separate operations by selected semantics:

- Runtime/platform updates carry the full frozen input, relevant component
  baselines and explicit lifecycle intent. The sole store supplies exact verified
  inputs; mixed apply remains held until all required inputs verify.
- Preference updates use their own component baseline and no runtime lifecycle
  generation or apply. A preference failure cannot veto independently verified
  runtime work.
- Private reads return a coherent memory observation. Reload is a distinct
  deliberate action, with ordinary safe outcome metadata and private values
  returned only through the private channel.

Keep launch-at-login as app administration, while persistence still goes through
one store. Its field shares platform.json today: use a narrow administrative
operation under that component's precondition and preserve its current value
when a runtime/platform edit does not express that administrative intent. Do not
add a direct app writer or let an old draft restore the flag accidentally.

Only a causal receipt for the matching submitted update may advance that draft's
baselines. Preserve edits made after submission. Snapshots and ordinary reads do
not retokenize dirty drafts; explicit reload/review remains conflict recovery.

Quit fences the runtime immediately and closes ordinary admission. Reserve one
final flush of the client's latest valid local draft, whether already submitted
or still waiting on autosave. It uses the same private runtime/platform and
preference operations and sole store, within one total Quit deadline, and is
never applied. Its reserved write claim must survive the Quit fence until that
flush window closes. Preserve lifecycle intent from before Quit and write no
disable. Invalid drafts do not block Quit; writes already started may complete.
There is no direct app save or second writer. Stop fences control before
persistence, and late writes cannot restore stopped enable intent. Ordinary knob saves under a
Stop fence must not implicitly re-enable a module. Map the interactive per-module
commands to the already selected per-module intent/fence policy; the current
whole-host process-start facade is not the final interactive API.

## Candidate private editor shapes

These names are candidates for review, not an API. They live beside the request DTOs in
`ConduitShared/PrivateConfiguration`. They are non-`Codable`, and only the private codec reads or writes them. Kernel mapping
stays in `ProxyControlBridge`.

**Baseline.** `PrivateBaseline` holds a store namespace UUID, a component (runtime, platform or preferences) and a
`UInt64` version. It is the wire form of `ConfigurationBaselineToken`, which only the store mints (its initializer is
`fileprivate`). A decoded baseline becomes a token only inside `ConfigurationStore.swift`, and the existing
`authority(_:for:)` check still decides. The namespace is the store's incarnation, separate from `ControlHostIncarnation`.
A version is a decimal lexeme of at most 20 bytes. A codec test pins a `UInt64.max` round trip through the scanner and
`JSONDecoder`.

**Observation (private read).** It is captured from memory in one owner turn, with no disk I/O:

- `hostIncarnation`, the owner generation and the terminal flag.
- The existing `PrivateRuntimeConfiguration` and `PrivatePlatformConfiguration`, a new `PrivatePreferences` whose browser
  URL is a `PrivateURLValue`, and the stored `launchAtLogin` as read-only administrative state.
- One state per component:
  - `verified(baseline)`: the store holds a baseline and the file was present;
  - `absent(baseline)`: the baseline of an observed absence, with loader defaults or a legacy fallback as values;
  - `retained(reason)`: no baseline, and the last values are for display only.

  The state describes what the store holds now, not a fresh per-component verification. A load adopts all three
  baselines from one observation. A refused load latches all three at once, including one refused for version
  exhaustion, so `observationRefused` is a whole-observation reason on every component. Only write-time facts latch one
  component:
  - `changedSinceBaseline`: a write conflict, a verification that found a change, or a changed sidecar during preservation;
  - `writeUnknown`.

  A write refused for version exhaustion returns `notAttempted(.versionExhausted)` before any I/O and latches nothing
  (`ConfigurationStore.write`), so that component's baseline and authority stay in force.

  The store does not keep the reason today. Recording one closed reason at its existing latch sites is the only store
  addition. Migration and fallback flags appear only if the store keeps the last load's per-component facts.
- Three module intents (module, `ControlLifecycleRevision`, enabled, fenced), from the selected per-module intent. The
  current whole-host generation does not substitute for it.

**Runtime/platform update.** The existing `PrivateConfigurationRequest`, revised:

- Two exact baselines replace the Int `expectedConfigRevision` and `expectedPlatformRevision`.
- Explicit per-module lifecycle intent replaces the whole-host `expectedOwnerGeneration`. Each module's intent names its
  expected `ControlLifecycleRevision` and is one of:
  - **save only:** an ordinary knob save. It persists and changes no lifecycle state.
  - **apply while running:** it persists, then applies only where the module is still running under that revision.
  - **start (enable):** an explicit enable with these frozen values. It persists them, then starts the module from the
    verified pair.

  Only a current explicit start may clear that module's Stop fence. It is current when its revision still matches and no
  newer Start or Stop superseded it. A save-only or apply-while-running update never clears a fence and never enables a
  stopped module.

  This follows the selected per-module intent and fence policy; it is not a new owner question. Ordinary
  `ControlRuntimeCommand` defines no start: its comment defers Start and configuration apply. So an editor Start travels
  on this private request, with its frozen values. No matching public half is implied or required.
- The platform values still exclude `launchAtLogin`. The host fills that value from the store's current platform value,
  under the same platform baseline, so an old draft cannot restore it.

**Preferences update and launch-at-login administration.** Two separate small private requests, each under its own single
baseline: preferences, or platform for the administrative flag. Neither carries lifecycle intent or applies anything.
The administrative operation needs a platform-only store commit. Today's coupled commit holds an authorized platform write
behind a latched runtime file (`heldBehindRuntime`).

**Causal receipt.** It carries:

- `requestID`, client-minted and the one causal key. The client maps it to its submitted draft locally, so no separate
  draft identity crosses the wire.
- The host incarnation.
- One outcome per requested component. It maps `ConfigurationWriteOutcome` through the existing closed workflow causes
  (`noBaseline`, `baselineMismatch`, `stagingRefused`, `preReadFailed`, `replacementRefused`, `heldBehindPlatform`,
  `heldBehindRuntime`, `preservationHeld`, `versionExhausted`, `superseded` and the unknown read-back reasons). It names
  the new baseline only for `persisted` or `unchanged`.
- The apply or start outcome, per module.

A busy store slot is a capacity outcome, distinct from a persistence failure. The receipt is secret-free, so ordinary
request and operation lookup can carry the same metadata after a lost reply, without retaining any private body. Only this
receipt advances the matching draft's baselines.

**Codec reuse.** The codec stays one header grammar, with a reply kind byte beside `Q` and a separately named reply cap.
The reader takes the expected kind and its cap, and it still refuses an oversize declared length before any body byte. The
same two-pass emitter writes replies, with `writeRuntime` and `writePlatform` unchanged, so oversize refusal still precedes
allocation. The same table-driven scanner, with new root tables and the existing wire mirrors, decodes them. There is no
generic JSON value tree, no second parser and no `Codable` on private values.

**Migration obligations, not owner policy and not shipped defects:**

- Introduce one shared host incarnation across the new owner, the workflow and the service. `RuntimeHost` does not expose a
  `ControlHostIncarnation` yet, and `RuntimeConfigurationWorkflow` mints its own for its store contexts.
- Propagate the client's actual `requestID` into the store context on the new client path.
  `RuntimeConfigurationWorkflow.context(generation:)` mints a request ID per store call. That is correct for today's
  process-start facade, which has no client request.
- Replace the request's incompatible revision fields before integration. The unadopted request carries Int-based
  `expectedConfigRevision` and `expectedPlatformRevision`, which cannot represent an exact store baseline (namespace,
  component and `UInt64` version). No production converter narrows store versions to Int today.

## Private channel concurrency

Decision 0021 already selects one global active private body/decode, refusing a busy peer before another body is
reserved. Implement that as its own transport lane, with capacity one and its own custody term. The ordinary 64 KiB caps,
the ordinary lanes' two-request-plus-two-reply charge and the per-module Stop lanes stay unchanged.

An owner turn only captures copy-on-write values, tokens and intents, or admits. Encoding, reading and decoding run off the
main actor and off `PlatformWork`, so neither the owner nor helper and Stop cleanup effects queue behind a codec pass. In
the request probe, reading one 7.38 MB frame took about 0.94 s and the two encode passes about 0.22 s. The first
correction to measure is a batched body copy inside the existing reader, rather than a new `SecretBytes` API. Actual-host
Stop/status latency during transfer and store staging is service-profile work.

## Before the AppState switch

1. Select the affected limits below from measurements; finalize the concrete
   private observation/update/reply values with codec and compatibility fixtures.
2. Connect the actual host to the existing service/client, implement private
   editor operations and consolidate administrative/preference saves in the sole
   store. Inventory every AppState presentation/preflight read and command.
3. Verify DNS/intercept, tunnels and proxy together: recovery, retries, helper and
   platform effects, mixed changes, draft conflicts, partial persistence,
   supersession and shutdown. Keep real-host and AppState twins until parity.
4. Activate AppState once. It retains drafts, presentation, notifications, updates
   and AppKit administration; delete its replaced orchestrator, runtime/reconciler/
   observer and direct-save paths in that integration change. Then consolidate
   the twin tests into shared coverage plus thin composition/client tests.

RuntimeActor is the selected step after convergence, moving the whole control
cluster together. Production socket/LaunchAgent handoff and real-machine release
acceptance remain separate work; none is proved by this proposal.

## Interactive admission still to implement

Put host-owned store operations in generation order within bounded ordinary
admission. A Start waiting behind an in-flight operation rechecks its ticket and
fences before acting; newer Start/Stop supersedes it. Refuse capacity before
changing lifecycle intent, distinguish capacity from persistence failure and
retain Stop's independent capacity. This follows 0014/0015, rather than adding a
new owner policy or a second unbounded queue.

The current process-start facade is not ready to expose unchanged to interactive
clients: a busy store is reported as commitFailed after Start has cleared the
fence. A later reload can then pass that fence. There is one production daemon
Start call, a held daemon Start exits the process, and no production reload
caller today; concurrent cases currently
exist only in tests/scenarios. Before service/client adoption, cover capacity
holds retaining a prior Stop fence and genuine persistence failure followed by
reload, alongside runtime/platform updates. The model and host admission tests
must evolve with that integration.

Complete the preference and narrow administrative platform commit operations,
per-module intent/fences and reserved Quit flush before the app switch. They use
the same store and private path. The current whole-host startup generation is
not a substitute for the selected per-module interactive contract.

## Decisions and design gates

- **Private editor reply ceiling:** selected by the owner on 2026-10-26 in
  [0034](decisions/0034-private-editor-reply-frame-cap.md). The request cap stays 8 MiB, and ordinary reply/stream
  frames stay 64 KiB.

  The separately named private reply frame cap is 8,388,608 B, equal to the request cap. Evidence
  from the [reply sizing experiment](experiments/private-editor-reply/README.md):

  - The actual request frame for the maximum storable shape is 7,382,956 B, and the conservative request bound is
    7,400,547 B.
  - The estimated reply bound is 7,523,543 B, with 865,065 B (10.3%) of headroom. It adds the widest preferences and a
    lexeme-charged allowance for the executed mirror's metadata: three component states, three module intents and one
    receipt.
  - That bound covers the executed mirror, not the finished API. The mirror's receipt has one aggregate apply outcome and
    reason, plus a draft identity. The candidate receipt above has an apply or start outcome per module, and no draft
    identity on the wire. Those per-module result members, and any other bounded member the final shape adds, consume the
    865,065 B headroom. The actual codec must measure them.
  - Alternatives:
    - 4 MiB is below the actual demonstrated loadable shape, a 7,382,956 B request-shaped body before any reply metadata,
      so it would refuse a configuration the store can load.
    - 8 MiB fits the conservative bound.
    - 16 MiB has no measured need and increases the worst-case reply reservation. The 8 MiB request terms of the custody
      charge are unchanged.
    - A cap between the demonstrated frame and the bound is not shown to make anything unobservable. The bound is
      conservative, not a demonstrated shape.

  The estimate comes from a mirror, not a reply codec. The request-path memory figures are not reply or whole-host
  figures. The dominant bytes come from the production writer
  and are measured. The mirror's metadata allowance uses 2.8% of the headroom.

  Adoption requires the actual reply codec to show, for the maximum observation:

  - its measured size, with exact-limit and one-over refusal before allocation;
  - release lifetimes with host-retained and client-held values in one process;
  - Stop/status latency during transfer.
- **Production service profile:** remaining queue, retained outcome/replay,
  subscriber, per-turn work, deadline and shutdown values are unselected. The
  existing coherent candidate is test-only; validate the actual host adapter
  before asking for shipping values.
- **Conditional later choices:** bind-new/repoint/retire listener handoff needs
  owner selection before changing current behavior. Whether a bounded #194
  applied-state expansion joins the release is also a scope decision. Neither
  justifies silently introducing independent effect groups or blocking an
  otherwise behavior-preserving host migration.

The candidate shapes above are review input; final type names and the field inventory land with the codec and its
compatibility fixtures. Implementations
must use the selected module boundaries and private channel, with no registry,
parallel writer, public test hook or new dependency.
