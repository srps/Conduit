import ConduitShared
import Foundation
import ProxyControlBridge
import ProxyKernel

/// `runtime-display-bounds` (decision 0029): the display policy through the real projection and the frame codec, headless. A kernel snapshot
/// with a name over its cap, a credential across the diagnostic cut, a URL with userinfo and query, and an input past the input limit is
/// projected, framed and decoded. The frame limit is exact to one byte, and a direct mutation and a malformed notice array are refused.
/// The host is simulated: no socket, machine, helper or network effect.
enum RuntimeDisplayBoundsScenario {
    static func run() async throws -> ScenarioResult {
        let began = Date()
        var assertions: [ScenarioAssertion] = []
        var notes: [String] = []
        func check(_ name: String, _ passed: Bool) { assertions.append(.init(name, passed)) }

        let basic = "dXNlcjpzZWNyZXRwYXNz"
        var kernel = ProxyOrchestratorSnapshot()
        kernel.runtimeStatus.lastHealthSummary = String(repeating: "a", count: 500) + " Basic " + basic + " tail"
        kernel.vpnInterfaceName = String(repeating: "v", count: 16_385)
        kernel.proxyError = "bind failed at https://svc:Secretpw@proxy.example.test/x?token=QUERYSECRET"
        let snapshot = try RuntimeSnapshotControlProjection.snapshot(
            kernel,
            stamp: displayStamp(),
            profileName: String(repeating: "P", count: 1_100),
            collectionRevisions: ControlCollectionRevisions()
        )

        check("a name over its 1,024-byte cap is cut to the cap and noticed",
              snapshot.profileName.utf8.count == 1_024
                && snapshot.displayNotices.contains(ControlDisplayNotice(field: .profileName, treatment: .shortened)))
        check("an input past the input limit is omitted whole, with its marker",
              snapshot.vpnInterfaceName == ControlDisplayText.omittedValue
                && snapshot.displayNotices.contains(ControlDisplayNotice(field: .vpnInterfaceName, treatment: .omitted)))
        check("a Basic credential across the diagnostic cut is absent from the projection",
              !snapshot.healthSummary.contains(basic.prefix(8)) && snapshot.healthSummary.utf8.count <= 512)
        check("URL userinfo and the query are absent from the projection",
              !(snapshot.proxyError ?? "").contains("Secretpw") && !(snapshot.proxyError ?? "").contains("QUERYSECRET"))

        let roomy = try ControlFrameLimits(maxFrameBytes: 1 << 20)
        let message = ControlRuntimeMessage(
            correlation: ControlRequestID(rawValue: displayUUID(7)),
            body: .frame(.snapshot(snapshot))
        )
        let payload = try ControlRuntimeCodec.encodeBoundedPayload(message, limits: roomy)
        check("the projected frame decodes to the same message", try ControlRuntimeCodec.decodeFrame(payload, limits: roomy) == message)
        let exact = try ControlFrameLimits(maxFrameBytes: payload.count + 1)
        let short = try ControlFrameLimits(maxFrameBytes: payload.count)
        check("the frame publishes at exactly its payload plus one line feed",
              try wireError { _ = try ControlRuntimeCodec.encodeBoundedPayload(message, limits: exact) } == nil)
        check("one byte less than that is refused as frameTooLarge",
              try wireError { _ = try ControlRuntimeCodec.encodeBoundedPayload(message, limits: short) } == .frameTooLarge)

        var direct = snapshot
        direct.profileName = String(repeating: "p", count: 1_025)
        let directMessage = ControlRuntimeMessage(
            correlation: ControlRequestID(rawValue: displayUUID(8)), body: .frame(.snapshot(direct))
        )
        check("a directly mutated name over its cap is refused as invalidValue, not published",
              try wireError { _ = try ControlRuntimeCodec.encodeBoundedPayload(directMessage, limits: roomy) } == .invalidValue)

        let encoded = try ControlRuntimeCodec.makeEncoder().encode(snapshot)
        var object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] ?? [:]
        let notices = (object["displayNotices"] as? [[String: String]]) ?? []
        object["displayNotices"] = notices + Array(notices.prefix(1))
        let malformed = try JSONSerialization.data(withJSONObject: object)
        check("a notice array that repeats a field is refused on decode as corrupt data",
              decodeRefusesAsCorrupt(malformed))

        notes.append("the host is simulated; the projection and codec are the production code")
        notes.append("payload bytes printed as RUNTIME_DISPLAY_MEASURE, separate from any computed bound")
        print("RUNTIME_DISPLAY_MEASURE scenario_snapshot_payload_bytes=\(payload.count) notices=\(snapshot.displayNotices.count)")
        return ScenarioResult(
            name: "runtime-display-bounds", clientCount: 0, clientsOpened: 0, clientsWithFirstByte: 0,
            clientsClosedEarly: 0, totalBytes: 0, durationSeconds: Date().timeIntervalSince(began),
            aggregateMBps: 0, minBytes: 0, maxBytes: 0, medianBytes: 0,
            earliestClose: nil, latestClose: nil,
            assertions: assertions.isEmpty ? [.init("scenario produced assertions", false)] : assertions,
            notes: notes
        )
    }

    /// The wire refusal a closure raises, or nil when it completes. Any other error is not a wire refusal, so it is rethrown: the
    /// scenario never reads an unexpected failure as a successful encode.
    private static func wireError(_ body: () throws -> Void) throws -> ControlRuntimeWireError? {
        do {
            try body()
            return nil
        } catch let refusal as ControlRuntimeWireError {
            return refusal
        }
    }

    /// Whether a snapshot payload is refused as corrupt data. Any other outcome, including an unexpected error, reads as not refused.
    private static func decodeRefusesAsCorrupt(_ data: Data) -> Bool {
        do {
            _ = try ControlRuntimeCodec.makeDecoder().decode(ControlRuntimeSnapshot.self, from: data)
            return false
        } catch is DecodingError {
            return true
        } catch {
            return false
        }
    }

    private static func displayStamp() -> ControlRuntimeStamp {
        ControlRuntimeStamp(
            incarnation: ControlHostIncarnation(rawValue: displayUUID(1)),
            presentationRevision: ControlPresentationRevision(rawValue: 9)!,
            configRevision: ControlConfigRevision(rawValue: 2)!,
            lifecycleRevision: ControlLifecycleRevision(rawValue: 5)!
        )
    }

    private static func displayUUID(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012X", value))!
    }
}
