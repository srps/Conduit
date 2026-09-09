# Security and architecture follow-up plan

Status: S01–S03 implemented on the security-fix branch; full Xcode CI remains the merge gate. See [validation details](security-fixes-2026-09-09.md) and the [original review](review-2026-09-09.md). The findings describe code behavior under their stated preconditions, not confirmed company-environment incidents.

## Finish the current branch

- Require the PR's full Swift build, XCTest suite, new security boundary regressions, and existing performance gate to pass.
- Review the behavior changes: PAC auth requires an enabled configured host/port, rejected reloads preserve state, and non-gateway binds require loopback.
- Keep the PR draft until CI and review are complete. Branch publication does not install the app/helper, merge to main, or produce a release.

S05 is implemented independently in [PR #27](https://github.com/srps/Conduit/pull/27), with a failing-before/passing-after network regression and green initial CI. Its remaining gate is review. S06 is the next implementation batch after current review feedback is settled.

## Sequenced implementation PRs

Each row is a bounded PR. Begin by reproducing the finding with synthetic fixtures, then add a regression with the fix. Prefer existing strategies and protocol seams; shared policy extractions should remove duplicate decisions rather than add another mode flag.

| Order | Findings / proposed branch | Implementation boundary | Acceptance evidence |
| --- | --- | --- | --- |
| 1 | S05 — `fix/socks-forced-routing` | Make SOCKS5 honor the same force-proxy precedence as HTTP/CONNECT. Reuse or extract the existing routing decision; preserve intentional off-VPN/direct policy. | Fake PAC returns DIRECT for a forced destination; HTTP, CONNECT, and SOCKS5 use a healthy synthetic upstream or refuse. A direct-origin counter remains zero in the forced-proxy case. Cover PAC-disabled and no-proxy/force-proxy overlap. |
| 2 | S06 — `fix/observable-target-redaction` | Separate the wire request URI from the observable destination. Strip query/fragment data before ordinary logs, structured events, active connection snapshots, and exports. | Synthetic short secrets never appear in any sink across success/error/body-limit paths; the fake origin receives the original URI unchanged. Assert on raw snapshots as well as diagnostics bundles. |
| 3 | S08 — `fix/socks-admission-budget` | Share inbound connection admission across HTTP and SOCKS5 and release permits on every close/error/cancellation path. Reuse configured limits. | Mixed-protocol flood stays within the intended combined budget, rejects excess clients with structured events, releases permits after failure, and admits a new client after recovery. |
| 4 | S09 — `fix/pac-fetch-bounds` | Enforce the PAC byte ceiling in HTTPS/file loading before accumulating an oversized body; retain timeouts and redirect/URL policy. | Oversized Content-Length, chunked/unknown-length responses, local files, cancellation, and valid scripts exercise bounded reads. Run with a local fixture server and temporary files. |
| 5 | S07 + R04 — `fix/helper-transaction-limits` | Bound the entire helper transaction, reject unauthorized peers without draining arbitrary bodies, move client waits off MainActor, and propagate subprocess exit failures. Use the current wire contract where possible. | A temporary unprivileged socket with fake operations handles drip-fed, partial, stalled, refused, and disconnected clients within deadlines. Later legitimate clients proceed; UI work remains responsive. Failed fake commands return failure and preserve recovery state. |
| 6 | S04 — `fix/helper-caller-authorization` | Implement the authorized-caller model after the decision below. Keep operation-level validation and helper-side peer/action/result auditing. | Fake identity checks deny an unexpected same-UID caller and allow the intended caller. Then verify signed app/helper acceptance, rejected alternate callers, updates, and recovery on a controlled macOS installation. |
| 7 | R01 — `fix/http-pac-failover` | Carry the ordered PAC proxy chain through ordinary HTTP forwarding. Share route selection with the earlier routing fix. Retry only where request replay is demonstrably safe. | First fake proxy unavailable and second healthy succeeds; partial request transmission, non-replayable bodies, authentication failures, and explicit DIRECT entries obey the documented retry policy without duplicate origin operations. |
| 8 | R02 — `fix/audit-completion-outcomes` | Derive audit completion from explicit exchange/tunnel outcomes, not disappearance from a UI connection list. | DNS/connect/auth failures, client cancellation, successful HTTP completion, and established tunnel closure produce accurate, exactly-once audit records. |
| 9 | R03 — `fix/bounded-observability-writers` | Bound producer queues and batches; use append/rotation rather than rewriting whole files per event. Define overflow reporting and bounded shutdown flush behavior. | Slow-storage and sustained-event tests assert queue/byte caps, visible loss counters, rotation, ordering, flush deadlines, and responsive runtime work. |
| 10 | R05 — `fix/drain-active-http-on-restart` | Retire the old pool without closing active HTTP exchanges during listener/config transitions. State shutdown scope explicitly and bound retired pools and their lifetime. | A slow plain-HTTP response and CONNECT tunnel survive a listener change; new requests use the new listener. Terminal stop closes both. Repeated restarts and stuck peers stay within resource limits. Update the conflicting invariant and tests together. |

Orders 5–6 share one helper workstream; keep transport/result fixes separate from caller authorization so each is reviewable. S04 is the remaining high-severity policy gap and a gate before treating a helper-installed build as ready for company use. Its design decision should happen before the implementation queue reaches it; its position is not an assessment that it has low security priority.

## Helper authorization decision

Before implementing S04, decide which signed callers may invoke privileged operations: the app, the user daemon, and any intended administrative CLI. Define the production signing requirement and a separate development policy. Do not replace UID trust with a reusable secret available to every process under that UID.

Evaluate authenticated IPC against the actual supported deployment/signing model, including application updates and stale helper versions. This plan does not select an Apple API without that design/SDK check. A change to `ConduitShared`'s installed helper contract requires explicit agreement and a compatibility/migration design under `AGENTS.md`.

## Validation environments

- **This personal Mac with CLT:** kernel/auth/PAC builds, headless simulations, synthetic HTTP/SOCKS/DNS peers, temporary helper sockets with fake operations, and config/logging tests. Use the documented SDK workaround when building the app. Do not install or invoke the privileged helper as part of these checks.
- **Xcode CI:** the full app/daemon XCTest harnesses, cross-module integration tests, performance gate, and relevant ASan/TSan scenarios. Record expected failures/skips separately. Do not widen sanitizer suppressions merely to obtain a green run.
- **Controlled macOS integration:** signed helper identity and update behavior, Keychain access under the chosen signing model, installation/restoration, and lifecycle behavior that fakes cannot establish. Use synthetic system settings on an appropriate test machine.
- **Company-approved environment only:** actual Kerberos/NTLM interoperability, VPN transitions, internal-resource routing, and permitted direct/public-DNS fallback. No company settings or credentials need to be copied to a personal laptop.

After the behavior fixes, resume daemon/client migration around the shared route, lifecycle, privilege, and observability contracts. Refresh module documentation and enforce import/API boundaries with tooling. Separately decide whether the product needs a mandatory-proxy policy: the current strict mode is not a system-wide VPN kill switch, and these fixes do not turn it into one.
