# Verified store and client workflow: architecture checkpoint

Status: reviewed with Claude Code through the owner's claude.ai Max subscription.
The store core below is implemented and checked in focused tests (2026-10-25, see
[the verification note](verification-configuration-store-2026-10-25.md)). The client
engine is implemented but unadopted; host adoption and the apply path remain
unimplemented. This refines
implementation planning for decisions 0014, 0015, 0017 and 0018. The owner selected
holding a mixed apply in [0025](decisions/0025-hold-mixed-configuration-apply.md);
the affected apply path remains unimplemented.

## One path and clear owners

| Owner | Responsibility |
| --- | --- |
| ConduitShared | Existing private values/codec and one RuntimeClient contract; safe phase/outcome values, no domain model or disk authority |
| ProxyControlBridge | One mapping between frozen private values and domain values; format/resources here, runtime eligibility at its owning gate |
| ProxyKernel persistence | File grammar, migration, exact schema-two staging and equality; no control DTOs or runtime command coordination |
| PlatformMac | OS file/lease effects behind protocols and fakes; physical effects do not run on a control actor |
| ConduitRuntime workflow/store | One intent owner, one serialized configuration writer, verified component results and apply fences; immutable input passed to the existing host |
| AppState | Drafts, presentation and app administration; retire the direct save path and temporary editor baseline as the shared workflow is adopted |

The workflow is one operation through those owners, not an additional AppState
coordinator. A store worker serializes physical I/O; it does not allocate a newer
intent generation after an await. The control owner captures that generation
before suspension and rechecks it, the host incarnation and Stop/Quit fences
before applying a completion. `expectedOwnerGeneration` is the client's observed
intent generation, not another independent counter. A lease lifetime is not an
intent generation.
RuntimeActor adoption must move the selected control cluster together; another
actor alone does not make an awaited operation atomic.

## Storage acceptance and runtime eligibility

Preserve the existing Settings repair baseline: a representable draft with an
invalid listener port can be saved, reported and held from runtime apply. A
non-blocking DNS/intercept problem does not become a proxy-start refusal. In
merged PR #228 the unadopted private bridge no longer runs the full `validate()`
gate. It refuses only what the wire cannot carry or an approved ceiling forbids,
and it carries bounded editable Int port drafts through one private request. That
is transport and storage, not runtime eligibility and not authority to run:
schema-two staging decides what may be stored, and `startBlockingProblems` with the
subsystem gates decide what may run.

Format/resource admission and exact schema-two staging decide whether values can
be stored. Existing `startBlockingProblems` and subsystem gates decide what may
run. No new normalization, invalid-draft refusal policy or parallel save-only
transport is selected. Saved, held and applied remain separate outcomes.

| Existing validation class | Storage | Runtime apply |
| --- | --- | --- |
| Grammar, resource or exact-representation refusal | Refuse before writing | No new apply |
| Unrepresentable duration | Refuse under 0023, including derived runtime budgets | Start-blocking |
| Representable invalid duration, port, limit, host or conflict | Preserve existing saveable repair draft | Start-blocking |
| Intercept pattern/IP, transparent-proxy IP or bypass grammar problem | Save if format/resource staging permits | Preserve existing non-blocking classification; the owning surface still validates |

## Inputs and observable results

Extend the existing RuntimeClient with a private configuration submission rather
than introducing a second client. One request ID follows saving, runtime admission
and settlement; internal phase IDs stay distinct. Ordinary lifecycle commands
remain on their existing small control frames.

Only the store mints component receipts after authoritative read-back. At open,
verify existing loaded components and establish initial revisions for this
incarnation; no receipt from a previous process is reused. Missing files retain
an explicit absent/uncommitted baseline, rather than a claim that defaults were
persisted. An operation requiring durable defaults commits them first. A commit then
replaces a component receipt only after its own verified write. Clients
supply expected revisions, never authoritative receipts. A receipt identifies
writer/incarnation, intent generation, component and revision; it is not proof of
power-loss durability. Keep content fingerprints private to the implementation,
away from status/events/wire outcomes. An ordinal is correlation, not authentication.

