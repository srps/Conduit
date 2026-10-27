# Shared module owner checkpoint, 2026-10-27

Status: unreleased shared-host integration. The actual framed client/private editor and AppState activation remain incomplete. Official Claude Code implemented and independently reviewed through the owner's verified claude.ai Max subscription; Codex reviewed and executed the guard checks. Serving Conduit 0.5.8, the helper and machine settings were untouched.

## One owner and one path

`RuntimeHostLifecycle` composes Start, scoped teardown, Stop and single-flight Quit over three fixed module lanes. The daemon and module facades use those functions; the replaced whole-runtime lane and lifecycle bodies are removed. `RuntimeConfigurationWorkflow` owns the sole store. Saved commands capture once inside its capacity and consume one exact verified runtime/platform pair. There is no queued configuration registry, alternate loader/writer, late rebind or automatic Start replay.

Whole actionable revision validation precedes mutation. An invalidated combined Start retires unfinished matching grants once and cleans only resources under its current tokens. Prior idle-running modules and newer owners stay. A Stop outside the request's explicit scope stays independent. Session DNS Stop fences immediately, cleans independently of store capacity and persists its disable through the same canonical store primitive.

Pending DNS enables belong to their request. Other writes stage durable intent/current Stop false. A held unverified Start gives back any Stop save it displaced; its own verified enable remains a saved fact, including a late completion after facade Stop or Quit. Newer session Stop wins. A carried obligation reports owed until verified, and configured facade Start cannot displace it. No new retry or persistence path is needed.

Conditional DNS never enables configuration or clears a fence. It checks its parent's exact prepared pair after suspensions and reports its own result. Replacing that pair holds the companion while leaving the completed proxy up.

`lifecycle.module_settled` carries closed module/source/result values and the numeric workflow group, with separate domain/wire values and exhaustive projection. Each member and companion records once; a joined request does not duplicate it. This is logical settlement, which can precede owned cleanup, not a physical-quiescence receipt. Diagnostic text stays out of its fields.

## Completion and inherited cleanup

A Start that takes over a Stop cannot use an old running snapshot as proof of completion. Each kernel module now retains one current whole-start completion, covering proxy PAC/probe preparation and DNS forwarder/transparent work. A same-input caller joins that completion; Stop advances independently and waits only for actual listener work. Older completion cannot clear a newer handle. The host checks the proxy's serving predicate before applying surfaces.

An unconfigured DNS member finishes cleanup inherited from an in-flight operation. The effect retains the three-module bounded set already busy at lane acquisition. This is separate from modules merely down: a normal configured-off Start must not probe or reset a user's loopback resolver. Prior idle-running DNS remains as selected; `not_configured` says this Start started nothing new. Tunnels need no symmetric branch: their reload reconciliation already closes removed definitions.

## Verification

The final focused wrapper passed 1,346 tests (two resource probes skipped), event catalogue (225 names), decision history, whitespace and the actual-host `runtime-host-effects` scenario (95 assertions). A redundant test that directly mutated effect state was replaced by the real failed-DNS/held-tunnels/identical-Start witness.

[Twenty strict production guard mutations](experiments/runtime-module-guards/README.md) each failed intended assertions without a compiler error or crash; baseline and exactly restored runs passed all 80 focused module/model/physical tests. The first busy-event witness crashed after its expected assertion, was excluded, and was corrected to fail safely; all twenty were then rerun. Fresh independent subscription-backed static reviews found no remaining blockers in their scopes.

The [six physical-ordering guards](experiments/runtime-physical-guards/README.md) were also rerun against this owner: each failed intended assertions without compiler errors or crashes; baseline and exactly restored runs passed 19 physical tests.

The actual-host reference model covers 241 sequential histories/590 transitions and eight gated Start/Stop histories. Additional deterministic witnesses cover reverse Stop-to-Start takeovers, mixed scopes waiting through PAC/bind work, preserved owed saves and user resolver preservation. These are bounded histories, not every OS/NIO schedule or a private-client model. The separate capture model and physical-ordering experiments retain their own source identities and scopes.

The first broad run exposed the pre-existing configured-port-zero applied-endpoint issue [#251](https://github.com/srps/Conduit/issues/251), plus a pressure-test scheduling error. The completion witness now uses a fixed configured port. The pressure test waits for both held capacity and the excess refusal before draining; its exact capacity/outcome assertions remain. Neither fix adds timing retries or changes product limits.

An earlier `thILFZ` owner run failed gated-settle teardown, then correctly retained its one lease slot and failed the next fixture. Its exact settlement/flush cause was not captured. The fixture now reports settlement, joins/admissions, lane/store idle and each diagnostic phase on recurrence. Later passing runs do not diagnose that failure; bounds and fail-closed retention stay.

All 41 local workflow checks passed on unchanged runtime/test/script fingerprint `69297b5df0c305b13eb3bf45ac12495d63210e2d01e604b250dd555ef0e581e0`: 3,551 tests (four skips), all 103 simulator records, perf and packaging/boundary checks. [Workflow evidence](experiments/runtime-module-guards/workflow-checks.json) records the source checkpoint. Exact-head hosted checks and review disposition are recorded on the pull request; local checks alone are not release acceptance.

## Still required

- Actual service/client adapter, private editor observation/update/receipt, preference/admin operations, shared incarnation/request identity and reserved final Quit draft flush.
- Actual-adapter frame, memory and Stop/status measurements before selecting the remaining production profile/deadlines. Current host Quit joins have no selected total deadline yet.
- One AppState activation deleting replaced lifecycle/reconciler/observer/save paths, then whole-cluster RuntimeActor isolation and release acceptance.

The existing native-tunnel Stop/all-bind-failed shared-pool issue is [#250](https://github.com/srps/Conduit/issues/250); ephemeral applied endpoints are #251. Lower-level forwarders do not promise arbitrary concurrent direct-call safety. AppState retains its legacy paths until the single activation. This slice changes no file schema or v1 counter. Repeated in-flight kernel Starts now await real completion; the new typed event extends the unreleased contract. No installed-app or release-readiness claim follows.
