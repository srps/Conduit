# Shared module owner checkpoint, 2026-10-27

Status: unreleased host integration; actual framed client/private editor and AppState adoption remain incomplete. Official Claude Code implemented through the owner's verified claude.ai Max subscription; Codex independently reviewed and ran the guard mutations. The serving 0.5.8 app, helper and machine settings were untouched.

## One owner and one path

`RuntimeHostLifecycle` composes one Start, scoped teardown, Stop and single-flight Quit over three fixed module lanes. The old whole-runtime lane and lifecycle bodies are removed. The daemon facade and scoped production module facade compose those same functions. The private workflow retains the sole store; preparation captures once inside its capacity and consumes one exact verified runtime/platform pair. No registry, parallel loader/writer, late rebind or automatic Start replay is introduced.

Whole actionable revision validation precedes mutation. An invalidated combined Start retires unfinished matching grants through one finalization and cleans up only its own still-held resources. Prior already-running modules and newer owners stay. An unrelated Stop outside its explicit scope stays independent. Session DNS Stop fences immediately, performs cleanup independently of store capacity, and persists its disable through the same canonical store primitive. A matching later verified write fulfils that obligation without clearing the fence; late older writes cannot fulfil a newer Stop.

Pending DNS enables are request-owned. The same staged-value helper serves capture and claim freshness: only the owning explicit DNS Start stages true; other requests use durable intent/current Stop false. A request's own verified enable remains a saved fact if subsequent activation fails. Conditional DNS never creates an enable or clears a fence, reports separate no-op/failure outcomes, and checks its parent's prepared pair after suspensions. A replaced pair holds the companion without undoing the completed proxy.

## Verification

The frozen owner at Kernel checkpoint `b478979` plus this slice passed the exact focused wrapper: 710 tests, event catalogue (224 names), decision history, whitespace and actual-host `runtime-host-effects` simulator (91 assertions). It covers the physical follow-up's three new tests too.

[Seven executed production mutations](experiments/runtime-module-guards/README.md) each failed intended assertions; exact source restoration and the 49-test focused suite passed. The actual-host independent model covers 241 sequential histories/590 transitions and eight gated Start/Stop histories. Scope is proxy/DNS state and intent plus tunnel isolation; this is not all OS/NIO schedules or a private-client model. The separate capture model and [six physical-ordering mutations](experiments/runtime-physical-guards/README.md) retain their own scopes and source identities.

The first owner wrapper `thILFZ` failed a gated-settle teardown and then failed the next fixture because its one retention slot correctly stayed occupied. Its exact settlement/flush cause was not captured. The fixture now reports settlement, joins/admissions, lane/store idle and each diagnostic phase on recurrence, preserving its bounds and fail-closed retention. Later passing runs do not diagnose that failure. A run edited while executing was not counted as final evidence.

## Still required

- Complete typed module settlement diagnostics; isolated module failure currently returns a typed result but lacks that event.
- Fresh combined-owner review and every `swift.yml` gate, then exact-head hosted checks/review disposition before merge.
- Actual service/client adapter, private editor observation/update/receipt, preference/admin operations, shared incarnation/request identity and reserved final Quit flush.
- Actual-adapter sizing, memory and Stop/status measurements before selecting the remaining production profile/deadline. Current Quit joins have no selected total deadline yet.
- One AppState activation deleting its replaced lifecycle/reconciler/observer/save paths, then whole-cluster RuntimeActor isolation and release acceptance.

The pre-existing native-tunnel Stop/all-bind-failed shared-pool limitation remains [#250](https://github.com/srps/Conduit/issues/250). Physical forwarders do not promise arbitrary concurrent direct-call safety, and AppState retains its legacy tunnel/termination gaps until activation. No schema, v1 counter or installed-app compatibility claim follows from this checkpoint.