Bound runtime-file self-write read-back by `max(staged byte length, observed prior
byte length)`, with the reader's single probe byte added by the reader itself and
no second probe. The observed prior is what the pre-read reported, and both counts
are within the approved 8 MiB budget. The bound must include the prior, because a
write that throws and leaves a larger prior unchanged still has to read that prior
back in full, so the result is verified not-persisted rather than unknown. The
pre-read uses the approved budget as its ceiling, and the read-back bound never exceeds it. This does
not apply the runtime-file ceiling to sidecars. Decision 0026 separately caps
platform/preferences startup reads and staged output at 128 KiB; journal policy
remains separate. Keep staged bytes only through the active
write/read-back verification that needs them, then release them. Compare authoritative read-back with the exact staged input; distinguish
verified persistence, verified non-persistence and unknown. A caller timeout or
cancellation only detaches its wait. Started physical work and its lease survive
until quiescent or process exit. Lease release also requires journal/runtime
writers to have quiesced; configuration-worker idleness alone is insufficient. The shutdown owner must
account for launch recovery, runtime lifecycle lanes, reconciler passes,
PlatformWork and each manager's serialized work, repair/reapply retry tasks and
their journal writes. Include AppState's remaining twin writers until removed;
prove that new work cannot enter this set after its shutdown fence.

A safe outcome separately describes component persistence, runtime admission and
apply: for example, persisted runtime plus unknown platform plus apply held for
missing verification. Preferences have their own result and cannot veto an
independently committed runtime update. No outcome contains URLs or config values.

## Capacity and retry

Keep one active private transfer/decode globally, with no queue of full private
bodies. Bound active operations, waiters and terminal metadata separately, and
retain no full configuration body merely for terminal request lookup. Concrete
item/byte/time limits must live in the validated engine configuration before
implementation; this draft adopts no unmeasured terminal-history default. Release a
sender's encoded body when transport no longer needs it; lookup does not require
retaining replayable mutation bytes.

A retained ID/content match can recover a recorded result within its bounded
history. Eviction produces unknown history. It does not establish exactly-once
execution or safe mutation retry after eviction. Clients never blindly replay a
mutation. Fingerprints are identity checks, not writer authority. Read-before-write
checks may detect an external edit but cannot exclude a nonparticipating editor
racing the replacement; the advisory lease excludes cooperating writers only.

**Selected conflict policy:** [0027](decisions/0027-refuse-external-configuration-edits.md)
requires an ordinary save to refuse observed byte changes since the verified
baseline, preserving the file/draft and holding the new apply until explicit
reload/review. Formatting-only edits conflict. A failed pre-read cannot authorize
a replacement. Reload uses the same owner and cannot bypass eligibility or
Stop/shutdown fences. This is a planned store check, not filesystem compare-and-swap;
nonparticipating editors can still race after it. The owner selected this over
legacy overwrite authority on 2026-10-24.

## Apply granularity: whole mixed unit selected

Existing `RuntimeReconciler.reconcile` advances runtime and platform baselines in
one pass. A change to a listener, PAC, DNS entries or intercept rules can also
change machine surfaces. Required receipts follow those effects, including a
previously verified unchanged component; no rewrite is required merely to retain
its receipt. Today's app may still reconcile after a platform write failure, so holding a mixed
apply would change that failure behavior. A save of changed platform values must not be mistaken for verification
of those values when it failed.

Consider one commit that changes a runtime value and a platform-management flag.
The runtime file verifies; the platform write fails or remains unknown:

- **Hold the mixed apply as one unit (recommended first).** Report the partial
  durable state and keep running the prior applied configuration until the whole
  required input verifies. No rollback claim. This is the smaller implementation
  over today's reconciler, and follows save-before-apply for the combined input.
- **Split into independently verified effect groups now.** Apply only effects
  whose complete receipt set verified. This needs an explicit dependency plan,
  per-group baselines and partial settlement/repair tests; handing the current
  reconciler a mixture of old/new fields is insufficient.

Effort comparison for owner review: independent groups add roughly two or three
substantial slices now: dependency planning, per-group baselines/repair and
partial-settlement model/harness/client integration. Most of that work is needed
in either timing. Deferring it adds replacement of the whole-update apply gate,
while the store, receipts and transport remain reusable. This is a scope estimate,
not a validated calendar commitment. After reviewing this comparison, the owner
selected holding the mixed apply; independent groups remain a revisit option.

A runtime-only update needs its runtime receipt and any existing verified platform
input its effects depend on. UI preferences remain independent under both options.
The selected Stop policy still requires immediate fence admission without waiting
for either save. Current RuntimeHost waits for launch recovery before admission;
fix and test that ordering during workflow adoption. Quit
still does not persist a disable. This choice changes no listener-handoff policy.

