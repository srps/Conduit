# Private editor and client integration: next-cut review

Status: headless contract implemented; host/client/draft integration remains under
review, 2026-10-26. The owner selected the private reply ceiling in 0034. The shared-host
workflow and private codec have separate verification; AppState still owns its runtime
and writers. Accepted decisions 0014/0015/0018/0025/0027/0031/0032/0034 govern the work.
No production daemon socket or AppState activation is implied.

## One owner, one client path

RuntimeHost and its private workflow/store serve the app through the actual framed
RuntimeClient. Add no AppState save coordinator or direct in-process mutation
shortcut. The service adapter consumes the host instead of becoming a second
runtime owner. Use one host incarnation across host, workflow, service and
observations; the store's baseline namespace has a separate authority purpose.

An editor observation captures the store's current runtime-file, platform and preference values
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

## Headless private editor contract

The values live beside the request DTOs in `ConduitShared/PrivateConfiguration`. Private values remain non-`Codable`,
with explicit private encoding/decoding and redacted reflection. Kernel mapping stays in `ProxyControlBridge`.
The codec and matchers are implemented; a real host memory provider, framed client methods and writer adoption remain
integration work. DTO construction alone does not establish an owner turn or persistence authority.

**Baseline.** `PrivateBaseline` holds a store namespace UUID, a component (runtime, platform or preferences) and a
`UInt64` version. It is the wire form of `ConfigurationBaselineToken`, which only the store mints (its initializer is
`fileprivate`). A decoded baseline becomes a token only inside `ConfigurationStore.swift`, and the existing
`authority(_:for:)` check still decides. The namespace is the store's incarnation, separate from `ControlHostIncarnation`.
A version is a decimal lexeme of at most 20 bytes. A codec test pins a `UInt64.max` round trip through the scanner and
`JSONDecoder`.

**Observation (private read).** It is captured from memory in one owner turn, with no disk I/O:

- The terminal flag. The host incarnation belongs to the correlated reply envelope; no unused whole-host owner generation is added.
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

  The store does not keep the reason today. Recording one closed reason at its existing latch sites remains an observation-specific store
  addition. Migration and fallback flags appear only if the store keeps the last load's per-component facts.
- Three module intents (module, `ControlLifecycleRevision`, enabled, fenced), from the selected per-module intent. The
  current whole-host generation does not substitute for it.

**Runtime/platform update.** The headless `PrivateConfigurationRequest` now carries:

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

**Preferences update and launch-at-login administration (not implemented).** Two small private operations will use their own single
baseline: preferences, or platform for the administrative flag. Neither carries lifecycle intent or applies anything.
The administrative operation needs a platform-only store commit. Today's coupled commit holds an authorized platform write
behind a latched runtime file (`heldBehindRuntime`).

Before exposing either independent sidecar operation, verify legacy fallback dependencies. A missing sidecar can take
its values from the runtime file: after another client's reload changes those values, the sidecar can still be absent.
The store correction retires a missing component's version when its effective canonical value changes and verifies
its runtime-file source before first sidecar creation. Its focused/model/actual-host witnesses and limits are in the
[verification checkpoint](verification-configuration-source-2026-10-26.md). This implements the selected conflict
policy; the independent preference/admin client operations still need adoption through that sole store.

Persistence equivalence belongs in the store's existing codec path. Swift string equality can alias different UTF-8
spellings of URLs and other saved text, so it cannot prove that the requested persisted intent is unchanged. Compare
canonical encodings of the current and candidate values on the store worker, reusing the existing stagers. Capture old
values for reload comparison in the same worker step, and return fixed change facts to the owner. Raw observed-file
baselines still decide conflicts; formatting and unknown fields remain preserved on a no-op. Do not add a second field
inventory, parser, retained hash history or domain API migration for this correction. Known unrepresentable repair values
cannot authorize equality reuse; a valid repair can still be written. Unexpected staging failures stay typed and visible.
Measure the extra staging work and temporary allocations through the actual adapter.

