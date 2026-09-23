# AGENTS.md

Conduit is a macOS menu-bar corporate proxy manager in Swift 6.2 on SwiftNIO and AppKit/SwiftUI: upstream failover, Kerberos/NTLM, PAC, SOCKS5 and tunnels. It has to be reliable as a daily driver, observable through structured events rather than log grepping, and testable headless with no side effects on the machine.

Most targets under `Sources/` have their own `AGENTS.md` with the rules for that code. Those rules add to this file; where they conflict, the nearer file wins. If a rule can be enforced by a linter, a test or a type, move it there and delete it here.

## Commands

The default `swift` may be Command Line Tools, which fails with `no such module 'XCTest'`. Prefix every build and test with `DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"`.

| Intent | Command |
| --- | --- |
| Build | `xcrun swift build` |
| Test | `xcrun swift test` |
| Before pushing | Every step of `.github/workflows/swift.yml`, not only `swift test`: at least `pm-sim all`, the `scripts/test-*.py` checks and `scripts/perf-gate.sh` |
| Headless proxy | `pm-proxy --state-dir "$(mktemp -d /tmp/pm-test-XXXX)" --port 0 --dns-port 0 --status-interval 2` (keep the state dir path short; it holds a control socket) |
| One simulator scenario | `swift run pm-sim <scenario>`; scenarios live in `Sources/pm-sim/` |
| Dev app beside the installed one | `./bundle-app.sh`, then `open -n -a "$PWD/Conduit.app" --args --dev [--section dns] [--vpn utun4] [--upstream host:port] [--dev-state-dir PATH]` |
| Install app | `./bundle-app.sh --release --install` (quits and replaces the running Conduit) |
| Install helper | `sudo ./install-helper.sh`, required after any change to `Sources/ConduitHelper/` |

The `--dev` instance runs over `FakeMachine` with a scratch state directory under `$TMPDIR/conduit-dev` and ephemeral ports. Use `open -n`: a direct executable launch from an agent session has no window server access. Its `proxy.log` confirms the windows came up.

## Layout

Libraries (`Package.swift` is the authority; `docs/architecture.md` has the graph):

- `ProxyKernel`: proxy, PAC routing engine, DNS forwarding, tunnels, runtime events, and the protocols the other targets implement.
- `ProxyAuth`: NTLM and Kerberos/Negotiate authenticators and the auth factory. `ProxyPAC`: CFNetwork-backed PAC evaluation.
- `PlatformMac`: every machine side effect, the lifecycle policy both hosts share, and the fakes they run against.
- `ConduitShared`: the helper IPC contract, the daemon control protocol and the domain-name grammar. `ProxyControlBridge` maps kernel snapshots to control-protocol types.

Executables:

- `Conduit` (app) and `ConduitDaemon` are twin runtime hosts over the same managers. `ConduitHelper` is the privileged LaunchDaemon.
- Tools: `pm-proxy` (headless proxy), `pm-sim` (fault-injection scenarios), `pm-dns`, `pm-tunnel`, `pmctl` (daemon control client), and the `pm-*-check` diagnostics.

## Rules

### Never

- Never quit, kill or replace the running Conduit to test a build; it is serving the machine's proxy. Use the `--dev` instance. `bundle-app.sh --install` kills the running app, so nothing automated runs it while Conduit is serving.
- Never let `pm-proxy` touch the host: no system proxy, env file, `/etc/resolver`, login items or helper calls. That is what makes it safe for agents and CI.
- Never log a credential, cookie, bearer token or `Proxy-Authorization` payload. Credentials crossing modules are `SecretBytes`; log sinks mask `Authorization` and `Proxy-Authorization`.
- Never swallow an error: recover with a structured event that says how, or surface it with one that says why. A `try?` that discards a failure someone would need to diagnose counts as swallowing.

### Ask first

- A new dependency in `Package.swift`. Today the only one is `apple/swift-nio`.
- Widening `package` access to `public`, or exposing a concrete type across a target boundary where a protocol exists.
- An unbounded collection, queue, cache or timer. Every one has a fixed capacity in config; see `RuntimeEventLog`, `maxConnections` and `inboundConnectionMaxLimit`.
- A new `TODO`, `FIXME` or `XXX`. File an issue instead.

### Always

- Emit a `RuntimeEvent` first for every routing, auth, failover, health or config decision, and derive the log line from it. Events are the contract with the UI, `pmctl` and `pm-sim`. They are listed in `docs/events.md`; add new ones there.
- Put machine side effects behind a protocol in `PlatformMac`, with a fake in `Sources/PlatformMac/PlatformFakes.swift`.
- Validate at the boundary and trust inside: `ProxyConfig` in `ConfigValidation.swift`, network input in the NIO handlers. Inside, assertions catch bugs, not user errors.
- New runtime behaviour adds unit tests and a `pm-sim` scenario before it ships.
- JSON that leaves the process as a file or a stdout NDJSON stream (`events.ndjson`, `audit.ndjson`, `snapshot.json`, the `ready` file) uses `CanonicalJSON.encoder()` / `.decoder()`, so timestamps are Unix-epoch seconds. In-process round-trips (helper IPC, control protocol, Keychain envelope) may use plain `JSONEncoder`.

## Commits and pull requests

- Use git. Split commits by concern. A commit that is a fix on its own must build on its own; a multi-commit feature only has to build at the branch tip.
- A commit made with an AI tool ends with one `Co-Authored-By:` trailer naming the tool, for example `Co-Authored-By: Claude <model> <noreply@anthropic.com>`. The human committer is the author and is accountable.
- Never put a session, conversation or transcript URL in a commit message; it only resolves for the tool account's owner. Put it in the PR description, with the tool's "generated with" line.

## References

- `docs/architecture.md`: module graph and daemon/client shape.
- `docs/STYLE.md`: the full engineering discipline behind these rules.
- `docs/events.md`: the `RuntimeEvent` catalogue.
- `docs/roadmap-v2.md`: product plan.
- `docs/design-*.md`: subsystem designs (module split, VPN flap resilience, tunnel DNS override, DNS intercept and transparent proxy).
