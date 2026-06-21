# Audit Findings Fix Plan

This document tracks the May 2026 proxy audit fixes. `Tests/ConduitTests/AuditRegressionTests.swift` contains in-process regression coverage, and `pm-sim` carries simulator coverage for the socket-level cases that need isolated listeners.

## 1. Gateway metadata blocklist bypass via origin-form HTTP

Regression test: `testGatewayMetadataBlocklistUsesEffectiveHostForOriginFormRequests`

Status: implemented via `HTTPRequestTarget`; routing, PAC, metadata blocking, and direct probes now use the effective target host/port.

## 2. Hop-by-hop request headers leak upstream

Regression test: `testUpstreamRequestStripsConnectionNamedHopByHopHeaders`

Status: implemented via `HTTPHopByHopHeaders`; forwarded requests strip standard hop-by-hop fields and every token named by `Connection`.

## 3. SOCKS5 method negotiation accepts no-auth when not offered

Regression test: `testSOCKS5GreetingRejectsNoAuthWhenClientDidNotOfferIt`

Status: implemented with a buffered SOCKS5 parser that selects no-auth only when offered.

## 4. URI userinfo leaks into logs

Regression test: `testLogSanitizerRedactsURIUserInfo`

Status: implemented URL-aware userinfo redaction in `SensitiveValueSanitizer`.

## 5. PAC route cache ignores path/query/scheme

Regression test: `testPACRouteCacheKeepsPathSensitiveDecisionsSeparate`

Status: implemented. PAC route cache keys now include the normalized full PAC input URL, including scheme, host, port, path, and query.

## 6. DNS synthesis answers malformed question counts

Regression test: `testDirectDNSSynthesisRejectsZeroQuestionCount`

Status: implemented for synthesized DNS responses; malformed/non-single-question packets no longer get synthesized answers.

## 7. PAC URL query tokens leak in logs

Regression test: `testPACRefreshLogsRedactQuerySecrets`

Status: implemented. PAC refresh logging removes userinfo, redacts query, and drops fragment.

## 8. Wildcard bind without gateway mode creates an unauthenticated LAN proxy

Regression test: `testWildcardProxyBindRequiresGatewayFiltering`

Status: implemented. Config validation rejects wildcard proxy binds without gateway mode, and rejects wildcard DNS forwarder binds without a DNS allowlist.

## 9. Stalled cleanup includes active non-CONNECT streams

Regression test: `testStalledConnectionCleanupIgnoresInUseConnections`

Status: implemented. Stalled cleanup excludes `inUse` connections.

## 10. CONNECT response framing ignores chunked bodies

Status: implemented. `RawConnectHandshakeHandler.tryParseResponse` now consumes chunked response bodies before processing the next handshake leg.

## 11. Proxied HTTP responses forward hop-by-hop headers

Simulator: `pm-sim audit-hop-response`.

Status: implemented. Proxied response heads run through the shared forwarded-message sanitizer before reaching the client.

## 12. Direct HTTP responses forward hop-by-hop headers

Regression test: `testDirectHTTPResponseForwarderStripsConnectionNamedHopByHopHeaders`

Status: implemented. Direct response heads run through the shared response sanitizer.

## 13. SOCKS5 request RSV byte is not validated

Simulator: `pm-sim audit-socks5-rsv`.

Status: implemented. The SOCKS5 parser rejects non-zero RSV before resolving or connecting.

## 14. SOCKS5 TCP frame fragmentation and pipelining

Status: implemented. `SOCKS5Handler` is now an accumulating state machine that preserves bytes across reads and can process complete pipelined frames.

## 15. DoH fallback coerces non-A/AAAA queries to A

Status: implemented for unsupported qtypes by returning a refused response instead of issuing an A lookup.

## 16. Control socket lacks peer authorization

Status: implemented. The control socket is owner-only and rejects peers whose effective UID does not match the daemon owner.

## 17. UDP relay keys pending DNS only by transaction ID

Status: implemented with relay-side TXID rewriting. Responses are correlated by unique relay TXID and restored to the client's original TXID before forwarding.

## 18. Streaming HTTP forwarding lacks downstream backpressure

Regression test: `testForwarderResumesUpstreamWhenClientBecomesWritable`

Simulator: `pm-sim flood-slow-drain`.

Status: implemented. Direct and proxied HTTP response streaming now share downstream writability handling: upstream `autoRead` pauses when the client is unwritable and resumes when the client drains.

## 19. PAC evaluation blocks NIO event loops

Regression test: `testRouteChainFutureDoesNotBlockCallerEventLoopDuringSlowEvaluation`

Status: implemented. `PACRoutingEngine` now exposes an event-loop future API for request routing, and HTTP/SOCKS handlers use it so slow PAC evaluation does not block NIO event loops.

Design note: HTTP/1.1 pipelined response ordering remains out of scope for this proxy path. Async PAC can make routing decisions complete out of arrival order, but strict pipelined response ordering was already not guaranteed once requests entered async upstream exchange or tunnel setup. Modern browsers do not pipeline; supporting it correctly would require an explicit per-client response serializer.
