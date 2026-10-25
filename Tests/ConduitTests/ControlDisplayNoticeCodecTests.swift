import XCTest
@testable import ProxyKernel
import ProxyControlBridge
import ConduitShared

/// The codec side of decision 0029. Each case runs the real projection output through the frame codec, or mutates the encoded record and
/// expects the decoder to refuse it. The check is named by its fields, so a malformed notice fails for the reason the record names.
final class ControlDisplayNoticeCodecTests: XCTestCase {
    private let roomy = try! ControlFrameLimits(maxFrameBytes: 1 << 20)

    /// The widest projection this suite measures: every snapshot field cut at its cap, with escapes, multibyte, combining and ZWJ text.
    private func widestSnapshot() throws -> ControlRuntimeSnapshot {
        let text = DisplayBoundsFixture.text(atLeast: 2_000)
        return try DisplayBoundsFixture.project(DisplayBoundsFixture.kernel(text: text), profileName: text)
    }

    private func message(_ snapshot: ControlRuntimeSnapshot) -> ControlRuntimeMessage {
        ControlRuntimeMessage(correlation: ControlRequestID(rawValue: DisplayBoundsFixture.uuid(7)), body: .frame(.snapshot(snapshot)))
    }

    private func snapshotObject(_ snapshot: ControlRuntimeSnapshot) throws -> [String: Any] {
        let data = try ControlRuntimeCodec.makeEncoder().encode(snapshot)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func decodeSnapshot(_ object: [String: Any]) throws -> ControlRuntimeSnapshot {
        let data = try JSONSerialization.data(withJSONObject: object)
        return try ControlRuntimeCodec.makeDecoder().decode(ControlRuntimeSnapshot.self, from: data)
    }

    private func notice(_ field: ControlDisplayField, _ treatment: String) -> [String: String] {
        ["field": field.rawValue, "treatment": treatment]
    }

    // MARK: - Frame size and the exact limit

    func testAWidestFrameRoundTripsAndItsLimitIsExactToOneByte() throws {
        let snapshot = try widestSnapshot()
        let payload = try ControlRuntimeCodec.encodeBoundedPayload(message(snapshot), limits: roomy)
        // The codec's rule is payload plus line feed. One byte more than that fits, and one byte less refuses the same value.
        let exact = try ControlFrameLimits(maxFrameBytes: payload.count + 1)
        let short = try ControlFrameLimits(maxFrameBytes: payload.count)
        XCTAssertEqual(try ControlRuntimeCodec.decodeFrame(payload, limits: exact), message(snapshot))
        XCTAssertNoThrow(try ControlRuntimeCodec.encodeBoundedPayload(message(snapshot), limits: exact))
        XCTAssertThrowsError(try ControlRuntimeCodec.encodeBoundedPayload(message(snapshot), limits: short)) { error in
            XCTAssertEqual(error as? ControlRuntimeWireError, .frameTooLarge)
        }
        XCTAssertEqual(snapshot.displayNotices.count, ControlDisplayOwner.snapshot.maxNotices)
        // A mixed sample of escapes and multibyte text. It is not the worst encoding: the all-NUL worst record is measured in the projection suite.
        print("RUNTIME_DISPLAY_MEASURE actual mixed_sample_snapshot_frame_payload_bytes=\(payload.count) notices=\(snapshot.displayNotices.count)")
    }

    // MARK: - Decoded notices and text

    func testAValidWidestRecordDecodesAndUnknownExtensionsStayLegal() throws {
        let base = try snapshotObject(try widestSnapshot())
        XCTAssertNoThrow(try decodeSnapshot(base))
        var extended = base
        extended["futureExtension"] = ["anything": 1]
        XCTAssertNoThrow(try decodeSnapshot(extended), "an unknown extension value is legal and is ignored")
    }

    func testADecodedNoticeArrayIsRefusedWhenItRepeatsOrIsOutOfOrder() throws {
        let base = try snapshotObject(try widestSnapshot())
        let notices = try XCTUnwrap(base["displayNotices"] as? [[String: String]])

        var duplicate = base
        duplicate["displayNotices"] = [notices[0], notices[0]]
        XCTAssertThrowsError(try decodeSnapshot(duplicate), "a repeated field is refused")

        var reversed = base
        reversed["displayNotices"] = Array(notices.reversed())
        XCTAssertThrowsError(try decodeSnapshot(reversed), "notices out of canonical order are refused")
    }

    func testADecodedNoticeArrayIsRefusedWhenItPassesTheOwnersFieldCount() throws {
        let base = try snapshotObject(try widestSnapshot())
        let notices = try XCTUnwrap(base["displayNotices"] as? [[String: String]])
        var over = base
        over["displayNotices"] = notices + [notices[0]]
        XCTAssertThrowsError(try decodeSnapshot(over), "more notices than the snapshot has fields is refused")
    }

    func testAnOverCountArrayIsRefusedByItsCountBeforeItsExtraElementIsRead() throws {
        // The fifteenth element is not a notice at all. A decoder that read it first would fail on its type. The refusal must name the count,
        // which shows the check ran before that element was decoded. The count here is known, so this is the early known-count refusal.
        let base = try snapshotObject(try widestSnapshot())
        let notices: [Any] = try XCTUnwrap(base["displayNotices"] as? [[String: String]])
        var over = base
        over["displayNotices"] = notices + [5]
        do {
            _ = try decodeSnapshot(over)
            XCTFail("an array longer than the snapshot's fields is refused")
        } catch let DecodingError.dataCorrupted(context) {
            XCTAssertTrue(context.debugDescription.contains("more notices"), context.debugDescription)
        } catch {
            XCTFail("the over-count array fails as corrupt data, not as \(error)")
        }
    }

    func testADecodedNoticeNamingAnotherOwnersFieldOrAnUnknownFieldIsRefused() throws {
        let base = try snapshotObject(try widestSnapshot())
        var wrongOwner = base
        wrongOwner["displayNotices"] = [notice(.connectionDestination, "shortened")]
        XCTAssertThrowsError(try decodeSnapshot(wrongOwner), "a snapshot cannot carry a connection row's notice")

        var unknown = base
        unknown["displayNotices"] = [["field": "notAField", "treatment": "shortened"]]
        XCTAssertThrowsError(try decodeSnapshot(unknown), "a field outside the closed set is refused")
    }

    func testAnOmittedNoticeNeedsTheFixedMarkerAndAPresentValue() throws {
        let base = try snapshotObject(try widestSnapshot())
        var notMarker = base
        notMarker["vpnInterfaceName"] = "a value that was never omitted"
        notMarker["displayNotices"] = [notice(.vpnInterfaceName, "omitted")]
        XCTAssertThrowsError(try decodeSnapshot(notMarker), "an omitted notice over a value that is not the marker is refused")

        var marker = base
        marker["vpnInterfaceName"] = ControlDisplayText.omittedValue
        marker["displayNotices"] = [notice(.vpnInterfaceName, "omitted")]
        XCTAssertNoThrow(try decodeSnapshot(marker))

        var absent = base
        absent.removeValue(forKey: "activeUpstream")
        absent["displayNotices"] = [notice(.activeUpstream, "shortened")]
        XCTAssertThrowsError(try decodeSnapshot(absent), "a notice for an absent optional field is refused")
    }

    func testTextOverItsCapIsRefusedAndTheCapItselfIsAccepted() throws {
        var base = try snapshotObject(try widestSnapshot())
        var notices = try XCTUnwrap(base["displayNotices"] as? [[String: String]])
        notices.removeAll { $0["field"] == "healthSummary" }

        var atCap = base
        atCap["healthSummary"] = String(repeating: "a", count: 512)
        atCap["displayNotices"] = notices
        XCTAssertNoThrow(try decodeSnapshot(atCap), "exactly 512 bytes is within the diagnostic cap")

        var overCap = base
        overCap["healthSummary"] = String(repeating: "a", count: 513)
        overCap["displayNotices"] = notices
        XCTAssertThrowsError(try decodeSnapshot(overCap), "513 bytes with no notice is refused, not rewritten")

        base["profileName"] = String(repeating: "p", count: 1_025)
        XCTAssertThrowsError(try decodeSnapshot(base), "a name over the 1,024-byte cap is refused")
    }

    func testARowsNoticeForAnAbsentOptionalIsRefusedWhenDecoded() throws {
        let row = try ControlConnectionRow(
            id: ControlConnectionID(rawValue: DisplayBoundsFixture.uuid(20)),
            destination: "files.example.test:443",
            upstream: "corp-1",
            method: "CONNECT",
            startedAt: ControlTimestamp(1_700_000_000),
            lastActivityAt: ControlTimestamp(1_700_000_001),
            bytesSent: ControlCount(0),
            bytesReceived: ControlCount(0),
            tunnel: false,
            authMethod: nil
        )
        var object = try XCTUnwrap(JSONSerialization.jsonObject(
            with: try ControlRuntimeCodec.makeEncoder().encode(row)
        ) as? [String: Any])
        object["displayNotices"] = [notice(.connectionAuthMethod, "shortened")]
        let data = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try ControlRuntimeCodec.makeDecoder().decode(ControlConnectionRow.self, from: data))
        XCTAssertThrowsError(try ControlRuntimeCodec.makeEncoder().encode(
            ControlConnectionRow(
                id: ControlConnectionID(rawValue: DisplayBoundsFixture.uuid(20)), destination: "a", upstream: "b", method: "c",
                startedAt: ControlTimestamp(1), lastActivityAt: ControlTimestamp(2), bytesSent: ControlCount(0),
                bytesReceived: ControlCount(0), tunnel: false, authMethod: nil,
                displayNotices: [ControlDisplayNotice(field: .connectionAuthMethod, treatment: .shortened)]
            )
        ), "the encoder refuses the same notice before it publishes it")
    }

