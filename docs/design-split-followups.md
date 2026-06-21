# Kernel/Platform Split — Follow-Up Work

> **Status (revised 2026-04-27):** originally written after the module split (2026-04-22) for four follow-ups; refreshed after the auth-runtime fix (`fix(auth): surface Kerberos→NTLM fallback as event/UI; bound lateBoundAuthenticatorProvider stack growth`) landed on `fix/auth-runtime-outcome-and-stack-leak`. CFNetwork PAC and `SecretBytes` have shipped; the dependent log-sink/event-detail sanitization has also shipped. The fifth bonus follow-up (headless auth-event surfacing) is partially shipped: `pm-proxy` now wires auth outcomes into the orchestrator, while `pm-tunnel` still has no event carrier.
>
> **Note on identifiers:** vendor-specific names were neutralized for the public release — where a type or file appears with a generic name (e.g. `CorporateDefaults`), the original in git history used a vendor-specific name; treat these as scrubbed placeholders, not literal historical filenames.

## Context

The module split finished on 2026-04-22. The kernel is now import-fence-clean (four CI greps + one `otool` check enforce it), every cross-target call goes through a `package protocol` in `Sources/ProxyKernel/Abstractions/`, and `pm-proxy` links zero Apple frameworks beyond `Foundation` / `Dispatch` / `CoreFoundation` / NIO.

The split was instrumentally valuable: it unblocked four follow-ups that had been waiting on a stable kernel shape. The auth-runtime fix that followed the split added a fifth opportunity. This doc plans each of them.

| #  | Follow-up                 | Triggered by         | Blocks                          | Size        | Status  |
| -- | ------------------------- | -------------------- | ------------------------------- | ----------- | ------- |
| 1 | CFNetwork PAC swap        | the `PacEvaluator` seam | —                            | ~300 LOC    | Shipped and graduated (2026-04-26): `CFPACEvaluator` is the sole PAC evaluator; `PACResolver` / `PACScriptEvaluator`, the Settings experimental toggle, `pm-proxy --cf-pac`, and `import JavaScriptCore` were removed. |
| 2 | `SecretBytes` type        | the widened `CredentialProvider` | Log-sink sanitization | ~200 LOC + boundary audit | Shipped (2026-04-23) — `SecretBytes` at every in-memory credential boundary; `ProxyCredentials.ntHash` retyped from `Data`. Dependent log-sink and event-detail sanitization shipped 2026-04-26. |
| 3 | Vendor preset → JSON      | the vendor-neutral `testFixture()` | OSS release            | Mechanical + test sweep  | Shipped: the hardcoded vendor-specific Swift defaults file was removed; presets now live under `Sources/ProxyKernel/Resources/Presets/` as JSON, and persistence falls back to generic defaults. |
| 4 | `PlatformIntegration`     | the control-plane reload path landing first | `pmctl reload`        | TBD — shape falls out of the daemon call sites | Not ready (needs daemon-first context) |
| 5 | Headless auth-event surfacing | the auth-runtime observability fix | Future `pm-sim auth-storm` scenarios | ~50 LOC + 1 test | Partially shipped 2026-04-26: `pm-proxy` now passes `outcomeHandler` and snapshots/events reflect auth outcomes; `pm-tunnel` remains deferred until it has an event carrier. |

The standalone vendor-preset externalization (§3) has shipped. `pm-tunnel` auth-event surfacing is deferred until there is an event carrier, and `PlatformIntegration` is explicitly a downstream consequence of the daemon-first work — see §4.

## 1. CFNetwork PAC swap

**Goal.** Replace `PACResolver`'s JavaScriptCore backend with `CFNetworkExecuteProxyAutoConfigurationURL`. Safari-parity PAC evaluation. OS-patched. One fewer framework link (`JavaScriptCore` drops out of `ProxyPAC`).

**Status (2026-04-26):** **Shipped and graduated.** `CFPACEvaluator` is now the only production `PacEvaluator`; `PACResolver` / `PACScriptEvaluator` were deleted, the Settings toggle and `pm-proxy --cf-pac` were removed, and `Sources/` no longer imports JavaScriptCore. The implementation landed alongside Local PAC serving; the original dual-impl ramp plan below is preserved for historical context.

### Why now

