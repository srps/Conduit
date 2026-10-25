# Runtime service and in-memory transport: agreed implementation shape

Status: source-reviewed by Codex and Claude Code through the owner's claude.ai Max
subscription, 2026-10-25 local date. This implements 0013/0014. No new product
policy or shipping resource profile is selected. PR #231 provides the framed
client; this slice supplies a working service over an injected command owner.

## One owner and a working engine

An internal MainActor command-owner protocol supplies current safe projected
state, synchronous admission/fencing and deferred execution of the five existing
commands. The service owns only bounded admission/outcome/observation metadata.
The actual RuntimeHost remains the eventual intent/lifecycle owner; no competing
ConfigurationWorkflow or owner-generation counter is introduced. ConfigurationStore
owns persistence facts only and is independently implemented.

Reserve provisional capacity, call the synchronous owner admission (which starts
no effect), finalize the ledger/pending record, then return acknowledgement and
schedule bounded deferred execution. Even synchronous effect completion must find
a finalized ledger. Stop slots are reserved per ControlModule and never coalesce
different modules. No Start wire command is invented. Actual host adoption must
fix Stop-before-recovery admission while preserving existing Start ordering and
the twin rule. Fake-owner tests are not that host proof.

The same retained request ID and semantic fingerprint recovers its admission;
a changed payload conflicts. The budget is excluded from that fingerprint.
Unretained IDs return unknown/notRecorded, which means no retained record, not
never admitted. Expired history is reported only when bounded proof metadata shows
the revision was captured and its rows were evicted. Anything unproven is `notCaptured`, never a false expiry.
No tombstones or exactly-once/mutation-replay guarantee is introduced.

## Framed endpoint and reservations

Decode once through one byte front door, classify the work lane and take a finite
reservation, then hop to the owner. Ordinary traffic, status and per-module Stop
have independent capacity. No direct UI shortcut or second JSON parser is added.
A gate is claimed before owner admission. Deadline/cancel before claim is provably
not sent; afterwards admission may be unknown. First resolution wins.

A caller ending its wait does not free queued work. Reservations survive until
owner hops, cleanup and timer tasks actually quiesce. Repeated timeouts against a
parked owner cannot accumulate queued closures. Stream capacity survives until
owner removal. Each stream has one pull and bounded wait/timer state; cancelled
or timed-out pulls consume no frame. A transient wait-capacity refusal must remain
typed and nonterminal if it consumes nothing. Timer cleanup is part of capacity,
not merely a Task.cancel call. Callbacks, continuation resumes and Task cancellation
run outside leaf locks.

## Request budget envelope and aliases

Every request carries one mandatory budget in its envelope, beside the correlation. It is never a field of a command
body. The budget is the caller's remaining time in whole milliseconds, read once per call from the one absolute
deadline, so a nested call takes what remains and never a fresh budget. The receiver derives its own deadline on
arrival as the earlier of the caller's absolute deadline and arrival plus budget. One timer enforces that deadline.
A budget that ends before a claim answers with a typed refusal: a rejected admission for a submit, and
`deadlineExpired` for the reads, a subscription open and a page. Zero is valid and is never malformed. A budget that
ends after a claim never cancels admitted work; the caller's wait ends as admission unknown, and lookup recovers the
outcome. The budget is excluded from a request's fingerprint, and a refusal is never recorded. A stream `next` has no
request and no budget. Private configuration keeps its own budget contract.

A request alias keeps a fixed-size fingerprint of the command, never its body, and it expires from its admission. Aliases
are evictable within their partition and never pin an operation. An expired or evicted alias answers not recorded, while
an operation that is still pending stays pending.

An encoding failure is never silent. The service reports the failing site to the owner as a closed `ControlServiceFault`
(`submitCommandNotEncodable` or `outcomeNotEncodable`), which carries no command body and no error text, and then refuses
the request as `internalFailure`, or substitutes the measured internal failure for an outcome. The owner is the canonical
diagnostic producer, so no second event authority exists here. The fault is staged as data and delivered after the
settlement or refusal is complete, so the owner reads a coherent state. The production host's emitter remains an adoption step.

## Observation and pages

