# 0036: Explicit host-checked conditional DNS activation

- Date: 2026-10-26
- Decision: accepted (owner, 2026-10-26, #186)
- Implementation: partial
- Validation: none
- Supersedes: none
- Superseded by: none

## Context

Today proxy Start/Restart can bring up enabled DNS after launch or a failed bind. An ordinary private
save-only DNS slot cannot start it, and normal DNS Start authorizes enabling and clearing a fence.
Those are different intentions. Conditional convenience should not be represented as a new explicit
enable or be decided from a client mirror. Whole-request validation is selected in 0035.

After official subscription-backed Claude review and an architecture explanation, the owner approved
host-checked conditional activation on 2026-10-26 (“sounds good. go with that.”), recorded in
[#186](https://github.com/srps/Conduit/issues/186). The [reviewed alternatives](../design-runtime-editor-admission-options.md)
record the tradeoffs.

## Decision

Proxy Start and ordinary menu Restart may explicitly request conditional DNS activation. The host
starts DNS only while its authoritative intent is already enabled and unfenced, nothing newer
supersedes it, and DNS is neither running nor starting. The action never writes enabled intent or
clears a DNS Stop fence. It has its own exact lifecycle revision and typed outcome.

Private Start still carries the current frozen valid draft. A conditional DNS slot is valid only when
paired with proxy Start. Ordinary menu Restart gets a narrow typed DNS companion and carries no
editor values. Both entry points use the same host/workflow primitive, with no generic dependency
engine, second writer or client-side lifecycle authority.

Restart's preparatory verification still goes through the sole store/workflow and required-input gate.
Required defaults may verify/commit there. Mixed, uncommitted, latched or otherwise ineligible inputs
hold; there is no last-applied fallback. Proxy and DNS use the same verified pair. Explicit Settings
commit/restart flows keep their edit intent by using the private full-configuration path.

Validate all participating revisions at admission under 0035. At execution recheck live intent, fences
and run state. A later Stop invalidates any remaining shared write/apply as in 0035. If Restart only acts
on unchanged verified inputs, a DNS Stop cancels its companion rather than stopping the proxy restart.
Completed physical effects are reported facts. Proxy Stop supersedes its pending companion.

Disabled/fenced/already-running/starting DNS is a typed no-op. If DNS startup fails, retain its enabled
intent and fence, restore its machine DNS surfaces as the app does, report that result separately and
leave an already-started proxy up. This is not a failed explicit DNS enable.

No ordinary Start command or launch auto-start is added. The daemon whole-host CLI/start facade and
pm-proxy behavior stay separate. New bounded fields/cases require sizing before codec adoption.

## Alternatives

Client-composed normal DNS Start reuses a case but models convenience as an explicit enable, couples
it to failed-Start authorization rules, and makes Restart require a separate operation or companion
anyway. Correct revision checks can make it safe, but the semantic and client-policy cost is higher.

Independent controls are coherent and smaller, but remove existing convenience: users must manually
start configured DNS after starting/restarting the proxy. No current usage need justifies that change.
A hidden host rule under save-only would silently change its meaning and was rejected.

## Consequences

One small explicit conditional action preserves existing convenience while the sole host owns its
permission and outcome. The wire gains a case and Restart companion. Menu Restart no longer saves
unsaved Settings values; explicit Settings commits continue to submit those values. Activation reads
host intent instead of the editor's DNS bit. Partial physical outcomes remain visible.

## Invariants and verification

Exercise real workflow/host/client adapters over explicit fakes: enabled DNS stopped/running/starting,
disabled or fenced DNS; stale proxy/DNS revisions before admission; Stop at each suspension; failed
DNS bind and machine restoration; failed proxy Start; verified-input holds. Assert both entries use one primitive and one verified pair. Do not automatically replay a held explicit
Start or clear a fence; conditional activation does not revoke prior enabled intent on failure. Extend independent bounded models,
execute meaningful guard mutations and add actual-host pm-sim coverage. Renew request/reply sizing.

## Implementation evidence

The [shared module owner checkpoint](../verification-runtime-module-owner-2026-10-27.md)
implements the host-side rule in
[`RuntimeHostLifecycle`](../../Sources/ConduitRuntime/RuntimeHostLifecycle.swift),
[`RuntimeModuleIntents`](../../Sources/ConduitRuntime/RuntimeModuleIntent.swift) and
[`RuntimeConfigurationWorkflow`](../../Sources/ConduitRuntime/RuntimeConfigurationWorkflow.swift).
[`Actual-host reference/model and ordering tests`](../../Tests/ConduitTests/RuntimeHostInteractiveTests.swift)
and [executed guard mutations](../experiments/runtime-module-guards/README.md)
cover the selected authority and freshness rules. The client integration follows below; AppState activation remains open.
Does not prove: actual framed-client/private-editor adoption, AppState activation, RuntimeActor isolation, production service-profile selection or release readiness.

The local [actual-client checkpoint](../verification-runtime-client-owner-2026-10-27.md) carries the exact client-observed DNS revision through ordinary Restart and the private Start's conditional DNS slot. [`RuntimePrivateEditor`](../../Sources/ConduitRuntime/RuntimePrivateEditor.swift) uses the same host lifecycle primitive and reports its companion result separately. It adds no DNS-enable write or fence-clearing shortcut. Complete-source review and AppState activation remain open.

The conditional-activation slice above introduced no ordinary Start command.
Subsequent native call-site review found menu, Overview and shortcut Starts use
saved values, with no Settings Start caller. Completing that client under 0037
adds an unshipped v2 saved Start through the same admission, preparation and
settlement primitive. It does not add launch auto-start, alter v1/the daemon CLI
or make a private Start follow saved input. The original conditional DNS policy
and exact companion precondition remain unchanged.

## Open questions

Production capacity/custody/deadline/total-Quit values still require actual-adapter measurements.
Listener handoff and per-surface applied-state expansion retain their separate affected-slice gates.