- `ProxyPAC` is a one-file target (`PACResolver.swift`, ~315 LOC). Low surface, narrow blast radius.
- The split established `PacEvaluator` + `PacScriptEvaluating` as the protocol seam. The kernel's `PACRoutingEngine` stores `any PacEvaluator` — it doesn't care which backend answers.
- Every v2 security audit of PAC handling surfaces the same concern: JavaScriptCore is a full JS engine running scripts fetched over HTTP/S from untrusted URLs. CFNetwork's PAC evaluator is OS-sandboxed and patched in line with Safari.
- No other follow-up depends on this; it can land solo.

### Shape

Introduce a second `PacEvaluator` conformer next to the existing `PACResolver`:

```swift
// Sources/ProxyPAC/CFPACEvaluator.swift  (new)

package final class CFPACEvaluator: PacEvaluator {
    package init() {}

    package func fetchPAC(from url: URL) async throws -> String {
        // CFNetwork doesn't expose the raw script text; this method becomes
        // a pass-through "I'll evaluate by URL, you don't need the text"
        // signal. The JS-backend version of this method still does the
        // network fetch — this is the divergence the two-protocol shape
        // accommodates: fetch + evaluate are different lifetimes.
        throw PACEvaluatorError.fetchNotApplicable
    }

    package func makeEvaluator(pacScript: String) throws -> any PacScriptEvaluating {
        // CFNetwork evaluates scripts from a URL or from raw data via
        // `CFNetworkCopyProxiesForAutoConfigurationScript`. Wrap that in
        // a `PacScriptEvaluating`-conformer.
        CFPacScriptEvaluator(script: pacScript)
    }

    package func routeChain(for directives: String) -> [PACRoute] {
        // Same as PACResolver — the directive-parsing is JS-engine-independent.
        PacDirectiveParser.parse(directives)
    }
}

package final class CFPacScriptEvaluator: PacScriptEvaluating {
    private let script: String
    init(script: String) { self.script = script }

    package func resolveProxyChain(for url: URL) throws -> [String] {
        // Call CFNetworkCopyProxiesForAutoConfigurationScript; convert
        // CFArray<CFDictionary> to the same `[String]` directive form that
        // today's PACResolver produces (`"PROXY host:port"`, `"DIRECT"`).
        ...
    }
}
```

Wiring:

- `AppState` + `pm-proxy` keep constructing `PACResolver()` (the existing JS-backed impl) by default. A new CLI flag + Settings toggle selects `CFPACEvaluator`.
- Feature flag lives in `ProxyConfig.experimentalCFPacEvaluator: Bool` (defaults to `false` for one release, then flips to `true`, then `PACResolver` is removed in the release after that).
- No API change for `PACRoutingEngine` — it already stores `any PacEvaluator`. Swap happens at construction.

### What's unblocked

- Removing `import JavaScriptCore` from the codebase entirely (after one release of dual-impl).
- OS security updates apply automatically; we stop owning a JS-engine-sized attack surface.

### Non-goals

- **No behaviour-change beyond the backend swap.** Same routing decisions, same fallback chain, same DNS callbacks (CFNetwork exposes `dnsResolve`/`myIpAddress` natively — we drop our Swift reimplementations of those when we cut JS-backend support).
- **No changes to PAC fetching.** `AppState.curlPACFetcher` + URLSession default stay as they are. CFNetwork takes a URL; we pass the same one the JS engine got.
- **No PAC-serving work** (roadmap item; separate from evaluator).

### Scope sketch

- `Sources/ProxyPAC/CFPACEvaluator.swift` — new file (~150 LOC)
- `Sources/ProxyPAC/PACResolver.swift` — `@available(*, deprecated)` marker in the final removal PR; unchanged until then (~0 LOC)
- `Sources/ProxyKernel/Models/ProxyConfig.swift` — one Bool field + `decodeIfPresent` back-compat (~10 LOC)
- `Sources/Conduit/App/AppState.swift` — conditional construction (~15 LOC)
- `Sources/pm-proxy/PMProxy.swift` — new CLI flag (~10 LOC)
- Tests — `CFPACEvaluatorTests` with the same corpus that `PACResolverTests` uses today (~150 LOC)

Total: ~300 LOC net + one new test file that parallels the existing PAC test coverage.

### Ordering

Independent. Land before or after `SecretBytes`; no interaction.

---

## 2. `SecretBytes` opaque credential type

**Goal.** Replace `String` / `Data` at every credential boundary with a zero-on-deinit byte container that cannot be `description`-logged, `debugDescription`-logged, or `Codable`-serialized. Closes the "credentials accidentally leak into a stderr dump / error description / JSON export" failure mode.

