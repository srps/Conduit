// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import XCTest
@testable import ProxyKernel

@MainActor
final class VPNReconnectRoutingTests: XCTestCase {
    func testReconnectRevokesDirectRoutingBeforeAwaitingProbe() async throws {
        try await checkReconnect(hasUpstreams: true, reachable: true)
    }

    func testFailedReconnectProbeKeepsStrictUpstreamRouting() async throws {
        try await checkReconnect(hasUpstreams: true, reachable: false)
    }

    func testNoUpstreamsStillAllowsDirectRouting() async throws {
        try await checkReconnect(hasUpstreams: false, reachable: false)
    }

    private func checkReconnect(hasUpstreams: Bool, reachable: Bool) async throws {
        let entered = expectation(description: "reconnect probe entered")
        let loop = MultiThreadedEventLoopGroup.singleton.next()
        let release = loop.makePromise(of: Void.self)
        let mode = NIOLockedValueBox(0)
        var config = ProxyConfig()
        config.localPort = 0
        config.localPACEnabled = true
        config.localPACPort = 0
        config.proxy.strictMode = true
        config.routing.pacRoutingEnabled = false
        config.upstreams = hasUpstreams ? [UpstreamProxy(name: "isolated", host: "127.0.0.1", port: 9, priority: 0)] : []
        let orchestrator = ProxyOrchestrator(config: config, connectivityProbe: { upstreams in
            let phase = mode.withLockedValue { value in
                let phase = value
                if value == 2 { value = 3 }
                return phase
            }
            if phase == 2 {
                entered.fulfill()
                do { try await release.futureResult.get() }
                catch { XCTFail("probe gate failed: \(error)") }
            }
            return UpstreamProbeSummary(results: upstreams.map {
                ProbeResult(proxy: $0, latencyMS: 0, reachable: phase >= 2 ? reachable : phase != 1)
            })
        })
        try await orchestrator.startProxy()
        mode.withLockedValue { $0 = 1 }
        await orchestrator.handleVPNStateChange(.disconnected(reason: .userInitiated))
        XCTAssertEqual(orchestrator.snapshot.directModeCause, .vpnDisconnected)
        mode.withLockedValue { $0 = 2 }
        let reconnect = Task { await orchestrator.handleVPNStateChange(.connected) }
        await fulfillment(of: [entered], timeout: 3)
        let pendingCause = orchestrator.snapshot.directModeCause
        let reconnectEvent = orchestrator.eventLog.events.last { $0.event == "vpn.reconnecting" }
        var script = ""
        if let localPAC = orchestrator.snapshot.bindings.localPACURL, let url = URL(string: localPAC) {
            do {
                let (data, _) = try await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 3))
                script = String(decoding: data, as: UTF8.self)
            } catch { XCTFail("local PAC fetch failed: \(error)") }
        } else { XCTFail("local PAC did not bind") }
        release.succeed(())
        await reconnect.value
        let finalCause = orchestrator.snapshot.directModeCause
        await orchestrator.stopProxy()
        XCTAssertEqual(pendingCause, hasUpstreams ? .none : .noUpstreamsConfigured)
        XCTAssertEqual(finalCause, hasUpstreams ? (reachable ? .none : .upstreamsUnreachable) : .noUpstreamsConfigured)
        XCTAssertEqual(script.contains("function FindProxyForURL(url, host) {\n  return \"DIRECT\";\n}"), !hasUpstreams,
                       "served PAC must revoke VPN-off DIRECT before probes complete")
        XCTAssertNotNil(reconnectEvent)
    }
}
