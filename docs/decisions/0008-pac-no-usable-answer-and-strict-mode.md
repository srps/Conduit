# 0008: PAC answers with no usable entry and strict mode

- Date: 2026-09-25
- Decision: accepted (owner, 2026-09-25, #49, #50, #87)
- Implementation: implemented
- Validation: none
- Supersedes: none
- Superseded by: none

## Context

- CFNetwork drops PAC directives it does not support (`HTTPS`, `HTTP`, `SOCKS5`, `QUIC`) before Conduit sees them, and the adapter turned an all-dropped answer into DIRECT (#49, #50).
- Script errors, timeouts and an unloaded PAC returned no routes, and the direct-reachability shortcut then sent the request DIRECT (#50).
- In strict mode, the same shortcut let any host that answered a background direct probe bypass the upstream (#87). Everywhere else, strict mode fails closed.

## Decision

- **No usable answer means upstreams only (#50).** An empty result, only unsupported or invalid entries, an evaluation error, a timeout, a PAC not yet loaded, a refused evaluation or a superseded result routes through the configured upstreams. No DIRECT is synthesized, the reachability shortcut does not apply and there is no PAC DIRECT fallback. It emits a rate-limited `pac.no_usable_route` with the reason.
- **The adapter reports, never invents (#49).** It never synthesizes `DIRECT` and accepts only `DIRECT`, `PROXY host:port` and `SOCKS host:port` with a valid endpoint. `SOCKS` entries are unsupported upstreams and are never replaced by the pool or DIRECT.
- **A promoted DIRECT is a fallback.** A `DIRECT` that becomes first only because rejected entries were removed is allowed outside strict mode and suppressed in strict mode.
- **Explicit choices are unchanged.** A script's leading `DIRECT`, `forceProxyHosts` and `noProxyHosts` keep their meaning. `vpnDisconnected` and `noUpstreamsConfigured` still route directly without PAC.
- **Strict mode drops the shortcut (#87).** It never routes DIRECT on reachability and makes no proactive probes. After a strict-mode upstream failure (502), Conduit probes that host once and, if it answers, emits `routing.strict_direct_reachable` with a hint to add it to No-proxy hosts. The request still fails. Non-strict mode keeps the shortcut.

## Alternatives

- Map `HTTPS`/`HTTP`/`SOCKS5` entries to a plain proxy or SOCKS. CFNetwork has already dropped them, and mapping would send plaintext to a proxy the script declared secure.
- Keep treating an unusable answer as DIRECT. An invalid decision would then grant direct traffic.

## Consequences

- A broken or unsupported PAC fails closed through the upstreams instead of bypassing them.
- Strict-mode users may see 502s for hosts that used to go direct, with a hint event to fix their No-proxy list.
- TLS to the proxy stays out of scope; CFNetwork's PAC path cannot express it.

## Invariants and verification

- On every no-usable-answer row, for HTTP, CONNECT and SOCKS5, strict and non-strict, the direct-origin connection counter stays at zero.
- Native fixtures run the real `CFNetworkExecuteProxyAutoConfigurationScript`, so a macOS change in directive mapping fails a test.
- At most one hint probe per host per cooldown, a bounded table and at most four probes in flight.

## Implementation evidence

Landed in #91.

- [`CFPACEvaluator`](../../Sources/ProxyPAC/CFPACEvaluator.swift) and its native fixtures in [`CFPACEvaluatorTests`](../../Tests/ConduitTests/CFPACEvaluatorTests.swift).
- [`PACRoutePlan`](../../Sources/ProxyKernel/Proxy/PACRoutePlan.swift), shared by HTTP, CONNECT and SOCKS5; [`PACRoutingTableTests`](../../Tests/ConduitTests/PACRoutingTableTests.swift) and [`PACDecisionTests`](../../Tests/ConduitTests/PACDecisionTests.swift).
- The hint probe in [`DirectConnectDetector`](../../Sources/ProxyKernel/Network/DirectConnectDetector.swift).
- The `pac-unsupported-only` and `strict-direct-reachable` scenarios in [`PACRoutingScenarios`](../../Sources/pm-sim/PACRoutingScenarios.swift), run in CI's forced-routing step.

Does not prove: behaviour against a production corporate PAC. No owner validation of this decision is recorded. Later fixes refined it: #97 holds the strict-mode hint while a VPN transition settles, and #93 bounds usable PAC routes without changing DIRECT precedence.

## Open questions

None.