Baseline, event high water and registration happen in one owner turn without an
await or a snapshot callback under a lock. A bounded ingress schedules one drain
hop per batch, with count and byte work budgets. Replay is retained and chunked;
it is not disabled for the first implementation.

Event batches use consecutive event positions. Cursorless operationFinished
frames do not consume event cursors. A separately bounded ordered control log
uses event-boundary metadata and explicit resync if a reader falls behind; outcome
lookup retention is independently bounded. Full snapshots coalesce in one latest
slot. A terminal has reserved/sticky capacity.

An ingress-loss marker reserves a private cursor position, without fabricating a
wire event. Crossing it yields observationLoss/resync, not a false expiry. This
also distinguishes a new post-loss baseline from an old one at the prior cursor.
Normal event batches never cross the gap marker. Resume.from is the first wanted
cursor, inclusive; callers use a checked last-consumed plus one. Cursor zero is a
bootstrap sentinel, not an expired emitted record. Future cursors are refused.

Collections retain bounded immutable projected rows per revision. Bound revision
count, rows, per-revision bytes, total retained bytes, page rows and ages. Reuse the
existing projection/packer. Over-budget capture reports honest unavailable with
totals where known, never a truncated collection. An unavailable page reply has
no fabricated revision. Its optional `knownTotal` is the snapshot's exact total for
the current collection, or the total a retained proof recorded, and it is nil when
no proof states one. Each row set is measured through one shared bounded projection
(`ControlRowBudget` in ConduitShared, `projectRows` in ProxyControlBridge): the count
is checked before any row is mapped, and the encoded bytes before each row is kept.
A capture whose exact total is past the row bound is refused before the owner projects
a row. The owner's rows must match the snapshot's kind and total in the same turn. Retained superseded pages report staleness. A revision with bounded proof of row
eviction reports expiry, and anything unproven reports `notCaptured`. Stable upstream UUIDs remain their identity.

## Limits, types and verification

All limits are finite, explicit and validated; fixture values are not shipping
defaults. Check sum/product/counter overflow. One bounded retention janitor sweeps
bounded work; it does not duplicate caller deadline handling or create one Task
per retained entry. Encoded byte accounting is not a process-RSS guarantee. Each lane reservation is bounded by two request-sized values, the
caller's frame and its decoded message, plus two reply-sized values, the refusal and one answer, because the request values
survive the await. The derivation is in the runtime checkpoint.

Minimal unshipped-v2 refinements express already-selected states: changed
incarnation and request conflict rejection, subscriber limit, local transport busy,
observation loss and a revision-free unavailable page reply. Reads also answer
closed codes: `changed_incarnation` for another incarnation, `internal_failure` for a
projection or pack that the host could not complete (never a corrupt transport), and
`frame_too_large` when a row does not fit the caller's frame. An offset past the known
total is `invalid_value`, decided before any capture. The rowless page statuses carry
no rows, and the packer produces only current and stale pages. Keep v1/helper
unchanged and preserve codec sizing, malformed-value checks and rejection order.
No unknown informational wire record becomes a domain producer escape hatch.

Drive production admission, subscription/replay and transport gates against three
independent bounded reference models. Cover stalled owner plus repeated timeout
and refill, cancelled timer cleanup, immediate effects, duplicate/conflicting IDs,
per-module Stop under ordinary/read load, baseline atomicity, event gaps,
mid-catch-up eviction, control-outcome overflow and page retention. Report actual
bounds and shortest replayable counterexamples; exhausted budgets fail. Adapter
fault witnesses are not source mutants unless source edits were actually tested.
The collection ledger has two bounded logical models: one kind, 22,620 exhaustive
sequences of depth 1 to 4 plus 100 walks, and two kinds with unequal row sizes,
refused captures and janitor batches of 1 and 3, 69,904 plus 100. Both were written
from the same design as the production ledger, so they are not independent
specifications, and they claim only their stated bounds. No source mutant of the
cross-kind eviction has been executed.

The actual host adapter, full configuration event family and writer/shutdown
adoption remain separate integration steps. pm-sim keeps its current target graph;
a new Shared wire scenario checks representations, while ConduitTests drive the
internal production service through @testable. No real-machine, global fairness,
private-transfer or release-readiness proof is inferred from this slice.