    // MARK: - The other displayed records

    private func object<Value: Encodable>(_ value: Value) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: ControlRuntimeCodec.makeEncoder().encode(value)) as? [String: Any])
    }

    private func decodeObject<Value: Decodable>(_ type: Value.Type, _ object: [String: Any]) throws -> Value {
        try ControlRuntimeCodec.makeDecoder().decode(type, from: JSONSerialization.data(withJSONObject: object))
    }

    func testTheOtherDisplayedRecordsRefuseEachMutationTheyCanCarry() throws {
        let long = String(repeating: "h", count: 513)

        // A DNS host row: a notice for another owner's field, an omitted notice without the marker, and a value over its cap with no notice.
        let dns = try object(ControlTunnelDNSHostRow(hostname: "a.example", outcome: .active))
        var wrongOwner = dns
        wrongOwner["displayNotices"] = [notice(.probeName, "shortened")]
        XCTAssertThrowsError(try decodeObject(ControlTunnelDNSHostRow.self, wrongOwner))
        var notMarker = dns
        notMarker["displayNotices"] = [notice(.dnsHostname, "omitted")]
        XCTAssertThrowsError(try decodeObject(ControlTunnelDNSHostRow.self, notMarker))
        var overCap = dns
        overCap["hostname"] = long
        XCTAssertThrowsError(try decodeObject(ControlTunnelDNSHostRow.self, overCap))
        var atCap = dns
        atCap["hostname"] = String(repeating: "h", count: 512)
        XCTAssertNoThrow(try decodeObject(ControlTunnelDNSHostRow.self, atCap))

        // An upstream row: a name over the 1,024-byte name cap is refused, and the diagnostic endpoint over 512 is refused too.
        let upstream = try object(ControlUpstreamRow(
            id: ControlUpstreamID(rawValue: DisplayBoundsFixture.uuid(30)), name: "corp-1", endpoint: "e:1",
            circuitState: .closed, ewmaLatencyMilliseconds: nil, consecutiveFailures: ControlCount(0), openUntil: nil
        ))
        var longName = upstream
        longName["name"] = String(repeating: "n", count: 1_025)
        XCTAssertThrowsError(try decodeObject(ControlUpstreamRow.self, longName))
        var longEndpoint = upstream
        longEndpoint["endpoint"] = long
        XCTAssertThrowsError(try decodeObject(ControlUpstreamRow.self, longEndpoint))

        // A tunnel binding row: its label is a name, and its hosts are diagnostic endpoints.
        let tunnel = try object(ControlTunnelBindingRow(
            id: ControlTunnelID(rawValue: DisplayBoundsFixture.uuid(40)), label: "db", localHost: "127.0.0.1",
            localPort: ControlPort(15_432), remoteHost: "db.example.test", remotePort: ControlPort(5_432),
            proxied: true, healthy: true
        ))
        var longLabel = tunnel
        longLabel["label"] = String(repeating: "l", count: 1_025)
        XCTAssertThrowsError(try decodeObject(ControlTunnelBindingRow.self, longLabel))
        var longRemote = tunnel
        longRemote["remoteHost"] = long
        XCTAssertThrowsError(try decodeObject(ControlTunnelBindingRow.self, longRemote))

        // The probe: its endpoint is a diagnostic, so an endpoint over 512 bytes is refused with no notice, and it encodes no further.
        let probe = try object(ControlUpstreamProbe(
            upstreamID: ControlUpstreamID(rawValue: DisplayBoundsFixture.uuid(30)), name: "corp-1", endpoint: "e:1",
            reachable: true, latencyMilliseconds: ControlCount(12)
        ))
        var longProbe = probe
        longProbe["endpoint"] = long
        XCTAssertThrowsError(try decodeObject(ControlUpstreamProbe.self, longProbe))
        XCTAssertThrowsError(try ControlRuntimeCodec.makeEncoder().encode(ControlUpstreamProbe(
            upstreamID: ControlUpstreamID(rawValue: DisplayBoundsFixture.uuid(30)), name: "corp-1", endpoint: long,
            reachable: true, latencyMilliseconds: ControlCount(12)
        )), "a direct probe over its cap is never published")
    }

    // MARK: - Direct construction and mutation

    func testADirectlyMutatedRecordCannotEmitInvalidTextThroughAnyEncoder() throws {
        var snapshot = try widestSnapshot()
        snapshot.profileName = String(repeating: "p", count: 1_025)
        XCTAssertThrowsError(try ControlRuntimeCodec.encodeBoundedPayload(message(snapshot), limits: roomy)) { error in
            XCTAssertEqual(error as? ControlRuntimeWireError, .invalidValue)
        }
        XCTAssertThrowsError(try ControlRuntimeCodec.makeEncoder().encode(snapshot), "a plain encoder is refused too")

        var absent = try widestSnapshot()
        absent.activeUpstream = nil
        XCTAssertThrowsError(try ControlRuntimeCodec.encodeBoundedPayload(message(absent), limits: roomy),
                             "a notice whose optional field was cleared is refused")
    }

    // MARK: - The check itself

    func testTheSharedCheckRefusesEveryMalformedShapeItNames() throws {
        let values: ControlDisplayValues = [
            (.dnsHostname, "h.example.test"),
        ]
        XCTAssertNoThrow(try ControlDisplayCheck.validate(owner: .dnsHostRow, notices: [], values: values))
        XCTAssertThrowsError(try ControlDisplayCheck.validate(
            owner: .dnsHostRow,
            notices: [ControlDisplayNotice(field: .dnsHostname, treatment: .shortened), ControlDisplayNotice(field: .dnsHostname, treatment: .shortened)],
            values: values
        ), "one owner field allows at most one notice")
        XCTAssertThrowsError(try ControlDisplayCheck.validate(owner: .upstreamRow, notices: [], values: values),
                             "the values must name exactly the owner's fields")
        XCTAssertThrowsError(try ControlDisplayCheck.validate(
            owner: .dnsHostRow,
            notices: [ControlDisplayNotice(field: .probeName, treatment: .shortened)],
            values: values
        ), "a notice for another owner is refused")
        XCTAssertThrowsError(try ControlDisplayCheck.validate(
            owner: .dnsHostRow,
            notices: [ControlDisplayNotice(field: .dnsHostname, treatment: .omitted)],
            values: values
        ), "an omitted notice needs the marker")
        XCTAssertNoThrow(try ControlDisplayCheck.validate(
            owner: .dnsHostRow,
            notices: [ControlDisplayNotice(field: .dnsHostname, treatment: .omitted)],
            values: [(.dnsHostname, ControlDisplayText.omittedValue)]
        ))
        XCTAssertThrowsError(try ControlDisplayCheck.validate(
            owner: .dnsHostRow,
            notices: [],
            values: [(.dnsHostname, String(repeating: "h", count: 513))]
        ), "a value over its cap is refused")
    }
}
