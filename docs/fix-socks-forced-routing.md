# SOCKS5 forced-proxy precedence (S05)

SOCKS5 previously passed `forceProxy: false` to the shared PAC evaluation gate. When a loaded PAC returned DIRECT, that result could override a matching force-proxy rule even in strict mode. HTTP and CONNECT already computed the real force-rule match.

SOCKS5 now computes that match from the current request's configuration and uses the existing HTTP/CONNECT PAC gate. A forced request skips PAC and uses the configured upstream path. The matcher still gives force rules precedence over overlapping no-proxy patterns. Each forced SOCKS decision emits `routing.socks5_force_proxy` through the runtime event sink.

Intentional direct states such as off-VPN operation retain their existing precedence. This fix does not turn strict mode into a VPN kill switch or change upstream-failure policy.

## Regression and validation

`pm-sim forced-proxy-precedence` creates separate loopback direct and proxied origins, a fake upstream, and an in-memory PAC evaluator returning DIRECT. It runs real HTTP, CONNECT, and SOCKS5 requests. The direct origin's accepted-connection count exposes an unintended direct dial even when the client sees a successful handshake.

Before the production fix, the scenario exited 1 with:

```text
Forced SOCKS5 target reached the direct origin despite PAC DIRECT
```

After the fix, it passes with zero direct dials for the forced cases. It also covers removal/restoration of force rules without restarting the listener, exact and wildcard patterns overlapping no-proxy rules, disabling PAC, a previously cached DIRECT result, structured decision events, and intentional off-VPN direct operation. It is registered in `pm-sim all` and the PR workflow.

Local CLT commands:

```sh
DEVELOPER_DIR="/Library/Developer/CommandLineTools" xcrun swift build \
  --build-system native \
  --sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
.build/debug/pm-sim forced-proxy-precedence
```

All fixtures are synthetic and use ephemeral loopback listeners. No company configuration, real credentials, or privileged system mutations are involved. XCTest execution uses the Xcode CI workflow; the local CLT installation lacks XCTest.

This branch is based directly on main and does not depend on the S01–S03 fixes in PR #26. The broader HTTP PAC failover finding R01 remains a separate planned change.
