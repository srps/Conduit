import ConduitShared
import Foundation

/// `runtime-service-wire` (decision 0014): the v2 representations the service engine answers with, checked
/// headlessly. It covers the approved refinements: the changed-incarnation and request-conflict rejections, the
/// subscriber-limit failure, the observation-loss replay reason, and the revision-free unavailable page. Each one
/// must round-trip through the one codec, and a frame over its limit is refused, not truncated. The scenario
/// drives the shared representations only: `pm-sim` cannot depend on the `ConduitRuntime` service, so the service
/// itself is driven by the `ConduitTests` runtime-service suites through `@testable`.
enum RuntimeServiceWireScenario {
    static func run() async throws -> ScenarioResult {
        let began = Date()
        var assertions: [ScenarioAssertion] = []
        var notes: [String] = []
        func check(_ name: String, _ passed: Bool) { assertions.append(.init(name, passed)) }

        let limits = try ControlFrameLimits(maxFrameBytes: 64 * 1024)
        let correlation = ControlRequestID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-0000000000C1") ?? UUID())

        let changed = try roundTrip(
            .response(.admission(.rejected(.changedIncarnation))), correlation: correlation, limits: limits
        )
        check("a changed-incarnation rejection round-trips", changed)

        let conflict = try roundTrip(
            .response(.admission(.rejected(.requestConflict))), correlation: correlation, limits: limits
        )
        check("a request-conflict rejection round-trips", conflict)

        let subscriberLimit = try roundTrip(
            .response(.failure(.subscriberLimit)), correlation: correlation, limits: limits
        )
        check("a subscriber-limit failure round-trips", subscriberLimit)

        let loss = try roundTrip(
            .response(.requestLookup(.unknown(.notRecorded))), correlation: correlation, limits: limits
        )
        check("a not-recorded lookup still round-trips beside the new reasons", loss)

        let replayLoss = ControlReplayAvailability.unavailable(.observationLoss)
        let replayData = try ControlRuntimeCodec.makeEncoder().encode(replayLoss)
        let replayBack = try ControlRuntimeCodec.makeDecoder().decode(ControlReplayAvailability.self, from: replayData)
        check("an observation-loss replay reason round-trips", replayBack == replayLoss)
        check("the observation-loss reason is named on the wire", String(decoding: replayData, as: UTF8.self).contains("observation_loss"))

        let page = try roundTrip(
            .response(.page(.unavailable(.activeConnections, .notCaptured, knownTotal: nil))), correlation: correlation, limits: limits
        )
        check("a revision-free unavailable page round-trips", page)
        let totaled = try roundTrip(
            .response(.page(.unavailable(.tunnelDNSHosts, .retentionBudgetExceeded, knownTotal: ControlCount(17)))),
            correlation: correlation,
            limits: limits
        )
        check("an unavailable page with its known total round-trips", totaled)
        let pageData = try ControlRuntimeCodec.makeEncoder().encode(
            ControlPageReply.unavailable(.tunnelBindings, .expiredRevision, knownTotal: ControlCount(4))
        )
        check("an unavailable page names no revision on the wire", !String(decoding: pageData, as: UTF8.self).contains("\"revision\""))
        check("an unavailable page names its known total on the wire", String(decoding: pageData, as: UTF8.self).contains("\"knownTotal\":4"))
        let legacy = Data(#"{"collection":"tunnelBindings","reason":"expired_revision","type":"unavailable"}"#.utf8)
        let legacyReply = try ControlRuntimeCodec.makeDecoder().decode(ControlPageReply.self, from: legacy)
        check("an unavailable page from before the total decodes with no total", legacyReply == .unavailable(.tunnelBindings, .expiredRevision, knownTotal: nil))
        let nullTotal = Data(#"{"collection":"tunnelBindings","knownTotal":null,"reason":"expired_revision","type":"unavailable"}"#.utf8)
        check("a null known total is refused, not read as no total", (try? ControlRuntimeCodec.makeDecoder().decode(ControlPageReply.self, from: nullTotal)) == nil)

        let tiny = try ControlFrameLimits(maxFrameBytes: 16)
        var refused = false
        do {
            _ = try ControlRuntimeCodec.encodeFrame(
                ControlRuntimeMessage(correlation: correlation, body: .response(.page(.unavailable(.upstreamHealth, .notCaptured, knownTotal: nil)))),
                limits: tiny
            )
        } catch ControlRuntimeWireError.frameTooLarge {
            refused = true
        }
        check("a frame over its limit is refused, not truncated", refused)

        // The observation representations: a resync is a stream end, a baseline that does not fit is a typed first frame, and a
        // failed snapshot read is a closed internal failure. None of them is a transport error or a silent gap.
        let resync = try roundTrip(
            .frame(.end(ControlStreamEnd(reason: .resyncRequired))), correlation: correlation, limits: limits
        )
        check("a resync end frame round-trips", resync)
        let baselineRefusal = try roundTrip(
            .response(.failure(.frameTooLarge)), correlation: correlation, limits: limits
        )
        check("a baseline refused as too large round-trips as its first frame", baselineRefusal)
        let internalFailure = try roundTrip(
            .response(.failure(.internalFailure)), correlation: correlation, limits: limits
        )
        check("a closed internal read failure round-trips", internalFailure)
        let refusalData = try ControlRuntimeCodec.makeEncoder().encode(
            ControlRuntimeMessage(correlation: correlation, body: .response(.failure(.frameTooLarge)))
        )
        check("a frame-too-large refusal names its stable code on the wire", String(decoding: refusalData, as: UTF8.self).contains("frame_too_large"))

        notes.append("representations only: the service is driven by the ConduitTests runtime-service suites")
        notes.append("no socket, machine, network or helper effects")
        return ScenarioResult(
            name: "runtime-service-wire", clientCount: 0, clientsOpened: 0, clientsWithFirstByte: 0,
            clientsClosedEarly: 0, totalBytes: 0, durationSeconds: Date().timeIntervalSince(began),
            aggregateMBps: 0, minBytes: 0, maxBytes: 0, medianBytes: 0,
            earliestClose: nil, latestClose: nil,
            assertions: assertions.isEmpty ? [.init("scenario produced assertions", false)] : assertions,
            notes: notes
        )
    }

    private static func roundTrip(
        _ body: ControlRuntimeBody,
        correlation: ControlRequestID,
        limits: ControlFrameLimits
    ) throws -> Bool {
        let frame = try ControlRuntimeCodec.encodeFrame(ControlRuntimeMessage(correlation: correlation, body: body), limits: limits)
        let decoded = try ControlRuntimeCodec.decodeFullFrame(frame, limits: limits)
        return decoded.body == body
    }
}
