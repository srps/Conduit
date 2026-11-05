# Contributing to Conduit

Thanks for considering a contribution. This guide covers how to build and run Conduit from source, how to test a change without touching the Conduit that serves your machine, and what a pull request needs.

If you are unsure whether a change fits, open a draft PR or an issue first. "Should we do this?" is a better conversation to have before the code than after.

## Product pillars

Every change is measured against these pillars. A proposed feature either lands under one of them or it doesn't ship. A change that fits none of them needs a short rationale for why it still belongs here. [`ROADMAP.md`](ROADMAP.md) tags each item with its pillars and adds an eighth, Open-source readiness.

| Pillar | What it means | How it's measured |
| --- | --- | --- |
| **Reliability** | No daily-driver regressions. Survives Wi-Fi, VPN, and captive-portal transitions. | Daily use. The `pm-sim` chaos suite is green. Zero "I had to restart it" moments per quarter. |
| **Security** | No secret leaks. PAC evaluation is sandboxed. Tunnel credentials can be rotated. | Reviewed threat model ([`docs/threat-model.md`](docs/threat-model.md)). Keychain audit. `Proxy-Authorization` is never logged. |
| **Efficiency** | Targets, not measured guarantees: under 40 MB RSS idle, under 3% CPU idle, under 50 ms added latency at p99. | Instruments profile under `pm-sim multi-100`. Long-run baseline. `scripts/perf-gate.sh` in CI. |
| **Observability** | Every routing, auth, failover, and health decision is a typed `RuntimeEvent`. | `ProxyOrchestratorSnapshot` is machine-consumable. NDJSON status stream. The agent harness asserts behaviour from events alone. |
| **Great UI** | The menu bar handles 90% of daily tasks. The main window follows the HIG. | Toggle the proxy, switch profile, test an upstream, and view health without opening the app. |
| **Daemon-first** | The runtime runs with no UI attached. The UI is a client. | `pm-proxy` serves traffic even with the GUI force-quit. |
| **Simulators & demos** | Every runtime behaviour is testable and demonstrable. | Every new behaviour ships with a `pm-sim` scenario. Demo mode shows the event stream live. |

## Where things are written down

- Priorities and status live in [`ROADMAP.md`](ROADMAP.md). Implementation rationale and acceptance criteria live in [`docs/planning.md`](docs/planning.md). Owner decisions live in [`docs/decisions/`](docs/decisions/README.md).
- The engineering discipline lives in [`docs/STYLE.md`](docs/STYLE.md): bound everything, assert invariants, emit structured events first, validate at the boundary, no silent failures, explicit resource lifetime, side effects behind protocols, security first, deterministic where possible.
- Agent and contributor guardrails (toolchain commands, import fences, judgment boundaries) live in [`AGENTS.md`](AGENTS.md). Humans and AI assistants both read that file first. It supersedes informal conventions.
- The module graph and request flow live in [`docs/architecture.md`](docs/architecture.md). Runtime events are catalogued in [`docs/events.md`](docs/events.md).

## Prerequisites

- macOS 26 (Tahoe) or later on Apple Silicon
- A Swift 6.2 or later toolchain. The Command Line Tools are enough to **build**. **Running the test suite** also needs Xcode 26 or later, because XCTest ships with Xcode rather than the Command Line Tools.
- Git

## Build

```bash
swift build
```