Keep typed results capable of reporting held and partial persistence under either
option. Later effect grouping can replace the apply plan behind that boundary;
it must be a deliberate tested refinement, not inferred from individual saved flags.

## Verification and sequence

The runtime boundary, exact schema-two staging and bridge correction merged in
PR #228; the runtime physical replacement seam/model merged in PR #229. The
shared sidecar boundary merged in PR #230. These are building blocks, not the async
store. Implement the selected external-edit check (0027) alongside expected-prior revisions.
Add the sole leased writer,
intent/revision fencing and bounded metadata, followed by the client workflow and
host adoption. Startup must acquire authority before migration/recovery, and every
journal/configuration writer must participate before shipping lease enforcement.

Drive actual production adapters against an independent bounded model. Cover
rename followed by error, unknown read-back, old queued writes, Stop during save,
late receipts, mixed failures, timeout, lease release and incarnation changes.
Inject adapter faults that mint a receipt before read-back, skip a fence, release
while writing or hide a partial commit; require short replayable counterexamples.
Also cover saved invalid-port drafts held from apply, saved non-blocking problems,
bridge mapping of both, second-body busy refusal, retained-ID content conflicts
and Stop admission while a write is blocked. Retain actual fake-machine and
headless scenarios alongside the model. No model,
source review or hash comparison alone proves physical shutdown or serving-app
behavior. Full workflow and owner validation remain separate evidence.


## Agreed next store-core slice (2026-10-24)

Codex and Claude reviewed the actual persistence, lease, queue and module graph
through the owner's claude.ai Max subscription. This implements accepted decisions;
it introduces no additional lifecycle authority or shipping engine defaults.

- **ProxyKernel:** extract the existing loader into one pure entry over frozen
  runtime/platform/preferences bytes, absence and existing typed read errors. The
  existing file loader delegates to it and retains its migration/staging/failure
  behavior. No PlatformMac identity, lease or control DTO enters the kernel. The
  same component decode helpers and exact stagers serve both paths.
- **PlatformMac:** generalize the existing verified replacement, not its algorithm.
  A resolved file role selects the existing runtime/sidecar limit; journal and
  foreign roles are refused. One pre-read checks a supplied opaque baseline, then
  the existing write/read-back classifier runs. Observation and verify-only use
  the same bounded reader. Identity is a private length plus SHA-256; descriptions
  are redacted, no identity is Codable or sent in ordinary results. Digest
  collision freedom and exclusion of after-check editor races are not claimed.
- **ConduitRuntime:** an internal MainActor store owns parsed current values,
  private component baselines/versions and one active I/O slot. All three files
  use that slot; preferences are an independent operation, not another writer.
  It retains the writer-owned StateRootSession and reports its own busy/idle state. It never releases
  root authority or claims journal/runtime quiescence. Blocking reads, parsing,
  staging, hashing and writes run through dedicated PlatformWork.

The internal API provides open/reload, a runtime/platform commit, an independent
preferences commit and verify-without-rewrite. Runtime/platform candidates stage
before their first write; a known staging refusal starts no coupled write. Both
commit entry points use one private physical path. Per-file physical failures
remain partial, with no rollback or automatic retry. Existing legacy migration
semantics remain in the file-loader wrapper, not copied into the store.

Open/reload adopt parsed values and baselines from the same observation. Missing
files remain explicitly uncommitted. A malformed/unreadable refused startup input
cannot become an authoritative baseline or an excuse to overwrite it. Explicit
reload changes an internal file-baseline version when observed bytes change; it
does not reinterpret machine-effect ControlConfigRevision/PrivatePlatformRevision.
The existing loader supplies legacy/default launch-at-login values. No new
missing-sidecar refusal or implicit bridge-local login-item value is introduced.
Preferences keep existing whitespace/default normalization and the raw UTF-8 cap;
0023's exact runtime-duration rule does not become an exact-preferences rule.

Commit results contain persistence facts and echo caller context. The store has
no owner-generation counter, Start/Stop/apply methods, terminal request ledger or
configuration-body queue. The future actual workflow checks its one live intent,
incarnation and per-module Stop fences before apply. An explicit newer Start/Enable
can supersede Stop; an ordinary saved edit cannot. Store-core tests do not claim
to establish those unadopted host fences.