**Status (2026-04-26):** **Shipped** in `feat: SecretBytes opaque credential container + ProxyCredentials retype` (2026-04-23). Refined by `refactor(Security): update SecretBytes initializers to accept Collection<UInt8> and improve memory handling`. New file `Sources/ProxyKernel/Security/SecretBytes.swift`; `ProxyCredentials.ntHash` retyped from `Data` to `SecretBytes`; consumers updated in `ProxyAuth/NTLMAuth.swift`, `PlatformMac/CredentialManager.swift`, `PlatformMac/KeychainStore.swift`, `Conduit/App/AppState.swift`. The `KeychainPayload` keeps `Data` for the bespoke Keychain wire format with explicit conversion at the boundary. Three structural defenses landed as designed below: redacted print/dump/Mirror, no `Codable` conformance, zero-on-`deinit`. The dependent log-sink/event-detail sanitisation work (mask `Authorization` / `Proxy-Authorization` / `Cookie` / `Set-Cookie` / bearer tokens in durable output) shipped later the same day.

**Status note (pre-ship, after the auth-runtime fix):** plan verified against the new branch state. One additive note (the `outcomeHandler:` parameter on `credentialBasedAuthenticatorProvider` is orthogonal to the inner `ProxyCredentials.ntHash` retype that drives this work) and one new lesson on storage patterns — see "Storage pattern note" subsection below.

### Why now

- The split widened `CredentialProvider` to `credentials(for: UpstreamProxy) throws -> ProxyCredentials?` + `setCredentials(_:for:)`. Every credential boundary is now a protocol call. The boundaries are visible; the rewrite is mechanical.
- This has been wanted since before the split. Pre-split, "find every credential boundary" was a grep exercise; post-split it's a protocol-surface inventory.
- Log-sink sanitization (the sibling security task) consumes this: once credential fields are `SecretBytes`, the sanitization pass that masks `Authorization` / `Proxy-Authorization` / `Cookie` headers can refuse to print any `SecretBytes` value, belt-and-braces.

### Storage pattern note

The auth-runtime fix resolved a stack-frame leak in `lateBoundAuthenticatorProvider` where `NIOLockedValueBox<@Sendable (String) throws -> ProxyAuthenticator>` accumulated `~4` reabstraction-thunk frames per CONNECT handshake (~550 calls → stack-guard hit). Root cause: `NIOLockedValueBox.withLockedValue<R>(_ body: (inout T) throws -> R)` re-thunks closure-typed values through `@in_guaranteed`/`@guaranteed` ABI on every body invocation and writes the re-thunked value back to storage. The fix introduced `AuthProviderHolder` — a small `class { var; NIOLock }` holder that reads via direct stored-property load (no inout, no body closure, no reabstraction). See the file header at `Sources/ProxyKernel/Proxy/ProxyOrchestrator.swift:138-171` and the regression test `AuthProviderStackDepthTests.testLateBoundProviderFrameCountIsBounded`.

**General rule for SecretBytes (and any future shared mutable state holding non-trivial Sendable types):**
- `NIOLockedValueBox<T>` and `Synchronization.Mutex<T>` are safe for **value types** (`ProxyConfig`, `LogLevel`, `Int`, `Bool`, etc.) — the `inout T` body contract reabstracts cheaply for trivially-copyable T.
- For **closures, existentials, type-erased Sendables, and unsafe pointers**, use a hand-rolled `class + NIOLock + read-into-local-let-then-act` pattern.

`SecretBytes` lives on the second list:
- It owns an `UnsafeMutableBufferPointer<UInt8>` (non-trivial, must be deterministically released)
- It needs `deinit` to call `explicit_bzero` (only `class` types have `deinit`)
- Concurrent reads (auth handshakes can dispatch from multiple NIO event loops simultaneously) must not interleave with the (rare) overwrite-via-`setCredentials`

Apply the `AuthProviderHolder` pattern: class-backed storage, `NIOLock` (or `os_unfair_lock` directly), `withUnsafeBytes` reads through a local-let snapshot. Do **not** wrap the buffer pointer in `NIOLockedValueBox<UnsafeMutableBufferPointer<UInt8>>` — same footgun.

### Sidebar: why we didn't do the inverted-ownership refactor

A genuinely cleaner architectural fix to the late-bound-auth problem would be **inverted ownership**: AppState constructs the `configBox` itself, derives `configSnapshotProvider`, builds the auth factory closure with it, and passes both into the orchestrator at init. This eliminates `AuthProviderHolder`, `setAuthenticatorProvider`, and the orchestrator's internal `configBox` simultaneously. The orchestrator becomes immutable wrt config + auth-factory storage; the caller owns the lifecycle.

