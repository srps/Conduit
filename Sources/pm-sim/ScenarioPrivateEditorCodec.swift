// SPDX-License-Identifier: Apache-2.0
import Foundation
import ConduitShared

/// The private editor read and reply, headless: a read frame, a correlated observation reply, an update's admission,
/// a read refusal, the reply cap and the frame kinds, through the real encoder, reader, scanner and decoder. It uses a
/// small synthetic configuration; maximum sizing belongs to the unit tests and the Release probe. It does not exercise
/// an owner turn, a fence, the store, a socket or a client draft.
enum PrivateEditorCodecScenario {
    private struct Failure: Error { let message: String }

    static func run() throws -> ScenarioResult {
        let started = Date()
        let token = "SIM-EDITOR-TOKEN-8"
        let update = try PrivateConfigBoundaryScenario.sampleRequest(pacURL: "https://pac.example.test/p.pac?token=\(token)")
        let preconditions = try PrivateConfigBoundaryScenario.samplePreconditions()
        let read = PrivateEditorReadRequest(
            requestID: ControlRequestID(rawValue: PrivateConfigBoundaryScenario.uuid(5)),
            incarnation: update.incarnation,
            budget: try ControlWireBudget(5_000)
        )

        // A read crosses as its own kind and decodes unchanged at every schedule.
        let readFrame = try bytes(PrivateConfigurationEncoder.encode(read))
        var readSchedules = true
        for chunk in [1, 7, 4_096] {
            readSchedules = try readSchedules && PrivateConfigurationDecoder.decodeRead(body(readFrame, kind: .read, chunk: chunk)) == read
        }

        // The observation carries the runtime baseline at UInt64.max and the stored launch-at-login, and crosses the
        // reply frame unchanged at every schedule.
        guard let revision = ControlLifecycleRevision(rawValue: 9) else {
            throw Failure(message: "the sample lifecycle revision is not representable")
        }
        let module = PrivateModuleState(lifecycleRevision: revision, enabled: true, fenced: false)
        let observation = try PrivateEditorObservation(
            terminal: false,
            runtime: update.runtime,
            platform: update.platform,
            preferences: PrivatePreferences(
                showMenuBarIcon: true, floatingWindowEnabled: false, globalShortcutEnabled: false,
                preferredBrowserTestURL: PrivateURLValue("https://example.com/?token=\(token)"),
                fileLoggingEnabled: true, automaticUpdateChecks: false
            ),
            launchAtLogin: true,
            components: PrivateComponentSlots(
                runtime: .verified(preconditions.runtime),
                platform: .verified(preconditions.platform),
                preferences: .retained(.writeUnknown)
            ),
            modules: PrivateModuleSlots(proxy: module, dns: module, tunnels: module)
        )
        let observed = PrivateEditorReply(requestID: read.requestID, hostIncarnation: read.incarnation, answer: .observation(observation))
        let observedFrame = try bytes(PrivateConfigurationEncoder.encode(observed))
        var replySchedules = true
        for chunk in [1, 7, 613, 4_096, 16_384] {
            replySchedules = try replySchedules
                && PrivateConfigurationDecoder.decodeReply(body(observedFrame, kind: .editorReply, chunk: chunk)) == observed
        }
        let observedText = String(decoding: observedFrame, as: UTF8.self)
        let exactBaseline = observedText.contains("\"version\":18446744073709551615")

        // The read matcher keeps its own observation and drops one for another request or from another incarnation.
        let matched = try observed.answer(answering: read) == .observation(observation)
        let otherRequest = PrivateEditorReply(requestID: update.requestID, hostIncarnation: read.incarnation, answer: .observation(observation))
        let otherIncarnation = PrivateEditorReply(
            requestID: read.requestID, hostIncarnation: ControlHostIncarnation(rawValue: PrivateConfigBoundaryScenario.uuid(99)),
            answer: .observation(observation)
        )
        let dropsUncorrelated = mismatch(of: { try otherRequest.answer(answering: read) }) == .otherRequest
            && mismatch(of: { try otherIncarnation.answer(answering: read) }) == .otherIncarnation

        // An update is answered by its admission only, through the reply frame, and an observation never answers it.
        let operation = ControlOperationID(rawValue: PrivateConfigBoundaryScenario.uuid(70))
        let admitted = PrivateEditorReply(requestID: update.requestID, hostIncarnation: update.incarnation, answer: .admission(.accepted(operation)))
        let admittedBack = try PrivateConfigurationDecoder.decodeReply(
            body(bytes(PrivateConfigurationEncoder.encode(admitted)), kind: .editorReply, chunk: 4_096)
        )
        let admission = try admittedBack.admission(answering: update) == .accepted(operation)
        let observationDoesNotAdmit = mismatch(of: {
            try PrivateEditorReply(requestID: update.requestID, hostIncarnation: update.incarnation, answer: .observation(observation))
                .admission(answering: update)
        }) == .unpairedAnswer

        // A refused read crosses as a closed code.
        let refused = PrivateEditorReply(requestID: read.requestID, hostIncarnation: read.incarnation, answer: .refused(.queueFull))
        let refusedBack = try PrivateConfigurationDecoder.decodeReply(
            body(bytes(PrivateConfigurationEncoder.encode(refused)), kind: .editorReply, chunk: 4_096)
        )
        let refusal = try refusedBack.answer(answering: read) == .refused(.queueFull)

        // Kinds: a reply is not an update, and an update reader refuses it at the kind byte with nothing buffered.
        let updateReader = PrivateConfigurationFrameReader(expecting: .update)
        let replyKindRefused = wireRefusal(of: { try updateReader.consume(observedFrame) }) == .unexpectedFrameKind
            && updateReader.retainedByteCount == 0
        // The reply cap: a declared length one byte past it is refused in the header with nothing buffered.
        let replyReader = PrivateConfigurationFrameReader(expecting: .editorReply)
        let overCap = PrivateConfigurationFrame.maxEditorReplyFrameBytes - 15
        let capRefused = wireRefusal(of: { try replyReader.consume(Array("PCV1 R \(overCap)\n".utf8)) }) == .frameTooLarge
            && replyReader.retainedByteCount == 0

        // The tokens never reach a description.
        let described = String(describing: observed) + String(reflecting: observed) + String(describing: observation.preferences)
        let redacted = !described.contains(token)

        let checks: [ScenarioAssertion] = [
            .init("a read frame decodes unchanged at every read schedule", readSchedules),
            .init("an observation reply decodes unchanged at every read schedule", replySchedules),
            .init("the observation carries a UInt64.max baseline exactly", exactBaseline),
            .init("the read matcher keeps its own observation", matched),
            .init("the read matcher drops a reply for another request or incarnation", dropsUncorrelated),
            .init("an update is answered by its own admission through the reply frame", admission),
            .init("an observation never answers an update", observationDoesNotAdmit),
            .init("a refused read crosses as a closed code", refusal),
            .init("an update reader refuses a reply at its kind byte with nothing buffered", replyKindRefused),
            .init("a reply length one byte past the reply cap is refused in the header", capRefused),
            .init("URL tokens are absent from every description", redacted),
        ]
        guard checks.allSatisfy(\.passed) else {
            throw Failure(message: "private editor codec assertions failed: \(checks.filter { !$0.passed }.map(\.name))")
        }
        return ScenarioResult(
            name: "private-editor-codec", clientCount: 0, clientsOpened: 0, clientsWithFirstByte: 0,
            clientsClosedEarly: 0, totalBytes: observedFrame.count, durationSeconds: Date().timeIntervalSince(started),
            aggregateMBps: 0, minBytes: 0, maxBytes: 0, medianBytes: 0, earliestClose: nil, latestClose: nil,
            assertions: checks,
            notes: ["PASS: private editor read and correlated replies (admission, observation, refusal) cross their own frame kinds at every read schedule with exact baselines, uncorrelated and unpaired replies are dropped, and the reply cap refuses in the header (codec only, not an owner turn, store or client draft)"]
        )
    }

    private static func bytes(_ frame: SecretBytes) -> [UInt8] {
        frame.withUnsafeBytes { Array($0) }
    }

    /// Feeds `frame` to a fresh reader of `kind` in pieces of `chunk` and returns its body.
    private static func body(_ frame: [UInt8], kind: PrivateConfigurationFrame.Kind, chunk: Int) throws -> PrivateConfigurationFrameBody {
        let reader = PrivateConfigurationFrameReader(expecting: kind)
        var offset = 0
        while offset < frame.count {
            let (step, consumed) = try reader.consume(frame[offset..<min(offset + chunk, frame.count)])
            offset += consumed
            if case .frame(let body) = step {
                guard offset == frame.count else { throw Failure(message: "bytes followed the frame") }
                return body
            }
        }
        throw Failure(message: "the input ended inside the frame")
    }

    private static func wireRefusal(of step: () throws -> some Any) -> PrivateConfigurationWireError? {
        do {
            _ = try step()
            return nil
        } catch {
            return error as? PrivateConfigurationWireError
        }
    }

    private static func mismatch(of step: () throws -> some Any) -> PrivateEditorReplyMismatch? {
        do {
            _ = try step()
            return nil
        } catch {
            return error as? PrivateEditorReplyMismatch
        }
    }
}
