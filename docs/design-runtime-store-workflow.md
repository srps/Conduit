# Verified store and client workflow: architecture checkpoint

Status: reviewed with Claude Code through the owner's claude.ai Max subscription;
proposed APIs, with no store or client-engine implementation claimed. This refines
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
non-blocking DNS/intercept problem does not become a proxy-start refusal. At
base `fd1491e` the unadopted private bridge no longer runs the full `validate()`
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
not introduce a startup cap for platform/preferences sidecars or the journal, which
have no runtime-file budget here. Keep staged bytes only through the active
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

The bounded file boundary, the precision correction and the bridge validation
boundary are done at base `fd1491e`. The physical store seam and its read-back
outcome matrix come next, as one unwired building block with no startup or host
adoption. Add the sole leased writer,
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