Deferred because: the daemon-first `DaemonHost` will naturally do this inversion as a byproduct of its larger restructuring (per §4 below — `DaemonHost` is the type that wraps `ProxyOrchestrator + platform wiring` and grows the control-plane reload path). Doing the inversion now means doing it twice. The local `AuthProviderHolder` fix is correct, small, and tested; deferring the broader refactor to the daemon-first work keeps the change set bounded.

This sidebar exists so a future reader who notices the same architectural smell finds the explicit "yes we considered it; here's why we deferred" rather than re-deriving it from scratch.

### Shape

```swift
// Sources/ProxyKernel/Security/SecretBytes.swift  (new)

package struct SecretBytes: Sendable {
    private var storage: UnsafeMutableBufferPointer<UInt8>
    private let len: Int

    package init(_ bytes: [UInt8]) { ... }
    package init(utf8 string: String) { ... }

    package func withUnsafeBytes<R>(_ body: (UnsafeBufferPointer<UInt8>) throws -> R) rethrows -> R { ... }

    // Deliberately no description / debugDescription / CustomStringConvertible /
    // CustomDebugStringConvertible / Encodable. Printing `someSecret` logs
    // `"SecretBytes(<redacted, 16 bytes>)"` via the fixed stub below.

    package func zero() { /* explicit_bzero on the storage */ }
}

// File-scope: the only printable representation.
extension SecretBytes {
    package func redactedDescription() -> String {
        "SecretBytes(<redacted, \(len) bytes>)"
    }
}

// Zero on deinit; storage lives as a class-backed reference so copies
// share the same zeroed backing when the last holder drops.
```

Touchpoints:

