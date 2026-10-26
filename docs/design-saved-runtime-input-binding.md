# Saved-command input binding: owner review

Status: option A selected by the owner on2026-10-26, recorded in
[0037](decisions/0037-saved-command-preparation-capture.md) and issue186.
Claude Code reviewed the alternatives through the owner's claude.ai Max subscription.
Replace the unmerged option-B prototype; do not keep a compatibility mode.
The owner directed finishing the shared owner and deleting replaced paths, with
one cohesive configuration store/load implementation and only material architecture
questions. The comparison below records the alternatives, not runtime modes.

## Scope of the choice

Private editor Start submits its frozen values and exact baselines. That is
selected in 0035 and remains unchanged. A menu Restart or the daemon's whole-host
Start carries no editor values. We have selected its required-input verification,
Stop fences and lack of last-applied fallback, but not when it chooses the saved
configuration it will use.

Source inventory at main `203d334`: `RuntimeConfigurationWorkflow.prepareStart`
reads the store's current values when preparation runs. `RuntimeHost.pushVerifiedInput`
can then leave a newer eligible reload's input in place while the Start continues.
The latter is legacy behavior, not a private frozen-input contract.

0035 begins with "The private editor request carries one frozen runtime/platform
input"; it does not select saved-command timing. 0036 requires the same verified
pair and preparatory gate but does not specify the binding instant. 0032 prevents
an older reload overtaking newer intent; it does not answer this question.

## Concrete outcomes

A is saved when Start/Restart is accepted. Another client explicitly reloads valid
B while the command waits. Assume no Stop or other lifecycle change.

| Choice | B arrives before preparation | B replaces the pair after preparation, before affected effects |
| --- | --- | --- |
| **A: capture once at preparation (recommended)** | Capture and use B. | Hold/supersede the remaining command; do not rebind or retry it. |
| **B: pin at admission** | Hold/supersede; the accepted input was A. | Hold/supersede. |
| **C: follow newer eligible input through the push** | Use B. | May use B, under an explicit bounded rebind/eligibility rule. |

Every choice preserves B's observed bytes, refuses invalid/uncommitted required
inputs and reports already-completed saves/effects honestly. None can make a
private frozen update silently apply somebody else's values. Stop retains its
independent admission and fences. No choice introduces a snapshot registry.

## Recommendation and tradeoffs

Claude and Codex recommend A. A saved command means "use the saved settings when
work begins". It selects one pair at the existing preparation boundary before any
staging/write, avoids retaining a full captured configuration while queued, and
keeps one cause for the effects that follow. A replacement after that checkpoint
requires an honest held/superseded result and an explicit new user action.

A preserves the legacy before-preparation behavior but changes its ability to
follow a later reload through the push. B gives the click/admission a stronger
meaning and one early revision check, but a normal reload while the command waits
can prevent it from running; queued captures must be included in custody measures.
C preserves more legacy progress. It is viable without an unbounded loop, but needs
an exact last rebind point, required-pair proof and outcome semantics for "prepared A,
used B". Those must not leak into private frozen requests by accident.

## Shared shape to preserve under every choice

The conceptual input is either **saved** or **submitted frozen values plus exact
baselines**. Both use the one store/workflow, module intents and verified-pair
primitive. A prepared operation carries its lifecycle ticket, verified pair and
its validity token. Values stay off ordinary frames; the private request remains
one complete request. This is not authority for a second save path, independent
module config baselines, generic mode flags, automatic replay or new shipping
profile defaults. API names are implementation details under the selected rule.

The prototype's test `testAFacadeStartNeverWritesOverAReloadObservedDNSValue`
currently expects option B's supersession before preparation. Its no-overwrite
assertion applies to all choices. Its admission-pinned expectation must be replaced by preparation-time capture.
A superseded legacy `startRuntime` must also stop appearing as successful merely
because it returned Void: provide a typed refusal/outcome and derived event under
all choices. Three host lanes, DNS bind/Stop ordering, the actual service adapter
and private read measurements still remain; this checkpoint is not release ready.

## Acceptance after selection

Test both arrival points above through the actual workflow and host, required
sidecar/default verification, changed-file conflicts, Stop at each suspension,
coherent proxy/DNS inputs and explicit typed settlement. Extend the independent
model and actual-host simulator; execute meaningful source-guard mutations.
Recheck frame size and physical-custody/lifetime costs when the real client adapter
adopts the fields. Production capacities/deadlines and total Quit remain separate
measured choices.
