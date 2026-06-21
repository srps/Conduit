# STYLE

**The engineering discipline for Conduit.**

This is a direct descendant of TigerBeetle's [TIGER_STYLE](https://github.com/tigerbeetle/tigerbeetle/blob/main/docs/TIGER_STYLE.md), adapted for a macOS-native user-mode proxy daemon. It keeps the parts that matter for daily-driver reliability, observability, and security; it drops the parts that only make sense for a zero-dependency financial database (static allocation everywhere, 70-line function limits, no external libraries).

If you're reading this because you're reviewing a PR, the quick version is at the bottom: [Review-time checklist](#review-time-checklist).

## Why this document exists

Conduit is a **menu-bar tool people rely on every working day**. It authenticates to corporate Kerberos/NTLM proxies, evaluates PAC, resolves DNS, tunnels TLS, and fails over between upstreams — on network paths that flap between Wi-Fi, VPN, captive portals, and tunnels.

That product shape imposes a discipline:

- **Unbounded anything is a bug.** A leaky cache or queue over 30 days of daily use manifests as "why did my Mac fan spin up?"
- **Silent failures are user-hostile.** If the proxy quietly falls through to DIRECT, the user trusts a broken tool.
- **System side effects are dangerous.** Mutating `/etc/resolver`, DNS, proxy settings, or login items in the wrong state leaves the machine wedged.
- **Credentials are radioactive.** A leaked `Proxy-Authorization` header is a corporate-security incident.

STYLE encodes the habits that keep those failure modes out.

## Relationship to other documents

- **[`AGENTS.md`](../AGENTS.md)** — short, actionable contract for human and AI contributors (NEVER / ASK / ALWAYS). Carries the judgment layer. References this doc.
- **`STYLE.md`** (this file) — the full discipline, with rationale and examples.
- **[`roadmap-v2.md`](roadmap-v2.md)** — product plan. §2.3 is the source for this doc; §5.7 is the research on why we didn't just adopt TIGER_STYLE verbatim.
- **[`docs/architecture.md`](./architecture.md)** — target module graph.

## Principles

### 1. Bound everything

Every pool, queue, cache, and buffer has a **fixed capacity defined in config**. The runtime runs for weeks without memory growth. Unbounded growth is a bug.

**Already applied:**

- `RuntimeEventLog` — fixed-capacity ring buffer, oldest-evicted-on-overflow.
- `ConnectionPool` — `maxConnections` cap per upstream.
- Inbound connections — `inboundConnectionMaxLimit` hard reject + `inboundConnectionWarnThreshold` warning.
- Tunnel sessions — `maxTunnelSessions`.
- Request body replay — non-CONNECT HTTP bodies stay in memory up to `maxBufferedBodyBytes` (16 MB default) and then spill to bounded temp files up to `maxSpooledBodyBytes` (256 MB default) so direct/proxied routes and multi-leg 407 auth can replay without unbounded RAM.
- DNS response cache — 2048 entries, LRU.

**Still needed (pending audit):** PAC evaluation queue bound, pending-auth handshake bound per source IP, any new collection introduced post-audit.

**Rule of thumb:** if you write `var x: [T] = []` and `append` to it in a loop that reads from the network, a timer, or another unbounded source, you need a cap.

### 2. Assert invariants, not just happy paths

After every state mutation (config reload, connection open/close, auth handshake, failover), assert internal state is consistent.

- `precondition()` for bugs (internal logic errors; crash is correct).
- `throws` for user errors (bad config, unreachable host).
- Assertion failures emit a structured `RuntimeEvent` with correlation IDs — not silent crashes, not anonymous `fatalError`.

**Example (invariant):** `ConnectionPool` should satisfy `active.count + idle.count ≤ capacity` after every mutation. Add a `precondition` in the mutating method, not just in tests.

**Example (user error):** a malformed PAC URL is caught by `ConfigValidation` at parse time and thrown, not asserted.

### 3. Structured events before log lines

Every runtime behaviour emits a `RuntimeEvent` **first**. Log lines are *derived from* events, never the other way around.

Events are the contract with:

- The UI (menu bar traffic lights, event inspector).
- `pmctl` / `pm-proxy --status-interval` NDJSON streams.
- The `pm-sim` agent harness (assertions from events, not log grep).
- The chaos demo (live event visualization).

**Rationale:** log lines are ephemeral, human-shaped, format-churning. Events are typed, machine-consumable, test-assertable. If behaviour exists only as a log line, the UI and the test harness can't observe it.

**Rule of thumb:** if you reach for `logger.info(...)` to record a decision, you should first emit a `RuntimeEvent`, then (optionally) derive the log line from it.

### 4. Validate at the boundary, trust inside

Validation lives at module boundaries; the internals trust their inputs.

- **Config boundary:** `ConfigValidation.swift` + per-section validators. After parse, `ProxyConfig` is valid.
- **Network boundary:** NIO handlers validate bytes, hostnames, ports, lengths. After a handler, structured types are valid.
- **Process boundary:** `pm-proxy` entry-point validates CLI flags; `RuntimeEnvironment` is the only ambient state injected.

Inside `ProxyKernel`, data is already valid. Assertions catch *bugs* (we violated our own invariant), not *user errors* (they gave us bad input).

**Rule of thumb:** if you're about to write a defensive nil-check inside Core, ask whether the boundary should have rejected the nil.

### 5. Functions fit on a screen

**100 lines max** (TigerBeetle uses 70; we're not a state machine at that granularity).

Long functions are a signal to name the sub-steps and extract. `ProxyOrchestrator.startProxy` is the standing example of a function that outgrew the rule; the module split breaks it into named lifecycle sub-steps.

**Rule of thumb:** if you need to scroll to see the start of the function from the end, the function is too long. Extract.

### 6. No silent failures

Every error is either:

- **Recovered** — with a structured event explaining how (e.g., "NTLM fallback after Kerberos TGT expired"), or
- **Surfaced** — with a structured event explaining why (e.g., "upstream A marked unhealthy after 5 consecutive probe failures").

"Catch and continue" without an event is banned. Swallowing a `try?` on a user-visible code path is a review failure.

**Example:** when a CONNECT tunnel fails through upstream A, we emit `failover.attempt` → try upstream B → emit `failover.success` or `failover.exhausted`. The user sees a traffic light change; the agent harness asserts on the event kind; nobody has to grep logs.

### 7. Explicit resource lifetime

Every connection, auth context, DNS session, tunnel session has:

- A **defined start** (construction emits an event; correlation ID assigned).
- A **lifecycle** (state transitions emit events).
- A **cleanup** (close/release is idempotent; emits an event).

Leaks are assertion failures. A counter of "live sessions" that never returns to zero during `pm-sim` teardown is a bug.

**Rule of thumb:** if you `init` something in `ProxyOrchestrator`, search for where it's `deinit`'d before merging. If the cleanup path isn't obvious, the lifecycle isn't explicit enough.

### 8. Side effects gated behind protocols

System proxy, env variables, `/etc/resolver`, login items, helper daemons, Keychain — **none of these are called directly from `ProxyKernel`**. All go through a `PlatformIntegration`-shaped protocol, mocked in tests and in `pm-proxy`'s headless mode.

**Current abstractions:**

- `ProxyAuthenticator` (protocol) — authenticator strategies.
- `PrivilegeClient` (protocol) — helper daemon IPC.
- `RuntimeEnvironment` — persistence paths (file locations only).

**Shipped additions (module split + security hardening):**

- `CredentialProvider` — Keychain access.
- `PacEvaluator` — PAC resolver (CFNetwork-backed, Safari-parity).

**Planned additions:**

- `PlatformIntegration` — system proxy, env, `/etc/resolver`, login items, notifications.
- `NotificationSink` — user notifications.

**Rationale:** `pm-proxy --state-dir /tmp/... --port 0` must be a pure function of its arguments. No ambient process state; no machine state mutations; no Keychain prompts. This is what makes the binary safe for CI, agents, and fault-injection testing.

### 9. Security is a first-class review axis

Every auth, credential, or privilege-escalation change is reviewed for:

- **Credential handling.** Credentials never cross `ProxyKernel` boundaries as `String`; use `SecretBytes` — an opaque wrapper that forbids `description`/`debugDescription`, zeroes on `deinit`, is `Sendable` but not `Codable`.
- **Log sanitization.** `Authorization` / `Proxy-Authorization` / `Cookie` / `Set-Cookie` / bearer tokens are masked in *every* log sink (in-app ring buffer, stderr, file, NDJSON).
- **PAC evaluation.** CPU- and memory-bounded. No access to process globals or file system from the PAC context. The PAC engine swaps JavaScriptCore for `CFNetworkExecuteProxyAutoConfigurationURL` (Safari-parity, OS-patched).
- **Tunnel credentials.** Never embed plaintext passwords; rotatable without daemon restart.
- **Helper IPC.** Unix socket restricted to `root:staff` with `getpeereid` peer validation; every privileged call emits an `auth.privilege_request` event for audit.
- **SNI validation.** `SNIParser` validates hostnames per-label (RFC 952). Property test covers random garbage → no false positives.

When any of the above changes, [`docs/threat-model.md`](./threat-model.md) gets updated in the same PR.

### 10. Deterministic where possible

- `pm-sim` scenarios must be **reproducible for a given seed**.
- `ProxyOrchestrator` decisions should be pure functions of `(config, snapshot, wall-clock)`.
- Hidden non-determinism (ambient env vars, global singletons, untracked clock access) is a bug.

**Rule of thumb:** if a test sometimes passes and sometimes fails on the same commit, the code under test has a non-determinism bug, not a flaky test.

**Scope:** we don't aim for TigerBeetle-level deterministic simulation of the entire runtime — we're not a financial database. We aim for deterministic scenarios under `pm-sim` and deterministic unit tests under `swift test`.

## How this differs from TIGER_STYLE

STYLE is TIGER_STYLE minus the parts that are over-engineering for a desktop proxy. The full rationale is in [`roadmap-v2.md §5.7`](roadmap-v2.md).

| TIGER_STYLE rule | STYLE position |
|---|---|
| Bounded everything | ✅ Adopted (rule 1). |
| Assert invariants | ✅ Adopted (rule 2). |
| Zero dependencies | ⛔ Rejected. We ship on SwiftNIO + Apple frameworks. That's fine. |
| 70-line function limit | 🟡 Relaxed to 100 (rule 5). |
| Zero dynamic allocation post-init | ⛔ Rejected. We're a user-mode daemon, not an LSM-tree. |
| Deterministic simulation of the whole runtime | 🟡 Scoped to `pm-sim` and tests (rule 10). |
| Structured events / no silent failures | ✅ Adopted (rules 3, 6). |
| Explicit resource lifetime | ✅ Adopted (rule 7). |
| Safety > performance > developer experience | ✅ Same priority order. |

## Review-time checklist

For reviewers (human or AI). When reviewing a PR, walk this list:

- [ ] **Bounds.** Every new collection/cache/queue/buffer has a cap from config or a `precondition`-backed invariant. (Rule 1)
- [ ] **Invariants.** Mutations assert post-conditions. Crashes are `precondition` with context; user errors `throws`. (Rule 2)
- [ ] **Events first.** Every routing / auth / failover / health / config decision emits a `RuntimeEvent`. Log lines derive from events. (Rule 3)
- [ ] **Boundary validation.** New external input is validated at the module boundary, not defensively inside Core. (Rule 4)
- [ ] **Function size.** No function > 100 lines. (Rule 5)
- [ ] **No silent catches.** Every `catch` either recovers-with-event or surfaces-with-event. `try?` on user-visible paths is justified. (Rule 6)
- [ ] **Lifetimes.** Every `init` has a matching `deinit` / `close` / `release`. Cleanup is idempotent. (Rule 7)
- [ ] **Side-effect gating.** New system calls go through a protocol, not directly. `ProxyKernel` imports no Apple frameworks beyond SwiftNIO + Foundation. (Rule 8)
- [ ] **Security.** Credentials use `SecretBytes` (once available); `Authorization` / `Proxy-Authorization` are masked in logs; PAC evaluation is sandboxed. (Rule 9)
- [ ] **Determinism.** Tests don't depend on wall-clock or ambient state; `pm-sim` scenarios are reproducible. (Rule 10)

If a PR can't check a box, the PR includes a one-line rationale (in the description or an inline comment). That's the audit trail.
