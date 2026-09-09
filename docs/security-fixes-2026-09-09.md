# S01–S03 remediation and CLT validation

This records fixes to the first three findings in [the source review](review-2026-09-09.md). Validation used the personal M4 Air, synthetic credentials, scratch state directories, and loopback servers. No company configuration, VPN access, Keychain credentials, helper installation, or system network changes were needed.

## Changes

### S01: upstream credential eligibility

The authenticator factory now receives an `UpstreamProxy` throughout the kernel, including both CONNECT and pooled HTTP authentication. It matches the actual destination against enabled configured upstreams using case-insensitive host comparison and an exact port. An unknown or disabled endpoint emits `auth.upstream_not_trusted` and throws before an authenticator or credential lookup is created. There is no fallback to the first configured upstream.

The configured endpoint is the credential grant within the active profile. PAC cannot create that grant. A PAC deployment using additional upstream endpoints must list them explicitly in Upstreams to use Conduit's authenticated path. Host aliases are separate grants; DNS is not used to infer equivalence. Existing profile-wide credential storage remains unchanged.

Kerberos construction still avoids reading NTLM credentials. Authentication continues to reuse one authenticator per handshake. The tests do not invoke real GSS or a ticket cache.

### S02: rejected configuration loads

Runtime configuration reads and JSON decoding now throw on corrupt data, unsupported future schemas, and I/O errors. Defaults remain available for a genuinely missing implicit first-run file or explicit `--minimal` mode. An explicit missing `--config`, malformed `--config-json`, or a missing file during reload is rejected.

`pm-proxy`, `pm-dns`, `pm-tunnel`, and `ConduitDaemon` stop startup and emit a structured rejection when loading fails. `pm-proxy` control reload returns an existing `invalid_request` response; SIGHUP reports the same rejection through the event stream. Rejected reloads in both runtime hosts retain the previous configuration and generation. Blocking validation errors are rejected before applying a reload.

The app stays available to display the load error, with activation and saving blocked so display defaults cannot replace the file or start a runtime. Repair the file and restart the app. Journal-backed recovery of orphaned system proxy/DNS settings still runs after a configuration failure; only legacy resolver-ownership inference is withheld because it requires valid runtime configuration.

Aggregate app/daemon loading stages runtime, platform, and preference configuration before migration can write any files. Malformed or unreadable sidecars reject the candidate and remain untouched; legacy extraction is available only when a sidecar is absent. Rejected reloads preserve all three in-memory configurations and their generation. The daemon runs blocking semantic validation on the staged runtime candidate before any migration is persisted.

Missing runtime configuration is accepted only for a genuine first run. Existing platform/preferences files or a platform journal identify established app/daemon state; runtime-only loaders also recognize prior snapshots, events, or readiness files. Deleting `config.json` while that state remains now rejects startup. Use explicit `--minimal` for a file-free headless run in a reused state directory.

This does not change the product's intentional direct-mode policies, such as the behavior for unreachable upstreams. It prevents read/decode failures from silently replacing a configured policy with defaults.

### S03: loopback listeners

Outside gateway mode, the proxy bind must be an IPv4 loopback literal in `127/8`, IPv6 `::1` (including equivalent expanded/bracketed forms), or `localhost`. The name `localhost` is pinned to `127.0.0.1`, so ambient DNS cannot turn it into a LAN bind. Other hostnames, non-loopback literals, and wildcard addresses are rejected.

Gateway mode keeps the existing proxy client filter. DNS has no such filter, so its configuration and actual UDP/TCP startup boundary require loopback even in gateway mode. HTTP/SOCKS binding, manual system proxy settings, environment URLs, emitted PAC directives, and internal DoH proxy routes use the normalized address. IPv6 URL authorities retain brackets. No LAN binding was used for validation.

## Validation

CLT identifies its compiler as Swift 6.4. The default macOS 27 SDK build encounters a missing `SwiftUIMacros` plugin. All products, including the app, build successfully using the macOS 26.5 SDK already present in this CLT installation:

```sh
DEVELOPER_DIR="/Library/Developer/CommandLineTools" xcrun swift build \
  --build-system native \
  --sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
```

`native` is accepted by this SwiftPM version but emits a deprecation warning. This is a local toolchain workaround, not a package dependency or deployment-target change.

Passed:

- `.build/debug/pm-sim security-boundaries`: unknown host, same host/different port, disabled and removed endpoints; both authentication modes; case normalization; lazy credential access; valid/invalid/missing/unreadable configuration; future schema rejection; rejected files remain unchanged; IPv4/IPv6 bind policy; real DNS UDP/TCP localhost binding; successful HTTP/CONNECT endpoint propagation and denied untrusted authentication through both network paths.
- `python3 scripts/test-security-boundaries.py`: startup failures, first run and minimal mode, unsafe-bind rejection, actual HTTP/SOCKS/DNS localhost bindings, rejected control and SIGHUP reloads preserving status/generation/listeners, and successful reload after repairing the file.
- Existing `pm-sim auth-storm` and `pm-sim failover` scenarios completed. Auth-storm reported 22 rejections from 24 clients with a per-source limit of 2; failover's two health probes succeeded through the surviving synthetic upstream.
- Explicit malformed configuration launches of `pm-dns`, `pm-tunnel`, and `ConduitDaemon` exited nonzero with `config.load_rejected`.
- `git diff --check`.

The app and daemon XCTest harnesses include regressions for blocked startup/save, preservation after rejected reload, and journal recovery despite a corrupt config. Local execution is unavailable: even with SDK 26.5, `swift test` fails with `no such module 'XCTest'`. Initial PR #26 CI passed the full Xcode build, 1,531 tests (3 skipped, 0 failures), headless regressions, and performance gate at `609cfa495f77`. The subsequent crash-recovery and strict-sidecar additions require their own green CI run before merging. A larger Mac is unnecessary for these build and headless checks.

Other findings from the architectural/security review remain outside this change.
