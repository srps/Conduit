# Explicit runtime effects and real-host simulation: verification

Status: all 40 local workflow checks pass on stable source, with independent final
Claude review finding no material blocker (2026-10-25).
This implements decision 0033's composition boundary; actual configuration-store/
workflow adoption, private editor replies, AppState activation and RuntimeActor
isolation remain open. It is not release readiness.

## One composition boundary

RuntimeHostEffects requires explicit privilege/helper, credential, Kerberos/GSS,
PAC, process/probe, network observer, VPN-provider and home/resolver inputs.
ConduitDaemon selects production adapters; test and simulator composition selects
fakes and scratch paths. There is one host implementation. The package dependency
from pm-sim to ConduitRuntime is consumed by the runtime-host-effects scenario.
No public test hook or store/lease accessor is added.

The existing diagnostic event log and writer sink are bound before invoking the
privilege factory, which creates one helper instance for both roles. No second
event buffer is introduced. The VPN factory receives current timing readers.
Explicit system GSS selection retains the existing auth factory's KDC-recovery
and structured-event binding; injected GSS replaces it for isolated runs.
TunnelResolverManager now requires its directory, including the app's existing
caller. This is wiring, not AppState activation.

## Cleanup ordering and bounded work

The focused witnesses exposed diagnostic producers that could finish after a
flush. settleStoppedEffects joins the captured credential warmup and admitted
observer-delivery cascade, with one join slot and a caller-supplied monotonic
deadline. Its closed outcomes distinguish settlement, deadline, active runtime,
supersession and busy. No raw task/delivery handle crosses the package boundary.
The internal computed join-count probe is available only to testable tests.

Stop, status, readiness and ordinary diagnostic flushing do not await a blocked
credential prompt. A deadline ends waiting, not the join. The join retains the
root session through its producer work. The composition owner must retain the
host/root through the final diagnostic flush; a producer join does not prove all
file writes or future OS callbacks quiescent.

CredentialManager's background warmup now coalesces at its single producer:
one active worker and one pending latest request, without a task chain or an
unbounded queue. Each run reads current identity through the existing provider.
This shared change affects AppState as well as RuntimeHost; the credential
read/cache and authentication algorithms are unchanged.

The scenario stops, settles, flushes, drops the host and proves root reacquisition
before removing scratch. Unknown settlement/flush pins one actual host until
process exit, retains scratch and refuses another run before allocation. This is
a single bounded simulator failure-retention slot, not production ownership state.
Setup failures use the same release/close-result path. Reacquisition has its own
scope, so its lease closes before directory deletion.

## Executed focused evidence

- The focused wrapper passes 97 tests, zero failures, and the actual RuntimeHost
  runtime-host-effects scenario. The scenario exercises a contended bind,
  retry/probe, successful restart, fake-machine proxy/environment effects, Stop,
  producer settlement, diagnostic confirmation and lease/root cleanup.
- Positive unit witnesses cover helper factory events persisted exactly once,
  dynamic VPN timing providers after reload, injected GSS and PAC use, credential
  isolation and scratch-only tunnel resolver scanning.
- Deadline, busy, Start/reload supersession and producer coalescing are tested with
  a gated secret-store fake. Concurrency tests observe actual join admission via
  a bounded handshake rather than assuming a Task.yield scheduled it.
- An independent blocked-active batch oracle drives the actual CredentialManager:
  40 exhaustive request batches of length zero through three, plus 16 fixed-seed
  eight-request batches, 56 traces total. It checks read and sink outcomes after
  release and awaits the first returned producer handle.

This model does not explore arbitrary thread interleavings or general credential
cache behavior. It is not the still-required adopted configuration-workflow model.
The two-identity pending case and simulator unknown-shutdown pin remain coverage
limits; the latter is source-reviewed, not an executed fault witness.

## Mutation sensitivity and provenance

Claude temporarily kept the first pending warmup instead of the latest. The model
and manual test failed; the original line was restored and the focused run passed.
The first mutation run retained only a summary, not its full overwritten log.

Codex independently reproduced the same source variant using the exact model
filter, archived both raw failure and restored-pass logs, and verified byte-for-byte
restoration. Original/restored CredentialManager SHA-256 at the mutation checkpoint
(the current file has a later documentation-comment change):

177b74f22387161b95e36e8c4c59567063fc27f5e17ee6d967255cd8aafc7c6c

Mutant SHA-256:

b34f09348ec23f0439d12a4a76eab7957d0a2d3edad5d0e270914523d0728e40

The mutant exits 1 with model failures; restored source exits 0.
Scratch evidence: mutant-warmup-sticky-pending/independent-results.json and its
independent-mutant.log / independent-restored.log under the task scratch root.
This is one real source mutation, not proof of sensitivity to every defect.

Official Claude Code implemented and verified the slice and reviewed it in a
separate read-only session, with verified claude.ai Max subscription authentication.
API/provider overrides were removed; there was no API fallback. Codex reviewed the
source, failure paths and mutation evidence. Earlier focused logs are explicitly
historical; no old prefix validates the final source.

## Complete workflow and boundaries

The final full run passes all 40 checks: build, 3,320 tests (two skips, zero
failures), all 102 simulator records, performance and the complete script/app/
updater harness checks. The source fingerprint before and after is identical:

f626b08254807a4199b6241b835ffd7bfe0bcee2d2a1d8aa600f37df7b2ab1d6

Task-local evidence is runtime-host-effects-full-gates/results.json and its raw
logs. The fingerprint covers the relevant source, tests, package and workflow
inputs; subsequent decision/evidence prose updates are checked separately.
The earlier full run also passed each check but changed source during execution;
its stable=false result is historical and does not validate the final tree.
Hosted Swift and CodeQL passed on exact head
62b3b71dad943d7df6a874aa52c91fe16ae7f169; [PR243](https://github.com/srps/Conduit/pull/243)
merged at80144373555e0a02fb22b3fd06f0f57c45c4589b. Optional automated code/security
reviews failed to complete and Devin skipped; no actual review submissions or
inline findings were present. Those services supply no clean-review evidence.
The full run includes the app harness, which consumes the shared warmup producer. No serving app/helper was stopped, replaced or installed;
no VPN was required. No real-session auth/PAC/VPN or installed-app validation is
claimed. Decision 0032 records the chosen reload policy but is still planned;
this slice does not replace RuntimeHost's configuration loader with the store.
