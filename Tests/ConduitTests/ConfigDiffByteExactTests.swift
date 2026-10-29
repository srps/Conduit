// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import ProxyKernel

/// #246: a field whose bytes reach the machine or the wire is changed when its UTF-8 changes. See `Respelled`.
@MainActor
final class ConfigDiffByteExactTests: XCTestCase {

    private struct Field {
        let path: String
        let set: (inout ProxyConfig, String) -> Void
        let changed: (ConfigDiff) -> Bool
    }

    /// The fields whose spelling the runtime sends: the PAC fetch URL, the health check's request line, the DoH request path, and the
    /// NTLM identity (UTF-16LE in the messages; domain and username also form the Keychain account).
    private let byteSensitive: [Field] = [
        Field(path: "routing.pacURL", set: { $0.routing.pacURL = "https://pac.example.test/\($1).pac" }, changed: \.routingChanged),
        Field(path: "health.checkURL", set: { $0.health.checkURL = "http://health.example.test/\($1)" }, changed: \.healthChanged),
        Field(path: "dns.dohProviders", set: { $0.dns.dohProviders = ["https://doh.example.test/\($1)"] }, changed: \.dnsChanged),
        Field(path: "auth.username", set: { $0.auth.username = $1 }, changed: \.authChanged),
        Field(path: "auth.domain", set: { $0.auth.domain = $1 }, changed: \.authChanged),
        Field(path: "auth.workstation", set: { $0.auth.workstation = $1 }, changed: \.authChanged),
    ]

    nonisolated private static func pacURL(_ word: String) -> String { "https://pac.example.test/\(word).pac" }

    func testARespellingAloneChangesTheSectionThatSendsIt() {
        Respelled.assertRespelling(Respelled.composed, Respelled.decomposed)
        for field in byteSensitive {
            var old = ProxyConfig.testFixture()
            field.set(&old, Respelled.composed)
            var new = old
            field.set(&new, Respelled.decomposed)

            let diff = ConfigDiff(old: old, new: new)
            XCTAssertTrue(field.changed(diff), "\(field.path): a respelling is a change to the section that sends it")
            XCTAssertTrue(diff.hasChanges, field.path)
        }
    }

    /// With an unrelated edit in the same save the new bytes do reach the orchestrator, but the section that sends them must still be
    /// marked, or nothing refetches the PAC, restarts the health loop or the DNS forwarder.
    func testARespellingBesideAnUnrelatedEditStillChangesItsSection() {
        var old = ProxyConfig.testFixture()
        old.routing.pacURL = Self.pacURL(Respelled.composed)
        var new = old
        new.routing.pacURL = Self.pacURL(Respelled.decomposed)
        new.logging.verbose.toggle()

        let diff = ConfigDiff(old: old, new: new)
        XCTAssertTrue(diff.loggingChanged)
        XCTAssertTrue(diff.routingChanged, "the respelled PAC URL is a routing change")
    }

    /// The profile name keys the Keychain account but is no auth section field: a respelling is runtime input, and neither it nor an
    /// ASCII rename resets the pooled authentication.
    func testAProfileNameRespellingIsInputButNoAuthChange() {
        var old = ProxyConfig.testFixture()
        old.profileName = "Office \(Respelled.composed)"
        var respelled = old
        respelled.profileName = "Office \(Respelled.decomposed)"
        let diff = ConfigDiff(old: old, new: respelled)
        XCTAssertTrue(diff.inputChanged)
        XCTAssertFalse(diff.hasChanges)
        XCTAssertFalse(diff.authChanged)

        var renamed = old
        renamed.profileName = "Home"
        XCTAssertTrue(ConfigDiff(old: old, new: renamed).inputChanged)
        XCTAssertFalse(ConfigDiff(old: old, new: renamed).authChanged, "a rename keeps today's pool behaviour")
        XCTAssertFalse(ConfigDiff(old: old, new: old).inputChanged)
    }

    // MARK: The orchestrator's apply

    @RuntimeActor private func makeOrchestrator(pac: LastFetchPACEvaluator, configure: (inout ProxyConfig) -> Void = { _ in }) -> ProxyOrchestrator {
        var config = GenericDefaults.shared.makeConfig()
        config.localPort = 0
        config.upstreams = []
        config.pacRoutingEnabled = true
        config.pacURL = Self.pacURL(Respelled.composed)
        configure(&config)
        return ProxyOrchestrator(config: config, logger: DiscardingLogSink(), pacEvaluator: pac)
    }

    @RuntimeActor private func didEmit(_ name: String, _ orchestrator: ProxyOrchestrator) -> Bool {
        orchestrator.eventLog.events.contains { $0.event == name }
    }

    /// A save that only respells the PAC URL: the orchestrator holds the new bytes and fetches them.
    @RuntimeActor func testTheOrchestratorTakesARespelledPACURLAndFetchesIt() async {
        let pac = LastFetchPACEvaluator()
        let orchestrator = makeOrchestrator(pac: pac)
        await orchestrator.refreshPACRouting(force: true)
        XCTAssertEqual(pac.fetchCount, 1)

        var respelled = orchestrator.config
        respelled.pacURL = Self.pacURL(Respelled.decomposed)
        await orchestrator.applyConfigChange(respelled)

        assertSameUTF8(orchestrator.config.pacURL, Self.pacURL(Respelled.decomposed), "the orchestrator holds the persisted bytes")
        XCTAssertTrue(didEmit("config.routing_changed", orchestrator))
        XCTAssertEqual(pac.fetchCount, 2, "the respelled URL is fetched")
        XCTAssertEqual(pac.lastFetchedUTF8, Array(Self.pacURL(Respelled.decomposed).utf8))
    }

    /// The same respelling with an unrelated edit: the bytes arrive, and the PAC is fetched from them now, not when the refresh
    /// interval next runs out.
    @RuntimeActor func testARespelledPACURLBesideAnUnrelatedEditIsFetchedAtOnce() async {
        let pac = LastFetchPACEvaluator()
        let orchestrator = makeOrchestrator(pac: pac)
        await orchestrator.refreshPACRouting(force: true)
        XCTAssertEqual(pac.fetchCount, 1)

        var mixed = orchestrator.config
        mixed.pacURL = Self.pacURL(Respelled.decomposed)
        mixed.logging.verbose.toggle()
        await orchestrator.applyConfigChange(mixed)

        assertSameUTF8(orchestrator.config.pacURL, Self.pacURL(Respelled.decomposed))
        XCTAssertTrue(didEmit("config.routing_changed", orchestrator))
        XCTAssertEqual(pac.fetchCount, 2, "the respelled URL is fetched at once")
        XCTAssertEqual(pac.lastFetchedUTF8, Array(Self.pacURL(Respelled.decomposed).utf8))
    }

    /// The profile name is part of the Keychain account the credential manager reads through the orchestrator's config. It has no
    /// section of its own, so the respelling must not be dropped as "nothing changed".
    @RuntimeActor func testTheOrchestratorTakesARespelledProfileName() async {
        let pac = LastFetchPACEvaluator()
        let orchestrator = makeOrchestrator(pac: pac) { $0.profileName = "Office \(Respelled.composed)" }

        var respelled = orchestrator.config
        respelled.profileName = "Office \(Respelled.decomposed)"
        await orchestrator.applyConfigChange(respelled)

        assertSameUTF8(orchestrator.config.profileName, "Office \(Respelled.decomposed)")
    }
}