Verify the production store against an independent bounded model for open/reload,
conditional writes, stale baseline tokens, busy refusal, missing files, read
failures, formatting/unknown-field edits, partial results and unchanged verification.
Keep the physical classifier matrix and scratch OS witnesses. pm-sim exercises
the physical mechanism through PlatformMac; it does not gain a ConduitRuntime
dependency. The complete configuration event family and one owner emitter move
with actual workflow/host adoption. This core reports typed persistence facts
and does not invent a parallel configuration/lifecycle coordinator.

Measure actual memory/copies during composition. Compact retained identities and
nominal Data lengths alone do not establish RSS, transport capacity or Stop fairness.

### Implemented store core (2026-10-25)

- Ownership: `ConfigurationComponent` is the kernel's existing identity. The loader
  and `ConfigurationLegacyFallback` own each refused legacy component's classification
  and fixed text. `VerifiedConfigurationFileReplacement` owns the observation, the
  baseline pre-read and the write with read-back. `ConfigurationStore` owns the parsed
  values, one baseline record and version per file, and the one busy slot.
- Absence: a missing file is an explicit absent baseline. A missing sidecar beside a
  present runtime file takes that component's valid legacy value when the runtime file
  carries one, and the defaults when its keys are absent. Neither case warns. A malformed
  legacy value refuses only that component, with a typed fallback.
- Latch: a conflict, an unknown read-back or an observed change latches the component
  until a reload. A latch does not change the version. A reload after a latch always takes
  a newer version, even when the bytes are the old ones, so every token issued before the
  latch stays refused. A version at its maximum refuses a write before any I/O.
- Partial results: the platform file is written first, and the runtime file is written
  only after the platform verifies. An unverified platform holds the runtime write. A
  failed write keeps what landed, with no rollback and no retry. Each component's authority
  is decided on its own: a refused file keeps its own reason, and an authorized one is held
  behind the other (`heldBehindPlatform` or `heldBehindRuntime`).
- Legacy preferences guard (decision 0026): a runtime rewrite that would drop decoded
  legacy preference values is held until the preferences sidecar verifies. The sidecar is
  re-verified in the same physical step, after the platform verifies and immediately before
  the runtime replacement. The hold is typed (`sidecarAbsent`, `noAuthoritativeSidecarBaseline`,
  `sidecarChanged`, `sidecarUnreadable`, `refused`), and only a changed sidecar latches.
  A null value creates no dependency. A malformed value is not a dependency, so the coupled
  commit is not vetoed. The explicit `commitPreferences` save is the migration path. A
  sidecar changed after the check is not excluded, and the tests pin that limit.
- Not implemented: the Start/Stop fences, the apply path and the mixed-apply hold, the
  RuntimeClient configuration submission, the configuration event emitter and
  host adoption. Startup lease acquisition is now implemented; Those remain owner adoption work.


## Production-adoption checkpoint (2026-10-25)

Update after the display review: 0029 is implemented and verified on the unreleased
v2 contract, and the owner selected 64 KiB replies/stream frames in
[0030](decisions/0030-ordinary-runtime-reply-frame-cap.md). The complete widened
baseline measures 49,376 bytes including LF. The remaining coherent service
profile, actual-owner scheduling and the integration work below still gate
production adoption. This does not move the semantic store or introduce a
parallel writer/client path. See [display verification](verification-runtime-display-2026-10-25.md).


Reviewed with official Claude Code through the owner's claude.ai Max subscription,
against merged startup/log protection (PRs238/239). This checkpoint preserves the
selected owners; it does not select presentation limits or shipping client defaults.

The next production cut connects AppState to the real RuntimeHost through the
selected typed RuntimeClient and its in-memory framed transport. Configuration
workflow adoption moves with that cut. Delete each replaced save/reconcile/lifecycle
path; another writer-only AppState coordinator or transport bypass would postpone
convergence. Under [0031](decisions/0031-incremental-runtime-development-single-activation.md),
DNS→tunnels→proxy development and parity/model verification proceed incrementally,
then AppState switches once and its replaced runtime/save paths are deleted
together. Each development slice names implemented responsibilities and remaining
parity gaps; activation proves there are no overlapping writers or runtime effects.
The table below is the target ownership, not a claim of completed activation. The existing ConduitRuntime dependency condition permits the app's
edge when it actually adopts the host. The v1 control socket belongs to pm-proxy;
ConduitDaemon has no control socket yet. A production daemon socket is later work.

