# Contributing to Conduit

Thanks for considering a contribution! This document explains how to get started.

## Prerequisites

- macOS 26 (Tahoe) or later
- A Swift 6.2+ toolchain. The Command Line Tools are enough to **build**; **running the test suite** additionally needs Xcode 26+, because XCTest ships with Xcode rather than the Command Line Tools.
- Git

## Building

```bash
swift build
```

Or with the Xcode toolchain explicitly:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build
```

## Running Tests

Tests use XCTest, which is provided by Xcode (not the Command Line Tools), so
point `DEVELOPER_DIR` at Xcode when running them:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

All 1,500+ tests must pass before submitting a PR. The test suite includes unit tests, integration tests, and fault-injection scenarios.

## Trying a Change in the App

Do not quit or replace the Conduit that is serving your machine to look at a change. A
debug build has a dev mode that runs beside it over a fake machine and a scratch state
directory, so nothing it does reaches the system proxy, the shell environment, the
resolver files, the helper or the Keychain:

```bash
./bundle-app.sh
open -n -a "$PWD/Conduit.app" --args --dev --section dns --vpn utun4
```

It shows the menu bar popover in a "Popover preview" panel for screenshots and the
accessibility inspector, opens the app window on the section you name, keeps a Dock icon,
and badges its menu bar glyph with a dot. Launch it with `open -n`; running the executable
directly from a script shows nothing. `--upstream host:port` pointed at a running `pm-proxy`
gives a real "proxied" state, and `--dev-state-dir PATH` places the state (and its
`proxy.log`, which says when the windows came up) where you want it. See the toolchain
table in [`AGENTS.md`](AGENTS.md).

## Running the Headless Proxy

```bash
swift run pm-proxy --port 3128 --state-dir /tmp/pm-test
```

Then test with:

```bash
curl -x http://localhost:3128 https://httpbin.org/ip
```

## Project Structure

See [`docs/architecture.md`](docs/architecture.md) for the full module graph. The key invariant: `ProxyKernel` has **zero** Apple-framework imports beyond Foundation/Dispatch. The build enforces this - if you accidentally import `Security` or `SystemConfiguration` in a kernel file, `pm-proxy` will fail to link.

## Before You Submit

1. **Read the Product Pillars** in [`README.md`](README.md#product-pillars). Every change must serve at least one pillar: Reliability, Security, Efficiency, Observability, Great UI, Daemon-first, or Simulators & demos.

2. **Follow STYLE** ([`docs/STYLE.md`](docs/STYLE.md)):
   - Bound everything (no unbounded collections fed by network/timer input)
   - Assert invariants (precondition for bugs, throws for user errors)
   - Structured events first (emit `RuntimeEvent` before writing a log line)
   - Validate at the boundary, trust inside
   - No silent failures
   - Side effects behind protocols

3. **Tests are required.** New runtime behaviour adds unit tests and (where applicable) a `pm-sim` scenario. The full suite must stay green.

4. **Never commit secrets.** No credentials, tokens, `.env` files, or unmasked auth headers in source or logs.

5. **Respect the import fence.** `Sources/ProxyKernel/` must not import any Apple framework beyond Foundation and Dispatch. Platform-specific code belongs in `Sources/PlatformMac/`.

## PR Process

1. Fork the repo and create a feature branch from `main`.
2. Make your changes with clear, atomic commits.
3. Ensure `swift test` passes locally.
4. Open a PR with:
   - A description of what changed and why
   - Which pillar(s) the change serves
   - Any new test coverage added
5. Wait for CI to pass and a maintainer review.

## Code Style

- Swift 6 concurrency (`async/await`, `Sendable`, actor isolation)
- `package` access for cross-target internal APIs
- No force-unwraps (`!`) outside tests
- Prefer `precondition` over `fatalError` for invariant violations
- See [`docs/STYLE.md`](docs/STYLE.md) for the full discipline

## Reporting Issues

- **Security vulnerabilities**: see [`SECURITY.md`](SECURITY.md) - do NOT open a public issue
- **Bugs**: open a GitHub issue with reproduction steps
- **Feature requests**: open an issue explaining the use case and which pillar it serves

## License

By contributing, you agree that your contributions will be licensed under the [Apache License 2.0](LICENSE).