Or with the Xcode toolchain explicitly:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build
```

### Open in Xcode

Open the cloned `Conduit` package directory in Xcode. Xcode opens Swift packages natively, resolves the `swift-nio` dependency graph, and runs the macOS app target.

## Run the headless proxy

`pm-proxy` never touches the host: no system proxy, environment file, `/etc/resolver`, login items, or helper calls.

```bash
swift run pm-proxy --port 3128 --state-dir /tmp/pm-test
```

Then test it:

```bash
curl -x http://localhost:3128 https://httpbin.org/ip
```

[`docs/getting-started.md`](docs/getting-started.md) covers upstream configuration and auth modes.

## Run the DNS forwarder on its own

```bash
swift run pm-dns --minimal --port 5353 --verbose
```

Point your system DNS at `127.0.0.1`. Queries for internal domains then go through corporate DNS, and external domains resolve through DoH. In the app, **Manage system DNS** does this for you.

## Try a change in the app

Do not quit or replace the Conduit that is serving your machine to look at a change. A debug build has a dev mode that runs beside it over a fake machine and a scratch state directory. Nothing it does reaches the system proxy, the shell environment, the resolver files, the helper, or the Keychain through those injected collaborators.

The dev bundle `Conduit Dev.app` has its own ad-hoc-signed bundle identity and selects dev mode by itself:

```bash
./bundle-app.sh --dev
open -n -a "$PWD/Conduit Dev.app" --args --section dns --vpn utun4
```

An ordinary local bundle with an explicit `--dev` still works:

```bash
./bundle-app.sh
open -n -a "$PWD/Conduit.app" --args --dev --section dns --vpn utun4
```

Build-time `--dev` refuses `--install`, `--release`, and `--share`.

Dev mode still uses the real notification manager and network-path monitor. An app-bundle launch can request notification permission and post notifications. It also writes scratch files and can make network requests to configured endpoints. Use synthetic configurations on personal machines. The missing notification and network-monitor injection points are tracked in [`docs/refactor-notes-2026-09-09.md`](docs/refactor-notes-2026-09-09.md).

The dev instance shows the menu bar popover in a "Popover preview" panel for screenshots and the accessibility inspector. It opens the app window on the section you name, keeps a Dock icon, and badges its menu bar glyph with a dot, so you can tell it apart from the installed app.

Launch it with `open -n`, which starts a new instance instead of activating the installed app. Running the executable directly works from a terminal, but from a script or an agent session it has no window server access and shows nothing.

For a real "proxied" state, point the dev instance at a side-effect-free `pm-proxy`:

```bash
swift run pm-proxy --port 3129 --state-dir /tmp/pm-dev --status-interval 5      # terminal 1
open -n -a "$PWD/Conduit Dev.app" --args --upstream 127.0.0.1:3129             # terminal 2
```

State lives under `$TMPDIR/conduit-dev`, or under `--dev-state-dir PATH`. The state directory's `proxy.log` says when the preview window and the app window came up, which is what a script checks instead of a screenshot.

The production flags `--port`, `--no-system-proxy`, and `--no-env` still work on their own for a second real instance. That instance talks to the real helper.

## Build and install the app from source

Build, bundle, and install to `/Applications` in one step. This quits and replaces a running Conduit.

```bash
./bundle-app.sh --install
```

For an optimized release build:

```bash
./bundle-app.sh --release --install
```

To make a local bundle that stays in the project directory:

```bash
./bundle-app.sh
open Conduit.app
```

Once installed, the app is in Spotlight, Launchpad, and **Finder > Applications**. To pin it to the Dock, right-click its Dock icon and choose **Options > Keep in Dock**. The **Launch at Login** setting needs the app in `/Applications`.

On first launch macOS may show a Gatekeeper warning ("cannot verify the developer"), because the app is not notarized. Release builds carry a self-signed certificate and local builds a self-signed or ad-hoc signature. Right-click the app, choose **Open**, and click **Open** in the dialog. You need to do this only once.

### Share a test build

To make an optimized test build for another Mac with the same architecture:

```bash
./bundle-app.sh --share
```

Send the ZIP under `.build/share/`. It keeps executable permissions and uses ad-hoc signing instead of the builder's local signing certificate. The app needs macOS 26 or later. This build is not notarized, so the recipient may need to approve it in **System Settings > Privacy & Security**. It does not install or replace the app on the builder's Mac. An existing helper pinned to a different signing identity refuses this build. Managed proxy and system DNS settings need helper v5. See [release installation](docs/release-installation.md) for the bundled installer and the signing-policy implications.

### Package a release

Maintainers can run `bash scripts/package-release.sh` to also create a disk image with an Applications shortcut and SHA-256 checksums. `VERSION` sets the app and asset versions. The Release packages workflow builds and tests the Apple Silicon package on pull requests that change packaging, or when run manually. After merging, push a matching `v<version>` tag to prepare a draft GitHub release with the installable packages attached. Review the draft and publish it when ready. [Release signing](docs/release-signing.md) describes the certificates.

## Set up the privileged helper from a source build

Managed system proxy and system DNS settings need helper v5. Resolver writes and the port-53 DNS relay also need admin authorization. Install the privileged helper once:

```bash
./bundle-app.sh --install
sudo ./install-helper.sh
```

The install script finds the helper binary in the installed app bundle in `/Applications`, then the local bundle, then the build directory. It installs a LaunchDaemon that runs as root. The app talks to it over a Unix domain socket at `/var/run/io.github.srps.Conduit.Helper.sock`. After installation, proxy enable and disable, DNS changes, and the port-53 relay happen with no further admin prompts.

You can also install and uninstall the helper from the app, in **Conduit > General > Privileged Helper**.

### Pin the helper to your build

Unless it is told which program to trust, the helper admits any process of the console user. To pin it to Conduit, create a local signing identity once, then build, install, and install the helper:

```bash
scripts/create-signing-identity.sh      # once; self-signed "Conduit Local Signing" in your login keychain
./bundle-app.sh --release --install     # signs with it and the hardened runtime
sudo ./install-helper.sh                # pins that certificate for the helper's callers
```

The pin is the certificate, so later app builds signed with the same identity need no helper reinstall. When the app carries the published release certificate (`Resources/release-signing.pem`, bundled beside `install-helper.sh`), the pin admits that certificate too, so GitHub releases keep working beside your local builds. See [release signing](docs/release-signing.md).

- `./install-helper.sh --print-caller-requirement /Applications/Conduit.app` shows the pin without installing anything.
- A pinned helper refuses an app signed ad-hoc, with a message that points here. Reinstalling the helper from an ad-hoc app removes the pin.
- `ConduitDaemon` is not bundled. To run it against a pinned helper, sign it as the pin expects: `codesign -f -o runtime -s "Conduit Local Signing" -i io.github.srps.Conduit.Daemon <path to ConduitDaemon>`.

### Update or remove the helper

> [!IMPORTANT]
> After a change to `Sources/ConduitHelper/`, or an app update that adds helper commands, reinstall the helper. `install-helper.sh` does not build, so build first.

```bash
sudo ./install-helper.sh
```

To remove the helper:

```bash
sudo ./uninstall-helper.sh
```

Location-scoped proxy and system DNS operations do not fall back to admin prompts when the helper is missing or outdated. Update the helper before you enable those settings.

### Read the logs

The helper logs to the unified log. The app mirrors its own log lines there under the same subsystem, so one query reads both processes in order:

```bash
/usr/bin/log show --predicate 'subsystem == "io.github.srps.Conduit"' --info --last 1d
```

Use `/usr/bin/log`, because zsh has a `log` builtin that shadows the command.

The app's own log file is `~/Library/Logs/Conduit/proxy.log`. It is on by default and rotates at 5 MiB, keeping three files.

## Run the tests

Tests use XCTest, which Xcode provides and the Command Line Tools do not, so point `DEVELOPER_DIR` at Xcode:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

Run the full suite before you submit a PR, and account for any expected skips in the CI result. The suite has unit tests, integration tests, and fault-injection scenarios. Run a single simulator scenario with `swift run pm-sim <scenario>`, or all of them with `swift run pm-sim all`. Scenarios live in `Sources/pm-sim/`.

Before pushing, run every step of [`.github/workflows/swift.yml`](.github/workflows/swift.yml), not only `swift test`. That means at least `pm-sim all`, the `scripts/check-*.py` and `scripts/test-*.py` checks, and `scripts/perf-gate.sh`.

Coverage includes NTLM, PAC routing and CFNetwork PAC evaluation, the DoH DNS forwarder, DNS wire format and poisoning resistance, UDP and TCP relay forwarding, system DNS management, config migration, upstream failover, the circuit breaker and EWMA, direct-connect detection, event loop safety, the helper contract, keychain credential management, the metadata blocklist, tunnel exemption, IPv6 parsing, body buffering, the SNI parser (ClientHello parsing, hostname validation, and random-garbage false positives), DNS intercept rules, transparent proxy config, logging sanitization, local PAC serving, and autoproxy URL validation.

## Project structure

[`docs/architecture.md`](docs/architecture.md) has the full module graph, the dependency matrix, and what each target owns. [`docs/design-module-split.md`](docs/design-module-split.md) explains how the original monolith split into the kernel, auth, PAC, and platform targets. `Package.swift` is the authority. In short:

- `ProxyKernel` is the portable library with all non-UI, non-platform logic: proxy, PAC routing engine, DNS forwarding, UDP relay, tunnels, models, and the runtime event envelope. Its imports are fenced, as described below.
- `ProxyAuth` holds the NTLM and Kerberos authenticators, using GSS and CommonCrypto. `ProxyPAC` evaluates PAC files through macOS CFNetwork, for parity with Safari.
- `PlatformMac` is the macOS glue: Keychain, `networksetup`, `SMAppService`, `SCDynamicStore`, `NWPathMonitor`, the helper client, the `/etc/resolver` writer, and TLS-inspection diagnostics. It also holds the fakes the hosts run against in tests.
- `RuntimeEvents` holds the typed domain event values. `ConduitRuntime` is the shared `RuntimeHost` that the app and `ConduitDaemon` compose.
- `ConduitShared` is the helper IPC contract, the daemon control protocol, and the domain-name grammar. `ProxyControlBridge` maps kernel snapshots to control-protocol types.
- `Conduit` is the macOS GUI app. `ConduitHelper` is the privileged LaunchDaemon for system proxy, DNS changes, and the port-53 UDP relay. `ConduitUpdater` is the nested self-updater and the only target that links Sparkle.
- `pm-proxy` is the headless proxy. It does not link `PlatformMac`, and the build is the test. The tools `pm-sim` (fault injection), `pm-dns` (standalone DoH forwarder), `pm-tunnel` (TCP forwarder), `pmctl` (control client), and the diagnostics `pm-vpn-check`, `pm-auth-check`, and `pm-tls-check` (TLS inspection and CA export) round out the executables.
- `ConduitTests` holds the automated regression tests.

Cross-target calls go through protocols in `Sources/ProxyKernel/Abstractions/`, listed in [the architecture doc](docs/architecture.md#abstractions-directory-the-seam). Kernel types use Swift's `package` access level, which makes them visible within the SwiftPM package but not outside it.

The kernel import allowlist is Foundation, Dispatch, the linked NIO modules, Darwin and Glibc, and `ConduitShared` for domain-name grammar. Apple platform frameworks belong behind protocols in `ProxyAuth`, `ProxyPAC`, or `PlatformMac`. CI enforces imports with [`scripts/check-kernel-imports.py`](scripts/check-kernel-imports.py), which asks the Swift compiler what each file imports in debug and release. Linking alone cannot enforce this fence. Naming `Process` in the kernel does not compile, and the script rejects a qualified `Foundation.Process` in the built object.

## Before you submit

1. **Fit a pillar.** Every change must serve at least one of the [product pillars](#product-pillars).

2. **Follow [`docs/STYLE.md`](docs/STYLE.md).**
   - Bound everything. No unbounded collections fed by network or timer input.
   - Assert invariants. Use `precondition` for bugs and `throws` for user errors.
   - Emit a structured `RuntimeEvent` before writing a log line.
   - Validate at the boundary and trust inside.
   - No silent failures.
   - Put side effects behind protocols.

3. **Add tests.** New runtime behaviour adds unit tests and, where applicable, a `pm-sim` scenario before it ships. The full suite must stay green on Xcode's toolchain (`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test`).

4. **Never commit secrets.** No credentials, tokens, `.env` files, or unmasked auth headers in source or logs.

5. **Respect the import fence.** After `swift build`, run `DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" python3 scripts/check-kernel-imports.py`.

## PR process

1. Fork the repo and create a feature branch from `main`.
2. Make your changes in clear, atomic commits.
3. Make sure `swift test` passes locally.
4. Open a PR with:
   - A description of what changed and why
   - Which pillars the change serves
   - Any new test coverage
5. Wait for CI to pass and a maintainer review.

## Code style

- Swift 6 concurrency (`async`/`await`, `Sendable`, actor isolation)
- `package` access for cross-target internal APIs
- No force-unwraps (`!`) outside tests
- Prefer `precondition` over `fatalError` for invariant violations
- See [`docs/STYLE.md`](docs/STYLE.md) for the full discipline

## Report issues

- **Security vulnerabilities.** See [`SECURITY.md`](SECURITY.md). Do not open a public issue.
- **Bugs.** Open a GitHub issue with reproduction steps.
- **Feature requests.** Open an issue that explains the use case and which pillar it serves.

## License

By contributing, you agree that your contributions are licensed under the [Apache License 2.0](LICENSE).