The apply/reconciler uses of configuration equality need separate production witnesses and a cohesive fix before private
apply is exposed ([#246](https://github.com/srps/Conduit/issues/246)). The store correction alone does not establish that
a byte-distinct URL change reaches the active runtime.

**Causal receipt (deferred until workflow integration).** Admission and settlement are separate. An update currently
receives `ControlAdmission` in its correlated private reply; no codec-only success is a saved or applied outcome.

The final receipt must come from the workflow that merges current lifecycle intent into a save. Today DNS lifecycle owns
`dns.forwarderEnabled`; proxy and tunnels have no equivalent persisted global enable bit, and tunnel-definition enabled
flags remain user settings. Do not invent new persisted flags or let a receipt mark an older draft clean after saving
different canonical values. Before the affected integration, specify actual committed lifecycle values and how the client
rebases them while retaining edits made after submission. The receipt obligations are:

- `requestID`, client-minted and the one causal key. The client maps it to its submitted draft locally, so no separate
  draft identity crosses the wire.
- The host incarnation.
- One outcome per requested component. It maps `ConfigurationWriteOutcome` through the existing closed workflow causes
  (`noBaseline`, `baselineMismatch`, `stagingRefused`, `preReadFailed`, `replacementRefused`, `heldBehindPlatform`,
  `heldBehindRuntime`, `preservationHeld`, `versionExhausted`, `superseded` and the unknown read-back reasons). It names
  the new baseline only for `persisted` or `unchanged`.
- The actual committed lifecycle values needed for causal draft rebasing, and an apply/start outcome per module; failures carry a closed `ControlFailureCode`.

A busy store slot is a capacity outcome, distinct from a persistence failure. The receipt is secret-free, so ordinary
request and operation lookup can carry the same metadata after a lost reply, without retaining any private body. Only this
receipt advances the matching draft's baselines.

**Read and reply.** `G` carries `PrivateEditorReadRequest`. `R` carries `PrivateEditorReply` with request correlation,
host incarnation and one answer: update admission, read observation or read refusal. Matchers refuse an unrelated request,
an unpaired answer, or an unexpected incarnation; only an explicit changed-incarnation refusal may name a different one.
No save receipt or mutation retry is hidden inside an observation read.

**Codec reuse.** One header grammar serves `Q`, `G` and `R`, with separate request and reply cap names.
The reader takes the expected kind and its cap, and it still refuses an oversize declared length before any body byte. The
same two-pass emitter writes replies, with `writeRuntime` and `writePlatform` unchanged, so oversize refusal still precedes
allocation. The same table-driven scanner, with new root tables and the existing wire mirrors, decodes them. There is no
generic JSON value tree, no second parser and no `Codable` on private values. Tiny secret-free `ControlAdmission` records reuse
their own sorted-key `Codable`; the private decoder verifies the exact member set against that canonical encoding, rather
than duplicating variant rules. This generic encoding path cannot receive private values.

The bridge retains one field mapping in each direction. Its observation preflight reuses `writeObservation` with a counting
sink to reject non-finite numbers and resource violations. That counts only the embedded value; the actual correlated reply
encoder owns the full eight-MiB frame check. No dummy request or envelope identity is constructed for validation.

**Migration obligations, not owner policy and not shipped defects:**

- Introduce one shared host incarnation across the new owner, the workflow and the service. `RuntimeHost` does not expose a
  `ControlHostIncarnation` yet, and `RuntimeConfigurationWorkflow` mints its own for its store contexts.
- Propagate the client's actual `requestID` into the store context on the new client path.
  `RuntimeConfigurationWorkflow.context(generation:)` mints a request ID per store call. That is correct for today's
  process-start facade, which has no client request.
- The headless request now carries exact component baselines. Integrate it by comparing those values inside the sole
  store; do not convert the namespace/version authority into an Int ordinal or mint a token in the bridge.

## Private channel concurrency

Decision 0021 already selects one global active private body/decode, refusing a busy peer before another body is
reserved. Implement that as its own transport lane, with capacity one and its own custody term. The ordinary 64 KiB caps,
the ordinary lanes' two-request-plus-two-reply charge and the per-module Stop lanes stay unchanged.

Reserve private capacity before the client maps or encodes a large body, and keep the reservation through reply
decoding and physical cleanup. A scoped exchange or single-use producer/consumer serves that requirement; an API that
accepts an already encoded eight-MiB frame reserves too late. The gate belongs to the host/service composition and is
shared across all its in-memory transports and connections, rather than minted by each transport initializer. No global
singleton or registry is implied. Completed frozen inputs that a write still owns remain separately bounded active
operation state until quiescence, as 0018 requires.

A pre-decode refusal cannot invent a correlated R reply: the private header has no request ID. An in-memory refusal before
encoding/sending is not-sent busy. After any bytes may have left a network client, a missing correlated answer leaves an
update's admission unknown or aborts a read; request lookup does not promise that an absent record means refusal.
The production socket's busy signaling remains for its own reviewed adapter. This adds no handshake or public/private
configuration halves.

An owner turn only captures copy-on-write values, tokens and intents, or admits. Encoding, reading and decoding run off the
main actor and off `PlatformWork`, so neither the owner nor helper and Stop cleanup effects queue behind a codec pass. The
[actual reply experiment](experiments/private-editor-codec/README.md) measures the implemented batched body copy: for a
7,487,875-byte frame, repeat read median fell from 925.7 ms to 0.86 ms with unchanged bytes, budgets and round trips. It
shows no established memory change. Encoding remains the largest codec step. Actual-host Stop/status latency during
transfer and store staging is service-profile work; the 16 KiB input budget does not bound growth/completion-copy work.

## Before the AppState switch

1. Select the production service profile below from actual-adapter measurements. The private observation/update/reply
   codec and fixtures are implemented separately; settlement receipts remain with workflow integration.
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

The [interactive admission alternatives](design-runtime-editor-admission-options.md) identify two
unselected multi-client/dependent-start policies. Keep the approved exact-revision and save-only
meanings; settle those choices before implementing private update/Start.

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

  The cap includes the complete header, envelope and terminator. The [actual-codec experiment](experiments/private-editor-codec/README.md)
  records a 7,487,875 B widest-string/count observation frame and a conservative numeric allowance of 7,499,714 B,
  leaving 888,894 B. The allowance is fixture-specific, not a universal bound on future fields or schema branches.
  New bounded fields require renewed sizing checks.

  Release lifetime checks held owner values and a separate client draft throughout encode/read/decode. Batching body
  copies reduced the measured repeat read median from 925.7 ms to 0.86 ms with no established memory change. Neither
  measurement proves real-host Stop/status responsiveness, which remains an adoption gate.

  The [decision](decisions/0034-private-editor-reply-frame-cap.md) preserves the smaller/split/larger alternatives and
  the [historical mirror](experiments/private-editor-reply/README.md) that informed the owner choice. The actual codec
  measurements supersede that mirror for the implemented observation shape; settlement receipts remain a separate shape.
- **Production service profile:** remaining queue, retained outcome/replay,
  subscriber, per-turn work, deadline and shutdown values are unselected. The
  existing coherent candidate is test-only; validate the actual host adapter
  before asking for shipping values.
- **Conditional later choices:** bind-new/repoint/retire listener handoff needs
  owner selection before changing current behavior. Whether a bounded #194
  applied-state expansion joins the release is also a scope decision. Neither
  justifies silently introducing independent effect groups or blocking an
  otherwise behavior-preserving host migration.

The implemented headless shapes and their fixtures precede host adoption. Receipt, preference/admin operation and
client-draft integration details remain review input. Implementations
must use the selected module boundaries and private channel, with no registry,
parallel writer, public test hook or new dependency.