| Owner | Responsibility and boundary |
| --- | --- |
| ConduitRuntime store/workflow | Configuration semantics, intent ordering, component baselines/receipts and save-before-apply eligibility. App-owned during convergence, daemon-owned later. |
| ConduitRuntime RuntimeHost | Runtime lifecycle, journal and machine reconciliation; consumes the exact verified immutable input. It does not become another configuration writer or re-read a path to substitute newer values. |
| ConduitRuntime composition | Constructs and retains the sibling workflow/store and host behind the typed client; adds no policy, queue or second intent owner. |
| PlatformMac StateRootSession | Private lease, resolved plan and narrowly scoped file authority; no raw lease accessor. |
| AppState | Editor drafts, presentation and app administration; invokes the client and AppKit Quit policy. |

The consumed construction seam now keeps the semantic store in ConduitRuntime. A
session-owned configuration replacement operation in PlatformMac accepts the
existing ConfigurationComponent identity (runtime/platform/preferences), staged
bytes and expected private baseline, and delegates to the existing verified
replacement primitive with its private lease. It resolves the file from the session's
plan; callers cannot provide a fabricated foreign path or a journal component.
The store retains the session instead of a naked lease. Existing bounded readers,
classifiers and StateFileAccessing fakes remain the physical path. Exact method
syntax and existing result/failure types are implementation details; this is no
new generic lease callback, dependency cycle or store relocation.

Adoption replaces AppState.persistConfiguration's three direct writers, its old
editor baseline/save-to-reconcile gate, synchronous termination saves, and each
migrated twin lifecycle. RuntimeHost's verified-input path replaces its reload
re-read. Startup migration/seeding must be inventoried separately under the same
session, complete before the store adopts baselines where retained, and never
remain a later save/reload bypass. Platform-journal authority remains distinct.

Stop fences at admission before waiting for recovery; physical cleanup still
respects recovery ordering. Quit uses an asynchronous drain under one total
remaining monotonic budget (AppKit terminateLater is a mechanism), with the fence
first and no durable disable merely to exit. A drained PlatformWork queue alone
cannot prove the logical store operation finished: coupled writes resume on the
owner between phases. Report physical and logical outcomes honestly and retain
process-lifetime authority for started work. Deadline sizing still needs evidence.

Do not introduce a Start-last-applied fallback after a failed/unknown enable.
Ordinary edits/enables still require verified eligible input; Stop/Quit remain the
selected exceptions. Keeping an already-running prior configuration under0025
is not permission to admit a new Start using an invalidated receipt.

The [display-text policy](design-runtime-display-bounds-review.md) is now selected
and implemented, and [0030](decisions/0030-ordinary-runtime-reply-frame-cap.md)
selects the reply/stream ceiling. Full framed client adoption is still gated by
the remaining coherent capacity/retention/work/deadline profile and its measured
behavior. Test profiles cannot silently become production defaults. No prep-only
interface is implemented merely to bypass that gate.

For the later reload slice, confirmation before discarding a draft implements
0027's explicit reload/review, with cancel preserving it. The owner subsequently
selected explicit disk reload-and-reconcile in decision 0032. Normal editor reads
remain in-memory/no-apply, and no client may discard another client's draft.
Production adoption and RuntimeActor migration remain separate implementation
work; this checkpoint does not claim either.


## Next workflow contract checkpoint (2026-10-25)

The session/store capability is implemented and focused verification passes.
Actual host/workflow/client adoption remains open. The editor contract below is
an API refinement for review, not an implemented private read protocol or a
selected reply budget.

Expected-prior component revisions already follow from 0015/0018. Two editors
can observe durable D5 and runtime-view R5; one saves an invalid repair draft,
creating durable D6 while runtime-view R5 stays unchanged. Checking only R5 or the
server's current baseline would let the other editor overwrite that draft. A save
must compare the original client-observed durable baseline. Ordinary snapshots
cannot silently refresh the draft's baseline tokens.

Proposed private editor observation: capture current values and runtime/platform/
preferences baselines in one owner turn, without re-reading disk; pair them with
the host incarnation and current intent generation. Preserve the store namespace,
component and version when matching a supplied expected revision to a token the
store actually issued. A version alone is not an identity across fresh stores.
This needs no registry or retained observation history. Host incarnation, store
baseline identity, runtime-view revisions and applied facts have different roles.