- **`ProxyCredentials`** — `ntHash: Data` becomes `ntHash: SecretBytes`. `username` / `domain` / `workstation` stay `String` (they're not secrets). `keychainData()` serializer uses `withUnsafeBytes` to avoid materializing the secret as a `Data`.
- **`CredentialProvider`** — the protocol shape doesn't change (still `ProxyCredentials`-typed); only the inner field is opaque.
- **`AuthenticatorFactory.credentialBasedAuthenticatorProvider`** — the closure hands off the `SecretBytes` to NTLM/Negotiate token generators. NTLM token generation already operates on raw bytes; the API boundary becomes `withUnsafeBytes { bytes in ... }`. The factory's outer signature gained an `outcomeHandler: (RuntimeAuthOutcome, String, String?) -> Void` parameter in the auth-runtime fix; **SecretBytes does not widen the factory signature further** — it only flips the inner `ProxyCredentials.ntHash` field type. The outcome callback fires on Kerberos success / NTLM fallback events and never sees the credential bytes.
- **`KeychainStore`** — `save(data: Data, account:)` becomes `save(secret: SecretBytes, account:)`. Same Keychain binding; the `Data` intermediate disappears.
- **`AppState.savePassword(_:)`** — takes `String` from the UI (password field), converts to `SecretBytes` at the boundary, discards the `String` immediately. This is the one site where plaintext passwords still transit Swift's String storage; we can't eliminate that without a SwiftUI `SecureField` API change, but we can shrink the lifetime to a single call stack.
- **Log sanitization** — every `LogSink` conformer refuses to print `SecretBytes` via the `redactedDescription()` stub. The `@autoclosure` call site path means you can't even accidentally string-interpolate a `SecretBytes` into a message that then gets filtered out.

### What's unblocked

- Log-sink sanitization assertion: *"No log line contains an unmasked base64 token > 64 chars."*
- Keychain ACL tightening to `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`; once credentials are opaque in-process, restricting at-rest access is the natural next hardening step.
- Future audit-log expansion: credential-ID-only references in `events.ndjson` and the planned `audit.ndjson` — no accidental content leak.

### Non-goals

- **No migration of `username` / `domain` / `workstation` to `SecretBytes`.** These are identity, not secrets. Principal names show up in Kerberos event logs unmasked today and should continue to — masking them would hurt diagnostics.
- **No cryptographic guarantees beyond "zero on deinit."** `SecretBytes` is a safety net against accidental logging, not an HSM. A compromised process can still read the bytes while the buffer is live. That threat model is out of scope for a user-space proxy.
- **No `Encodable`.** Persisted credentials round-trip via the existing `keychainData()` explicit serializer; there is no code path that needs to `JSONEncoder().encode(creds)`.
- **No `CodingKeys` changes for `ProxyCredentials`.** It never was `Codable`; this stays.

### Scope sketch

- `Sources/ProxyKernel/Security/SecretBytes.swift` — new file (~120 LOC including zero-on-deinit + the `withUnsafeBytes` plumbing)
- `Sources/ProxyKernel/Security/ProxyCredentials.swift` — `ntHash` field retype + `keychainData()` rewrite (~30 LOC changed)
- `Sources/ProxyAuth/NTLMAuth.swift` — NT-hash-consuming paths go through `withUnsafeBytes` (~20 LOC)
- `Sources/PlatformMac/KeychainStore.swift` — `save(secret:account:)` signature (~10 LOC)
- `Sources/PlatformMac/CredentialManager.swift` — `ProxyCredentials.keychainData()` usage (~10 LOC)
- `Sources/Conduit/App/AppState.swift` — `savePassword` boundary (~5 LOC)
- Tests — `SecretBytesTests` (lifecycle, zero-on-deinit, no-description conformance), `ProxyCredentialsTests` updated (~100 LOC)

Total: ~200 LOC net + a boundary audit across the six files above.

### Ordering

Land before log-sink sanitization — that task asserts on `SecretBytes`'s redacted print. Independent of the CFNetwork swap; the two can proceed in parallel.

---

## 3. `CorporateDefaults.swift` → `Resources/Presets/example-corp.json`

**Goal.** Remove the vendor-specific Swift struct from the kernel and ship the same data as a JSON file under `Resources/Presets/`. Ship alongside two other example presets (generic/empty, self-hosted Squid) so the OSS distribution has no hardcoded vendor strings outside `docs/` and the preset file itself.

### Why now

- The split landed `ProxyConfig.testFixture()`, a vendor-neutral factory for tests that don't depend on vendor-specific values. This shrinks the OSS test-migration surface from "every test that calls `corporateDefault()`" to "only tests that specifically want the vendor shape."
- This follow-up is a prerequisite for the OSS exit criterion: "no vendor strings outside `Resources/Presets/example-corp.json` and `docs/`."
- The kernel-side `ProxyConfigPersistence` path that falls back to `corporateDefault()` also needs a cut-over: post-OSS it falls back to `GenericDefaults`, not a vendor preset.

### Shape

```swift
// Sources/ProxyKernel/Models/PresetLoader.swift  (new)

package enum PresetLoader {
    /// Load a preset by name (`"example-corp"`, `"generic"`, `"squid"`) from the
    /// bundled `Resources/Presets/<name>.json`. Returns `nil` if missing;
    /// the app falls back to `GenericDefaults.shared.makeConfig()` in that
    /// case.
    package static func load(_ name: String, bundle: Bundle = .module) -> ProxyConfig? { ... }

    /// Enumerate available presets for the first-run wizard.
    package static func availablePresets(bundle: Bundle = .module) -> [PresetDescriptor] { ... }
}

package struct PresetDescriptor: Codable, Sendable, Identifiable {
    package let id: String              // "example-corp"
    package let displayName: String     // "Example Corp corporate proxy"
    package let description: String     // user-facing blurb for the wizard
}
```

File layout:

```
Resources/
└── Presets/
    ├── index.json           list of {id, displayName, description, version}
    ├── example-corp.json    current default vendor values in JSON form
    ├── generic.json         empty/minimal valid config for home / OSS use
    └── squid.json           self-hosted Squid example (Kerberos off, simple upstream)
```

SwiftPM resource bundling:

```swift
// Package.swift
.target(
    name: "ProxyKernel",
    dependencies: [...],
    path: "Sources/ProxyKernel",
    resources: [.copy("../../Resources/Presets")]
)
```

(or a dedicated `Presets/` subdirectory inside `Sources/ProxyKernel/` if the out-of-target resource path creates friction — resolve that during implementation)

Call-site migration:

- `Sources/Conduit/App/AppState.swift` — first-run picks from `PresetLoader.availablePresets()` in the wizard; default still selects the corporate preset for existing users' migration path.
- `Sources/pm-proxy/PMProxy.swift` — `--minimal` mode continues to use `GenericDefaults.shared.makeConfig()`; unchanged.
- `Sources/ProxyKernel/Support/ProxyConfigPersistence.swift` — the fallback when the persisted config is unreadable becomes `GenericDefaults.shared.makeConfig()` (was `ProxyConfig.corporateDefault()`).
- `ProxyConfig.corporateDefault()` — deleted. Replaced everywhere it was called by `PresetLoader.load("example-corp") ?? GenericDefaults.shared.makeConfig()` or `ProxyConfig.testFixture()`.

Test migration:

- The ~110 `ProxyConfig.corporateDefault()` call sites in `Tests/ConduitTests/` triage three ways:
  1. **Tests that need "any populated valid config"** → `ProxyConfig.testFixture()`. Expected majority.
  2. **Tests that genuinely assert on vendor-specific values** → `PresetLoader.load("example-corp")!` with `@testable import ProxyKernel`. Small minority.
  3. **Tests that build a partial config and only `corporateDefault()` for the scaffolding** → `ProxyConfig.testFixture()` and adjust the field assertions if the fixture's defaults differ.

Do the triage in one sweep, one PR per batch.

### What's unblocked

- OSS release exit criterion: no employer/vendor strings remain in `Sources/` (vendor data lives in the preset JSON + docs only).
- `Resources/Presets/` becomes the extensibility point for future presets (a Homebrew user contributing their employer's config drops a `.json` in and contributes it upstream).
- `docs/configuration.md` can document preset fields by pointing at `Resources/Presets/generic.json` as the canonical example.

### Non-goals

- **No JSON-schema validator.** `Codable` decoding + `ConfigValidation` at load time catches malformed presets. A JSON schema is future work if third-party presets become a thing.
- **No preset versioning / migration.** `index.json` carries a `version` field for forward-compat but the v1 migration is the hard-delete of `corporateDefault()`. Future schema changes handled by `ProxyConfig`'s existing additive-field `decodeIfPresent` pattern.
- **No in-product preset editor.** Presets are read-only; user-edited configs live in `~/Library/Application Support/Conduit/config.json` as today. If a user wants to save their current config as a preset, that's a future UX addition.
- **No preset download from the network.** Presets are bundled at build time; network-fetched presets would re-open the supply-chain concerns the `CFNetwork PAC swap` closes.

### Scope sketch

- `Resources/Presets/*.json` — 3 files, ~50 lines each
- `Sources/ProxyKernel/Models/PresetLoader.swift` — new file (~80 LOC)
- `Sources/ProxyKernel/Models/CorporateDefaults.swift` — deleted
- `Sources/ProxyKernel/Models/ProxyConfig.swift` — `corporateDefault()` deleted; `testFixture()` stays
- `Package.swift` — resource declaration (~5 LOC)
- `Sources/ProxyKernel/Support/ProxyConfigPersistence.swift` — fallback retarget (~2 LOC)
- `Sources/Conduit/App/AppState.swift` — first-run wizard + test-PAC fallback (~10 LOC)
- `Sources/Conduit/Views/SetupWizardView.swift` — preset picker instead of a hardcoded vendor default (~30 LOC)
- Test migration — ~110 call sites (mechanical + `ProxyConfig.testFixture` sweep)

Total: ~150 LOC new code + ~200 LOC test-call-site mechanical swaps + 3 JSON files.

### Ordering

OSS-prep work. Land in OSS-prep mode after the UI polish work — doing it earlier adds the preset picker UI before the rest of the UI polish is in place, creating unnecessary rework. Independent of the security-hardening work; sequencing is about release phase, not technical dependency.

---

## 4. `PlatformIntegration` design

**Goal.** Re-visit the composite `PlatformIntegration` protocol that was deferred during the split once the daemon-first control-plane reload path gives us real callers to drive the shape from.

### Why not now

This is the one follow-up that isn't ready to start. The split's pre-audit established why:

1. **`ProxyOrchestrator` references zero `PlatformMac` concretes.** The orchestrator never grew a cross-target need for platform side-effects.
2. **`AppState` owns every platform side-effect call site** (~30 references in `AppState.swift`). AppState already links `PlatformMac` directly; a composite protocol with AppState as its only consumer would be ceremony, not abstraction.
3. **The original 8-method composite would have violated ISP badly.** Most callers needed 0–2 methods; the composite would have forced every caller to depend on all 12 (the expanded list including `saveCurrentDNS`, `restoreIfNeeded`, `startRelay`, `probeLiveness`, `reconcile`, `hasSavedState`, `isApplied`, `isCleared`).

None of those conditions change until the daemon-first control-plane reload path becomes a real caller. The trigger is the daemon-first work, not a follow-up scheduling decision.

### When to revisit

Start `PlatformIntegration` design when the first of these lands:

- **`pmctl reload` applies `ConfigDiff` subsystem-by-subsystem.** The daemon-side reload handler (inside `pm-proxy` or a new `DaemonHost` type) needs to call `applySystemProxy` / `applySystemDNS` / `applyEnvironmentVariables` as a side-effect of a control-socket command. That's the first kernel-adjacent caller that isn't `AppState`.
- **LaunchAgent watchdog with `lifecycle.crash_restart` event.** On restart, the daemon re-applies the last-known config's system-side state from `snapshot.json`. The re-apply logic wants a protocol seam so pm-sim can assert on it without real `networksetup` calls.

Both tasks push side-effect orchestration below the AppState boundary. The protocol shape emerges from which methods both call sites share — not from a pre-emptive design session.

### Shape guidance (not a design)

Before the design session, lock in these decisions based on lessons from the split:

- **Per-concern protocols, not a god composite.** `SystemProxyApplying`, `SystemDNSApplying`, `EnvironmentApplying`, `LoginItemControlling`, `NotificationDispatching`. Each 2–4 methods. The protocol surface inventory ([`docs/architecture.md § Abstractions directory`](./architecture.md)) is the target shape: no protocol above 3 methods, no protocol below ~1 real caller.
- **Location:** `Sources/ProxyKernel/Abstractions/`, matching every other cross-target protocol. Conformers in `Sources/PlatformMac/` — same file-per-protocol boundary as the existing `CredentialManager: CredentialProvider` / `HelperPrivilegeClient: PrivilegeClient` / `VPNStatusMonitor: VPNStatusObserving` pattern.
- **DaemonHost, not orchestrator.** If the daemon-first control socket lives in a new `DaemonHost` type that wraps `ProxyOrchestrator + platform wiring`, the platform protocols are `DaemonHost`'s init params, not the orchestrator's. Keeps the orchestrator's already-wide init signature closed.
- **Test seam parity:** `RecordingSystemProxyApplier` / `RecordingSystemDNSApplier` / etc., matching the existing `RecordingPrivilegeClient` / `RecordingLogSink` pattern. pm-sim uses them.

### What the deferral actually bought

Listing this explicitly because it's the lesson that carries forward:

- **No 8-method god protocol in the kernel today.** Every Abstractions/ file has ≤3 required methods. Adding `PlatformIntegration` speculatively during the split would have tripled the largest protocol overnight.
- **No speculative conformers.** `PlatformMacIntegration` (the composite that would implement `PlatformIntegration`) isn't shipped; the cost of maintaining it through the subsequent milestones would have been ceremony with no caller.
- **The daemon-first design is unconstrained.** When the control-plane reload path lands, its shape drives the protocol shape — not the other way around.

### Non-goals (for the deferral period)

- **No placeholder `PlatformIntegration` protocol.** Don't add an empty protocol "to reserve the name." The reservation is the `design-module-split.md §PlatformIntegration (deferred)` section + this document.
- **No `AppState` refactor to use a protocol against itself.** AppState owns the concretes today; that's fine. The refactor is "extract protocols from AppState's usage *after* the daemon-side usage surfaces," not "extract protocols now so the daemon work has them ready."
- **No pre-emptive per-concern protocol additions** (`SystemProxyApplying` etc.) before the daemon-first work starts. Same argument. The names are sketched above; the shapes are not.

### Ordering

Daemon-first phase. Re-read this section at daemon-first kick-off; decide then whether the evidence has shifted.

---

## 5. Headless auth-event surfacing

**Goal.** Make `auth.kerberos_succeeded` / `auth.kerberos_fallback_ntlm` / `auth.ntlm_configured` `RuntimeEvent`s reach headless contexts. `pm-proxy` owns a `ProxyOrchestrator` and now emits these events into its snapshot/event log; `pm-tunnel` has no `ProxyOrchestrator` or event carrier today, so it remains a future event-stream follow-up rather than faking events as log lines.

**Status (2026-04-26):** **Partially shipped.** `pm-proxy` now passes `outcomeHandler: { [weak orchestrator] ... reportAuthOutcome(...) }` to `credentialBasedAuthenticatorProvider`, so `pm-proxy --status-interval` snapshots and the orchestrator event log see auth outcomes. `pm-tunnel` still passes no outcome handler because it constructs `ConnectionPool` / `TunnelForwarder` directly and has no `RuntimeEventLog` carrier.

### Why now

The auth-runtime fix introduced `outcomeHandler:` as an optional 3rd parameter on `credentialBasedAuthenticatorProvider`. AppState and `pm-proxy` wire it to `orchestrator.reportAuthOutcome(_:host:reason:)`. `pm-tunnel` still passes `nil` (the default), so:

- The auth events reach `pm-proxy`'s `orchestrator.eventLog` and snapshots.
- Future `pm-sim` scenarios that assert on Kerberos→NTLM fallback should use an orchestrator-backed path, not `pm-tunnel`.
- `pm-tunnel` gets no `.auth`-category events yet; add an event carrier there only when the event-stream shape needs it.

The original asymmetry was unintentional for `pm-proxy`. For `pm-tunnel`, the asymmetry is now deliberate: there is no orchestrator/event-log owner to report into.

### Shape

Two design choices, easy decision:

**Option A: default-route to `eventLog` when `outcomeHandler == nil`.** Add a new init parameter to `credentialBasedAuthenticatorProvider` for an `eventSink: (@Sendable (RuntimeEvent) -> Void)?`, OR pass the orchestrator's event-emit closure from pm-proxy/pm-tunnel. The factory falls back to emitting `RuntimeEvent` directly when no `outcomeHandler` is supplied.

**Option B (recommended): have orchestrator-backed headless binaries build their own outcomeHandler.** `pm-proxy` constructs `ProxyOrchestrator` and has `reportAuthOutcome` available, so it passes the same hook as AppState. `pm-tunnel` does not, so defer it until an event carrier exists.

(B) is simpler and more consistent. The reason both binaries pass `nil` today is probably oversight or scope-control during the auth-runtime change, not a deliberate decision.

### What's unblocked

- `pm-proxy --status-interval` snapshots gain `lastAuthOutcome` / `lastAuthFallbackReason` fields — surfaces silent fallback to operators running headless
- `pm-sim` scenario `auth-fallback-storm` (planned in the reliability-scenario backlog) can land
- Audit-log expansion (`audit.ndjson`, per [`roadmap-v2.md`](./roadmap-v2.md)) gets these events on every host

### Non-goals

- **No new event kinds.** The three existing auth-outcome event names are sufficient.
- **No `RuntimeAuthOutcome` API surface change.** The enum is the right shape.

### Scope sketch

For Option B (recommended):
- `Sources/pm-proxy/PMProxy.swift` — `outcomeHandler: { [weak orchestrator] o, h, r in orchestrator?.reportAuthOutcome(o, host: h, reason: r) }` (~5 LOC)
- `Sources/pm-tunnel/PMTunnel.swift` — deferred; add an event carrier before wiring this.
- Tests — extend `AuthHandshakeIntegrationTests` (or add a new pm-proxy-style test) to assert the snapshot field flips after a fallback handshake (~30 LOC)

Total: ~50 LOC + 1 test.

### Ordering

Independent of CFNetwork (§1) and SecretBytes (§2). Lower priority than both — this is observability completeness, not a security or architectural seam. Land as a quick adjacent PR after either §1 or §2.

---

## Summary of ordering

```
Module split COMPLETE (2026-04-22)
↓
Auth-runtime fix (2026-04-23) — RuntimeAuthOutcome + AuthProviderHolder
│
├── Can start now (security-hardening subsequence, parallel-safe):
│   ├── §1 CFNetwork PAC swap         ~300 LOC    standalone
│   └── §2 SecretBytes opaque type    ~200 LOC    blocks log-sink sanitization
│
├── Partially shipped (observability completeness):
│   └── §5 Headless auth-event surfacing  pm-proxy done; pm-tunnel waits for event carrier
│
├── Can start at OSS-prep kickoff:
│   └── §3 Vendor preset JSON         mechanical + test sweep
│
└── Starts inside the daemon-first work, not standalone:
    └── §4 PlatformIntegration        shape TBD — emerges from daemon call sites
                                      (see §2 sidebar for the inverted-ownership
                                       refactor that the daemon work will likely fold in)
```

All five are single-PR candidates (the vendor-preset test-site migration may warrant two or three batched PRs for review reviewability, but the code change is one PR). None reopens the module split; all five live inside the seams the split established.

## References

- [`docs/architecture.md`](./architecture.md) — target architecture + protocol layout. The shapes these follow-ups extend.
- [`docs/design-module-split.md`](./design-module-split.md) — especially `§New Abstractions → PlatformIntegration (deferred)` (rejection rationale) and `§Open Items (Deferred)` (the originating list).
- [`roadmap-v2.md`](./roadmap-v2.md) — the security-hardening backlog that commissions CFNetwork PAC + SecretBytes, the daemon-first architecture that drives `PlatformIntegration`'s shape, and the OSS preparation that commissions the vendor-preset JSON externalization.
- [`ROADMAP.md`](../ROADMAP.md) — the security / daemon-first / OSS checklists; this doc is the *how*, ROADMAP is the *what + when*.
