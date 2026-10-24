// SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import ProxyKernel
import ProxyControlBridge
import ConduitShared

/// Sizes for the v2 contract, in two kinds that are never mixed:
/// - RAW_PERSISTED_CONFIG: the kernel's own encoding of a configuration. It is not a v2
///   value. No v2 type accepts a `ProxyConfig`, and no config-commit envelope exists yet.
/// - V2_WIRE: the bytes the v2 codec publishes for projected values.
/// Every configuration called valid is asserted valid first, so a size is never reported
/// for a configuration the validator would reject. These numbers are inputs to owner
/// review. They set no cap and choose no default frame limit.
final class RuntimeConfigSizingTests: XCTestCase {
    /// Measurement only: large enough that the value publishes, so the figure is its size.
    private let measureLimits = try! ControlFrameLimits(maxFrameBytes: 1 << 20)
    private let frameLimits16KiB = try! ControlFrameLimits(maxFrameBytes: ControlSocket.maxFrameBytes)
    private let correlation = ControlRequestID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!)

    private func uuid(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012X", value))!
    }

    // MARK: - RAW_PERSISTED_CONFIG

    private func rawBytes(_ config: ProxyConfig) throws -> Int {
        try CanonicalJSON.encoder().encode(config).count
    }

    /// Reports the raw encoding of a configuration that the validator has already accepted.
    private func reportRaw(_ name: String, _ config: ProxyConfig) throws {
        let errors = config.validate()
        XCTAssertEqual(errors.count, 0, "\(name) must validate before its size means anything: \(errors)")
        let bytes = try rawBytes(config)
        print("RUNTIME_CONFIG_SIZING RAW_PERSISTED_CONFIG \(name) raw_json_bytes=\(bytes) validation_errors=\(errors.count)")
    }

    /// Ten upstreams, twenty DNS domains with two servers each, twenty intercept
    /// rules and twenty tunnels: a large configuration a real user could plausibly keep.
    private func largeValidConfiguration(scale: Int = 1) -> ProxyConfig {
        var config = ProxyConfig()
        config.profileName = "Corporate VPN"
        config.upstreams = (0..<(10 * scale)).map { index in
            UpstreamProxy(name: "corp-\(index)", host: "proxy\(index).corp.example.test", port: 8080, priority: index)
        }
        config.dnsEntries = (0..<(20 * scale)).map { index in
            DomainDNSEntry(domain: "corp\(index).example.test", servers: ["10.0.\(index).1", "10.0.\(index).2"])
        }
        config.dnsInterceptRules = (0..<(20 * scale)).map { index in
            DNSInterceptRule(pattern: "*.app\(index).example.test", interceptIP: "127.44.3.\(index + 1)")
        }
        config.tunnelDefinitions = (0..<(20 * scale)).map { index in
            TunnelDefinition(localPort: 20_000 + index, remoteHost: "db\(index).corp.example.test", remotePort: 5432, label: "db-\(index)")
        }
        config.maxConnections = 5_000
        return config
    }

    func testDefaultConfigurationIsMeasured() throws {
        try reportRaw("default", ProxyConfig())
    }

    func testLargeValidConfigurationIsValidAndMeasured() throws {
        try reportRaw("large_valid", largeValidConfiguration())
    }

    func testHighCountConfigurationIsValidAndMeasured() throws {
        try reportRaw("high_count", largeValidConfiguration(scale: 2))
    }

    func testLongStringConfigurationIsValidAndMeasured() throws {
        var config = largeValidConfiguration()
        config.profileName = String(repeating: "P", count: 1_000)
        config.healthCheckURL = "https://health.example.test/" + String(repeating: "h", count: 900)
        config.noProxyHosts = (0..<200).map { "bypass\($0).example.test" }
        try reportRaw("long_strings", config)
    }

    func testEscapingHeavyConfigurationIsValidAndMeasured() throws {
        // Quotes, backslashes and non-ASCII names all escape or widen in JSON.
        var config = largeValidConfiguration()
        config.profileName = #"Corp "VPN" \ path/é"#
        config.upstreams = (0..<10).map { index in
            UpstreamProxy(name: #"corp "\#(index)" é"#, host: "proxy\(index).corp.example.test", port: 8080, priority: index)
        }
        try reportRaw("escaping", config)
    }

    func testArtificialTokensAreInTheRawEncodingSoTheExclusionTestsHaveSomethingToExclude() throws {
        var config = ProxyConfig()
        config.pacURL = "https://pac.example.test/proxy.pac?token=ARTIFICIAL-TOKEN-PAC-5b2d"
        config.healthCheckURL = "https://monitor:ARTIFICIAL-TOKEN-HEALTH-8e1c@health.example.test/"
        config.dohProviders = ["https://doh.example.test/dns-query?key=ARTIFICIAL-TOKEN-DOH-2a7c"]

        let raw = String(decoding: try CanonicalJSON.encoder().encode(config), as: UTF8.self)
        XCTAssertTrue(raw.contains("ARTIFICIAL-TOKEN-PAC-5b2d"))
        XCTAssertTrue(raw.contains("ARTIFICIAL-TOKEN-HEALTH-8e1c"))
        XCTAssertTrue(raw.contains("ARTIFICIAL-TOKEN-DOH-2a7c"))
        // The raw configuration is private data. It is not a v2 value, and no v2 type
        // accepts a ProxyConfig, so none of these tokens can reach the wire.
    }

    // MARK: - V2_WIRE

    private func stamp() -> ControlRuntimeStamp {
        ControlRuntimeStamp(
            incarnation: ControlHostIncarnation(rawValue: uuid(1)),
            presentationRevision: ControlPresentationRevision(rawValue: 9)!,
            configRevision: ControlConfigRevision(rawValue: 2)!,
            lifecycleRevision: ControlLifecycleRevision(rawValue: 5)!
        )
    }

    /// The baseline a live subscription would open with, for an empty kernel snapshot.
    private func baselineMessage(profileName: String) throws -> ControlRuntimeMessage {
        let snapshot = try RuntimeSnapshotControlProjection.snapshot(
            ProxyOrchestratorSnapshot(),
            stamp: stamp(),
            profileName: profileName,
            collectionRevisions: ControlCollectionRevisions()
        )
        let baseline = try ControlBaseline(
            incarnation: stamp().incarnation,
            snapshot: snapshot,
            highWater: try XCTUnwrap(ControlEventCursor(rawValue: 0)),
            replay: .live
        )
        return ControlRuntimeMessage(correlation: correlation, body: .frame(.baseline(baseline)))
    }

    func testV2BaselineBytesAreMeasuredAgainstTheCallersLimit() throws {
        let empty = try baselineMessage(profileName: "")
        let emptyBytes = try ControlRuntimeCodec.encodeFrame(empty, limits: measureLimits).count
        let wide = try baselineMessage(profileName: String(repeating: "P", count: 1_000))
        let wideBytes = try ControlRuntimeCodec.encodeFrame(wide, limits: measureLimits).count

        print("RUNTIME_MEASURE V2_WIRE baseline_empty_frame_bytes=\(emptyBytes)")
        print("RUNTIME_MEASURE V2_WIRE baseline_1000_byte_profile_frame_bytes=\(wideBytes)")
        XCTAssertGreaterThan(emptyBytes, 0)
        XCTAssertGreaterThan(wideBytes, emptyBytes, "the measured text must move the frame size")
        // Whether this fits 16 KiB is recorded, not assumed. The 16 KiB here is the v1
        // bound, used as the caller's chosen limit.
        XCTAssertNoThrow(try ControlRuntimeCodec.encodeFrame(empty, limits: frameLimits16KiB))
    }

    func testV2UpstreamPagesAreMeasuredAndEachFitsTheCallersLimit() throws {
        let rows = try (0..<40).map { index in
            ControlUpstreamRow(
                id: ControlUpstreamID(rawValue: uuid(index + 1)),
                name: "corp-\(index)" + String(repeating: "n", count: 52),
                endpoint: "proxy\(index).corp.example.test:8080",
                circuitState: .closed,
                ewmaLatencyMilliseconds: try ControlNonNegativeNumber(12.5),
                consecutiveFailures: try ControlCount(0),
                openUntil: nil
            )
        }
        var offset = 0
        var pages: [Int] = []
        var largest = 0
        while true {
            let message = try ControlPagePacker.page(
                of: rows,
                offset: offset,
                incarnation: stamp().incarnation,
                revision: ControlCollectionRevision(rawValue: 3)!,
                correlation: correlation,
                limits: frameLimits16KiB,
                wrap: ControlPageReply.upstreamHealth
            )
            let frame = try ControlRuntimeCodec.encodeFrame(message, limits: frameLimits16KiB)
            largest = max(largest, frame.count)
            XCTAssertLessThanOrEqual(frame.count, ControlSocket.maxFrameBytes)
            guard case .response(.page(.upstreamHealth(let page))) = message.body else {
                return XCTFail("the page is a different collection")
            }
            pages.append(page.rows.count)
            guard let next = page.nextCursor else { break }
            offset = next.offset.rawValue
        }
        XCTAssertEqual(pages.reduce(0, +), rows.count, "every row is paged exactly once")
        print("RUNTIME_MEASURE V2_WIRE upstream_pages_16KiB rows_per_page=\(pages) largest_frame_bytes=\(largest)")
    }
}
