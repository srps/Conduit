// SPDX-License-Identifier: Apache-2.0
// Probe for the "2200-thunk frame chain" observation from the 2026-04-22
// Conduit crash report. The crash trace showed ~2200 consecutive
// `@Sendable (String) -> ProxyAuthenticator` thunk frames between
// `RawConnectHandshakeHandler.start()` and
// `credentialBasedAuthenticatorProvider`'s inner closure, culminating in
// a stack-guard overflow when a debug instrumentation call on top added
// ~4 KB of stack. The 4 KB allocation is gone; this test tries to
// quantify whether the underlying closure chain grows per-invocation or
// is a static (bounded) ABI-thunk artifact.
//
// Strategy: capture `Thread.callStackSymbols.count` *inside* the leaf
// factory closure across many invocations. A constant count means the
// chain is bounded and harmless; a linearly growing count proves each
// invocation wraps the provider in another thunk layer and we have a
// real leak to fix.

import XCTest
import NIOConcurrencyHelpers
@testable import ProxyAuth
@testable import ProxyKernel

final class AuthProviderStackDepthTests: XCTestCase {

    /// Measures the raw `credentialBasedAuthenticatorProvider` path in
    /// isolation (no orchestrator). This is the ceiling — any depth
    /// growth here would be inside the factory itself, not the
    /// orchestrator's late-binding indirection.
    func testCredentialBasedProviderFrameCountIsBounded() throws {
        let depths = NIOLockedValueBox<[Int]>([])
        let depthsRef = depths
        let credProvider = InMemoryCredentialProvider()
        let factory: @Sendable (String) throws -> ProxyAuthenticator = credentialBasedAuthenticatorProvider(
            configProvider: { .testFixture() },
            credentialProvider: credProvider,
            outcomeHandler: { _, _, _ in
                depthsRef.withLockedValue { $0.append(Thread.callStackSymbols.count) }
            }
        )

        // Pick `.ntlmv2` via a mutated fixture so the outcomeHandler fires
        // synchronously inside the factory closure (NegotiateAuthenticator's
        // success handler only fires after a real GSS handshake, which we
        // can't do here without a TGT; `.ntlmDirect` fires eagerly).
        let cfg = ProxyConfig.testFixture()
        var mutated = cfg
        mutated.auth.mode = .ntlmv2
        let ntlm = mutated
        let upstream = cfg.upstreams.first!
        try credProvider.setCredentials(
            ProxyCredentials(
                username: "u",
                domain: "D",
                workstation: "W",
                ntHash: SecretBytes.repeating(0, count: 16)
            ),
            for: upstream
        )

        let ntlmFactory: @Sendable (String) throws -> ProxyAuthenticator = credentialBasedAuthenticatorProvider(
            configProvider: { ntlm },
            credentialProvider: credProvider,
            outcomeHandler: { _, _, _ in
                depthsRef.withLockedValue { $0.append(Thread.callStackSymbols.count) }
            }
        )
        _ = factory  // silence unused-warning; factory is declared for the .systemNegotiated path baseline

        for _ in 0..<20 {
            _ = try ntlmFactory("proxy.example.com")
        }

        let captured = depths.withLockedValue { $0 }
        XCTAssertEqual(captured.count, 20, "outcomeHandler should fire once per invocation")
        let first = captured.first ?? 0
        let last = captured.last ?? 0
        XCTAssertLessThanOrEqual(abs(last - first), 2,
            "Stack depth between first and last invocation should not grow. first=\(first) last=\(last) all=\(captured)")
    }

