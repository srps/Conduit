// SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import ProxyKernel

/// `dnsInterceptReady` gates whether `/etc/resolver/<domain>` intercept files
/// may exist. Those files hand every process on the machine an address, so a
/// false negative silently blackholes the domain and a false positive points
/// it at a listener that isn't there.
///
/// The subtle half is *where* the predicate is read. `ProxyOrchestrator`
/// updates `snapshot` synchronously inside `mutateSnapshot`, but hosts mirror
/// it into their UI through `onSnapshotChange` + `Task { @MainActor }`. Right
/// after `startDNS()` returns, that mirror still holds the snapshot taken
/// before the transparent proxy bound. Reading it there withheld the resolver
/// files from a fully healthy stack — observed as `getaddrinfo ENOTFOUND` on
/// every intercepted domain while both listeners were up.
final class DNSInterceptReadinessTests: XCTestCase {

    // MARK: - The predicate

    func testReadyOnlyWhenBothListenersAreBound() {
        XCTAssertTrue(
            ProxyOrchestratorBindings(dnsPort: 5053, transparentProxyPort: 10443).dnsInterceptReady
        )
    }

    /// Resolver files pointed at `127.0.0.1:5053` with nothing bound there:
    /// ENOTFOUND for every intercepted domain.
    func testNotReadyWhenForwarderIsDown() {
        XCTAssertFalse(
            ProxyOrchestratorBindings(dnsPort: nil, transparentProxyPort: 10443).dnsInterceptReady
        )
    }

    /// The forwarder would answer with the intercept IP, but nothing accepts
    /// there — a refused connection mid-TLS rather than ENOTFOUND.
    func testNotReadyWhenTransparentProxyFailedToBind() {
        XCTAssertFalse(
            ProxyOrchestratorBindings(dnsPort: 5053, transparentProxyPort: nil).dnsInterceptReady
        )
    }

    func testNotReadyByDefault() {
        XCTAssertFalse(ProxyOrchestratorBindings().dnsInterceptReady)
    }

    /// The snapshot file is written by the daemon and read by the GUI; an
    /// older snapshot must decode to "not ready" rather than fail.
    func testLegacySnapshotWithoutTransparentProxyKeysDecodesAsNotReady() throws {
        let legacy = #"{"dnsHost":"127.0.0.1","dnsPort":5053,"tunnels":[]}"#
        let decoded = try JSONDecoder().decode(ProxyOrchestratorBindings.self, from: Data(legacy.utf8))
        XCTAssertEqual(decoded.dnsPort, 5053)
        XCTAssertNil(decoded.transparentProxyPort)
        XCTAssertFalse(decoded.dnsInterceptReady)
    }

    // MARK: - The producer

    /// By the time `startDNS()` returns, the orchestrator's own snapshot must
    /// already describe both listeners. Hosts write resolver files off this,
    /// synchronously, with no further `await` to let a mirror catch up.
    @MainActor
    func testStartDNSPublishesBothBindingsBeforeItReturns() async throws {
        var config = ProxyConfig.testFixture()
        config.upstreams = []
        config.localPort = 0
        config.dnsForwarderEnabled = true
        config.dnsForwarderPort = 0
        config.transparentProxyEnabled = true
        config.transparentProxyIP = "127.0.0.1"
        config.transparentProxyPort = 0
        config.dnsInterceptRules = [DNSInterceptRule(pattern: "*.intercepted.example")]

        let orchestrator = ProxyOrchestrator(config: config, logger: DiscardingLogSink())
        await orchestrator.startDNS()
        defer { Task { await orchestrator.stopDNS() } }

        let bindings = orchestrator.snapshot.bindings
        XCTAssertEqual(orchestrator.snapshot.dnsRunState, .running)
        XCTAssertNotNil(bindings.dnsPort, "forwarder port must be published")
        XCTAssertNotNil(bindings.transparentProxyPort, "transparent proxy port must be published")
        XCTAssertTrue(bindings.dnsInterceptReady)
    }

    /// A snapshot delivered asynchronously can be observed mid-`startDNS`,
    /// after the forwarder bound but before the transparent proxy did. Such a
    /// snapshot must read as *not* ready — this is the exact intermediate the
    /// GUI mirror was caught holding, and treating it as ready would install
    /// resolver files pointing at an unbound intercept IP.
    func testIntermediateSnapshotWithOnlyForwarderBoundIsNotReady() {
        let midStart = ProxyOrchestratorBindings(dnsHost: "127.0.0.1", dnsPort: 5053)
        XCTAssertNil(midStart.transparentProxyPort)
        XCTAssertFalse(
            midStart.dnsInterceptReady,
            "the mid-start snapshot must never authorize writing intercept files"
        )
    }

    /// `stopDNS` tears the transparent proxy down, so readiness must drop with
    /// it — otherwise a later refresh would rewrite files for dead listeners.
    @MainActor
    func testStopDNSClearsBothBindings() async throws {
        var config = ProxyConfig.testFixture()
        config.upstreams = []
        config.localPort = 0
        config.dnsForwarderEnabled = true
        config.dnsForwarderPort = 0
        config.transparentProxyEnabled = true
        config.transparentProxyIP = "127.0.0.1"
        config.transparentProxyPort = 0
        config.dnsInterceptRules = [DNSInterceptRule(pattern: "*.intercepted.example")]

        let orchestrator = ProxyOrchestrator(config: config, logger: DiscardingLogSink())
        await orchestrator.startDNS()
        XCTAssertTrue(orchestrator.snapshot.bindings.dnsInterceptReady)

        await orchestrator.stopDNS()

        XCTAssertNil(orchestrator.snapshot.bindings.dnsPort)
        XCTAssertNil(orchestrator.snapshot.bindings.transparentProxyPort)
        XCTAssertFalse(orchestrator.snapshot.bindings.dnsInterceptReady)
    }
}