Absent/uncommitted, current verified, last-known without authority and unavailable
inputs need closed states. A missing file's defaults are not verified persisted;
required defaults commit first through the same workflow. Conflicts and unknown
writes keep the selected reload/review gate. A consistent last-verified view can
be stale by its next use, so admission rechecks it; whether a private read is busy
is a capacity decision rather than a substitute for those checks.

Private values reuse the explicit runtime/platform bridge and codec. Preferences
need an equally explicit private representation: their browser URL can contain
tokens. Values remain off ordinary status/events/outcome lookup. The new reply
direction, its full encoded ceiling and lifetime/copy measurements are still
unimplemented and unselected. Do not silently borrow the request's 8 MiB cap or
add an envelope allowance to it. Ordinary stamp metadata additions also require
bounded sizing under 0030 before adoption. The v1 status counters stay unchanged.

The owner selected explicit disk reload-and-reconcile in
[0032](decisions/0032-explicit-reload-and-reconcile.md). A normal private editor read performs neither disk
I/O nor runtime apply. Client-owned dirty drafts cannot be discarded by another
client's reload event.


## Next consumed host cut: reviewed shape (2026-10-25)

Claude and Codex reviewed this shape against the actual host/store/daemon source.
Decision 0032 selects reload-and-reconcile. The simulator dependency exception in
[the host simulation review](design-runtime-host-simulation-review.md) is still
an owner gate; no new workflow implementation or simulator access is claimed.

- **Store:** retain one physical-work slot, existing frozen reader/decoder and
  verified replacement. Preserve ConfigurationOperationContext. Add an explicit
  allowMissing input for startup compatibility and a narrow Sendable write claim
  provided by the workflow. Check the claim inside the worker immediately before
  replacement, after any preservation read; do not hold its lock across I/O.
  Once replacement starts, finish read-back and record its persistence facts even
  if intent changed. Return an exact verified runtime/platform pair only when
  both required inputs verify; never treat the store's independently updated
  per-file values as a coupled apply candidate.
- **RuntimeConfigurationWorkflow:** one internal MainActor owner per host,
  privately holding the store. Own bounded, non-wrapping intent generations,
  synchronous Start/Stop admission and the session Stop fence. Start admission
  happens before launch recovery suspension; preparation after the join checks
  that same admission and cannot clear a newer Stop. Required absent defaults
  commit through the store before Start. A runtime Stop does not revoke an
  independent preferences operation. No parallel intent counter lives in the store.
- **RuntimeHost:** consume the workflow in an asynchronous open factory before
  constructing orchestrator/reconciler baselines. The daemon's existing startup
  migration stays before store observation. A reload facade delegates to the
  workflow, replacing the migration-capable reload body. Push verified eligible
  input before starting listeners rather than relying on a prior reconcile.
  Reconcile only eligible current input; held input never becomes the reconciler's
  requestedConfig or retry baseline. Keep v1 host config and configGeneration
  aligned with their existing host-view meaning; store durable tokens are separate.
- **Reload settlement:** one store slot excludes overlapping loads/commits.
  A stale observation may remain an honest store observation, while workflow
  apply is held and newer Start/Stop intent wins. It cannot update the applied
  host view, retokenize a client's draft or authorize later retry. Whole decode
  refusal retains last-known values without new baseline authority; representable
  validation problems are adopted as repair drafts with held apply.
- **Events:** a complete new typed config.workflow.* family belongs to the
  workflow, with closed phase/component/reason fields and derived detail. Extend
  the closed-namespace gate and exhaustive payload/control mappings. Preserve
  unaffected legacy config.* producers and pm-proxy behavior. Remove the old
  host reload event producer in the same implementation; retire replaced app
  workflow producers at final activation. The two runtime owners do not execute
  competing paths after activation.
- **Verification:** focused store/host integration tests and an independent
  bounded workflow model exercise admission, worker claim, physical completion,
  resume checks and apply. Cover Stop during recovery/read/write, stale reload,
  a verified platform step followed by revoked runtime, invalid/missing inputs,
  no reload writes and required-default commit before Start. Report exploration
  bounds and injected-defect sensitivity. Real-host pm-sim coverage depends on
  the explicit simulator choice; old physical/client-fixture scenarios do not
  count as adopted-workflow coverage.

Private editor observation/reply encoding and its measured ceiling remain a later
separate cut. This host/store cut neither silently adopts the 8 MiB request cap
for replies nor selects production queue/retention/deadline defaults. AppState
activation and the whole-control-cluster RuntimeActor move remain later gates.