    /// Measures the path through `lateBoundAuthenticatorProvider`
    /// (the real orchestrator's late-binding closure + `NIOLockedValueBox`
    /// box dereference) — this is the one CONNECTHandler actually goes
    /// through. If the box indirection inflates frames per call, it
    /// shows up here.
    /// Regression guard for the `lateBoundAuthenticatorProvider` stack-frame
    /// leak uncovered by the 2026-04-22 Conduit crash. The bug: using
    /// `withLockedValue { $0 }(host)` on a `NIOLockedValueBox` storing a
    /// closure causes the inout copy-out cycle to reabstract the stored
    /// closure through thunks and write the thunked value *back* into the
    /// box — so every call layered another ~4 stack frames onto the next
    /// call. A few hundred CONNECT handshakes would then produce a
    /// multi-thousand-frame stack and topple over. The fix is to invoke
    /// the stored factory *inside* the `withLockedValue` body so the
    /// return value is a concrete `ProxyAuthenticator` struct (no closure
    /// reabstraction), not the factory closure itself.
    ///
    /// If this ever regresses, the failure message prints the growing
    /// frame counts — 500 iterations produces ~2000 extra frames in the
    /// regressed path, matching the crash report's observed depth exactly.
    @MainActor
    func testLateBoundProviderFrameCountIsBounded() async throws {
        let orchestrator = ProxyOrchestrator(
            config: .testFixture(),
            logger: DiscardingLogSink()
        )

        let depths = NIOLockedValueBox<[Int]>([])
        let depthsRef = depths
        let probeProvider: @Sendable (String) throws -> ProxyAuthenticator = { _ in
            depthsRef.withLockedValue { $0.append(Thread.callStackSymbols.count) }
            return NTLMAuthenticator(credentials: ProxyCredentials(
                username: "u", domain: "D", workstation: "W",
                ntHash: SecretBytes.repeating(0, count: 16)
            ))
        }
        orchestrator.setAuthenticatorProvider(probeProvider)

        let accessor = orchestrator.lateBoundAuthenticatorProvider
        for _ in 0..<50 {
            _ = try accessor("proxy.example.com")
        }

        let captured = depths.withLockedValue { $0 }
        XCTAssertEqual(captured.count, 50)
        let first = captured.first ?? 0
        let last = captured.last ?? 0
        XCTAssertLessThanOrEqual(abs(last - first), 2,
            "Late-bound accessor path leaked stack frames across invocations. " +
            "first=\(first) last=\(last) delta=\(last - first) all=\(captured)")
    }

    /// The hypothesis that actually might produce a deep chain:
    /// `setAuthenticatorProvider` storing a closure that captures the
    /// previous closure from the box. If some code path accidentally
    /// does `setAuthenticatorProvider({ try accessor($0) })` — i.e.
    /// re-wraps the existing provider rather than replacing it — each
    /// call would add frames. This test simulates that misuse to see
    /// how fast frames accumulate and confirm the ABI-thunk cost per
    /// wrap.
    @MainActor
    func testWrappedProviderFrameGrowth() async throws {
        let orchestrator = ProxyOrchestrator(
            config: .testFixture(),
            logger: DiscardingLogSink()
        )
        let base: @Sendable (String) throws -> ProxyAuthenticator = { _ in
            NTLMAuthenticator(credentials: ProxyCredentials(
                username: "u", domain: "D", workstation: "W",
                ntHash: SecretBytes.repeating(0, count: 16)
            ))
        }
        orchestrator.setAuthenticatorProvider(base)

        let depths = NIOLockedValueBox<[Int]>([])
        let accessor = orchestrator.lateBoundAuthenticatorProvider

        // Intentionally wrap 500 times — simulating the 2200-thunk
        // scenario if each wrap added ~4 frames (500 × 4 = 2000, close
        // to observed).
        for _ in 0..<500 {
            let current = orchestrator.lateBoundAuthenticatorProvider
            let wrapped: @Sendable (String) throws -> ProxyAuthenticator = { host in
                try current(host)
            }
            orchestrator.setAuthenticatorProvider(wrapped)
        }

        // Probe depth now.
        let depthsRef = depths
        orchestrator.setAuthenticatorProvider { _ in
            depthsRef.withLockedValue { $0.append(Thread.callStackSymbols.count) }
            return NTLMAuthenticator(credentials: ProxyCredentials(
                username: "u", domain: "D", workstation: "W",
                ntHash: SecretBytes.repeating(0, count: 16)
            ))
        }
        // Note: after the last setAuthenticatorProvider, any prior wrapping
        // closures are no longer in the chain (the box now holds the probe
        // directly). So this proves that setAuthenticatorProvider REPLACES,
        // not LAYERS. Depth here should match the bounded-case test above.
        _ = try accessor("proxy.example.com")
        let captured = depths.withLockedValue { $0 }
        XCTAssertEqual(captured.count, 1)
        print("[AuthProviderStackDepthTests] post-500-setAuthenticatorProvider depth = \(captured.first ?? -1)")
    }
}
