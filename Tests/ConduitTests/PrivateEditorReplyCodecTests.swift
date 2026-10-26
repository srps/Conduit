// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import ConduitShared

/// Codec tests for the editor read and the host's private answers (decisions 0014, 0018 and 0034): admission, observation
/// and refusal, their correlation, the reply cap and the maximum observation. They use the real encoder, reader, scanner
/// and decoder. They do not exercise an owner turn, a fence, the store or a client draft.
final class PrivateEditorReplyCodecTests: XCTestCase {
    private struct Failure: Error {}

    // MARK: - Read

    func testReadRequestRoundTripsAsItsOwnKind() throws {
        let read = try sampleRead()
        let frame = try PrivateConfigurationEncoder.encode(read).bytes()
        XCTAssertTrue(String(decoding: frame.prefix(7), as: UTF8.self) == "PCV1 G ")
        XCTAssertEqual(try PrivateConfigurationDecoder.decodeRead(readFrame(frame, kind: .read)), read)
        // A read frame is not an update or a reply.
        XCTAssertThrowsError(try readFrame(frame, kind: .update)) {
            XCTAssertEqual($0 as? PrivateConfigurationWireError, .unexpectedFrameKind)
        }
        let body = try readFrame(frame, kind: .read)
        XCTAssertThrowsError(try PrivateConfigurationDecoder.decode(body)) {
            XCTAssertEqual($0 as? PrivateConfigurationWireError, .unexpectedFrameKind)
        }
        XCTAssertThrowsError(try PrivateConfigurationDecoder.decodeReply(body)) {
            XCTAssertEqual($0 as? PrivateConfigurationWireError, .unexpectedFrameKind)
        }
    }

    // MARK: - Answers

    /// Every admission and every refusal crosses the wire unchanged, and an admission's bytes are exactly what its own
    /// `Codable` writes with sorted keys.
    func testAdmissionsAndRefusalsRoundTripAndAdmissionBytesAreItsOwnEncoding() throws {
        let operation = ControlOperationID(rawValue: PrivateConfigSamples.uuid(70))
        let admissions = [ControlAdmission.accepted(operation), .joined(operation)]
            + ControlRejectionCode.allCases.map { ControlAdmission.rejected($0) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        for admission in admissions {
            let reply = sampleReply(.admission(admission))
            let text = try bodyText(reply)
            let own = String(decoding: try encoder.encode(admission), as: UTF8.self)
            XCTAssertTrue(text.contains("\"admission\":\(own),"), own)
            XCTAssertEqual(try roundTrip(reply), reply)
        }
        for code in ControlRejectionCode.allCases {
            let reply = sampleReply(.refused(code))
            XCTAssertTrue(try bodyText(reply).contains("\"refusal\":\"\(code.rawValue)\""))
            XCTAssertEqual(try roundTrip(reply), reply)
        }
    }

    /// Exactly one answer is present, every answer member is required, and an admission carries exactly the members its
    /// own encoding writes for its variant.
    func testAnswerPresenceAndAdmissionVariantMembersAreStrict() throws {
        let operation = PrivateConfigSamples.uuid(70).uuidString
        let accepted = try bodyText(sampleReply(.admission(.accepted(ControlOperationID(rawValue: PrivateConfigSamples.uuid(70))))))
        let admission = "\"admission\":{\"operation\":\"\(operation)\",\"type\":\"accepted\"}"
        let mutations = [
            "\"admission\":null",
            "\"admission\":{\"operation\":\"\(operation)\",\"rejection\":\"queue_full\",\"type\":\"accepted\"}",
            "\"admission\":{\"operation\":\"\(operation)\",\"rejection\":null,\"type\":\"accepted\"}",
            "\"admission\":{\"type\":\"accepted\"}",
            "\"admission\":{\"operation\":\"\(operation)\",\"type\":\"rejected\"}",
            "\"admission\":{\"rejection\":\"queue_full\",\"type\":\"joined\"}",
            "\"admission\":{\"operation\":\"\(operation)\",\"type\":\"settled\"}",
            "\"admission\":{\"operation\":\"\(operation)\",\"type\":\"accepted\",\"extra\":1}",
        ]
        for mutated in mutations {
            XCTAssertEqual(refusal(replacing(accepted, admission, with: mutated)), .malformedBody, mutated)
        }
        // A second answer beside the admission, or a missing answer member.
        XCTAssertEqual(refusal(replacing(accepted, "\"refusal\":null", with: "\"refusal\":\"queue_full\"")), .malformedBody)
        XCTAssertEqual(refusal(replacing(accepted, ",\"refusal\":null", with: "")), .malformedBody)
        XCTAssertEqual(refusal(replacing(accepted, ",\"observation\":null", with: "")), .malformedBody)
        XCTAssertEqual(refusal(replacing(accepted, "\"observation\":null", with: "\"observation\":null,\"receipt\":null")), .malformedBody)
        let refused = try bodyText(sampleReply(.refused(.queueFull)))
        XCTAssertEqual(refusal(replacing(refused, "\"refusal\":\"queue_full\"", with: "\"refusal\":\"busy\"")), .malformedBody)
    }

    // MARK: - Observation

    /// Every component state, retained reason and module state crosses the wire unchanged, with exact baselines.
    func testEveryComponentStateAndModuleStateRoundTrips() throws {
        let states: [(ControlConfigWorkflowFile) -> PrivateComponentState] = [
            { .verified(PrivateConfigSamples.baseline($0, version: .max)) },
            { .absent(PrivateConfigSamples.baseline($0, version: 0)) },
        ] + PrivateRetainedReason.allCases.map { reason in { _ in .retained(reason) } }
        for state in states {
            for component in ControlConfigWorkflowFile.allCases {
                var components = try sampleObservation().components
                components[component] = state(component)
                let observation = try sampleObservation(components: components)
                XCTAssertEqual(try roundTrip(sampleReply(.observation(observation))), sampleReply(.observation(observation)))
            }
        }
        var observation = try sampleObservation()
        observation.terminal = true
        observation.launchAtLogin = true
        observation.modules.dns = PrivateModuleState(
            lifecycleRevision: try PrivateConfigSamples.lifecycleRevision(Int.max), enabled: true, fenced: true
        )
        XCTAssertEqual(try roundTrip(sampleReply(.observation(observation))), sampleReply(.observation(observation)))
    }

    /// A component's baseline names its own file, and its state pairs with exactly one of baseline or reason. Required
    /// nullable members, unknown states and reasons, and missing slots are refused.
    func testComponentStatesAreStrictAndMatchTheirSlots() throws {
        let base = try sampleObservation()
        var swapped = base.components
        swapped.platform = .verified(PrivateConfigSamples.baseline(.runtime, version: 3))
        XCTAssertThrowsError(try sampleObservation(components: swapped)) {
            XCTAssertEqual($0 as? PrivateConfigurationWireError, .invalidValue)
        }

        let text = try bodyText(sampleReply(.observation(base)))
        let namespace = PrivateConfigSamples.storeNamespace.rawValue.uuidString
        let platformBaseline = "{\"namespace\":\"\(namespace)\",\"component\":\"platform\",\"version\":3}"
        let verified = "\"platform\":{\"state\":\"verified\",\"baseline\":\(platformBaseline),\"reason\":null}"
        let mutations = [
            "\"platform\":{\"state\":\"verified\",\"baseline\":\(platformBaseline.replacingOccurrences(of: "platform", with: "runtime")),\"reason\":null}",
            "\"platform\":{\"state\":\"verified\",\"baseline\":null,\"reason\":null}",
            "\"platform\":{\"state\":\"verified\",\"baseline\":\(platformBaseline),\"reason\":\"writeUnknown\"}",
            "\"platform\":{\"state\":\"retained\",\"baseline\":\(platformBaseline),\"reason\":\"writeUnknown\"}",
            "\"platform\":{\"state\":\"retained\",\"baseline\":null,\"reason\":null}",
            "\"platform\":{\"state\":\"retained\",\"baseline\":null,\"reason\":\"busy\"}",
            "\"platform\":{\"state\":\"stale\",\"baseline\":\(platformBaseline),\"reason\":null}",
            "\"platform\":{\"state\":\"verified\",\"baseline\":\(platformBaseline)}",
            "\"platform\":{\"state\":\"verified\",\"reason\":null}",
            // A retained state's baseline is null, but its member is still required: a missing key is never read as null.
            "\"platform\":{\"state\":\"retained\",\"reason\":\"writeUnknown\"}",
        ]
        for mutated in mutations {
            XCTAssertEqual(refusal(replacing(text, verified, with: mutated)), .malformedBody, mutated)
        }
        XCTAssertEqual(refusal(replacing(text, "\"enabled\":true,\"fenced\":false}", with: "\"enabled\":true}")), .malformedBody)
        XCTAssertEqual(refusal(replacing(text, "\"lifecycleRevision\":4,", with: "\"lifecycleRevision\":-4,")), .malformedBody)
        XCTAssertEqual(refusal(replacing(text, "\"launchAtLogin\":false,", with: "")), .malformedBody)
        // An observation reply still names the admission member, as null: a missing answer member is refused.
        XCTAssertEqual(refusal(replacing(text, "\"admission\":null,", with: "")), .malformedBody)
    }

    /// A storable repair draft that blocks a start is still returned unchanged: the codec checks format, not eligibility.
    func testStartBlockingRepairDraftIsReturnedUnchanged() throws {
        var observation = try sampleObservation()
        observation.runtime.proxy.port = 70_000
        observation.runtime.proxy.maxConnections = 0
        observation.runtime.routing.pacURL = PrivateURLValue("not a url")
        XCTAssertEqual(try roundTrip(sampleReply(.observation(observation))), sampleReply(.observation(observation)))
    }

    // MARK: - Correlation

    /// An update is answered only by an admission for its own request ID from its own incarnation. Only a rejection for a
    /// changed incarnation may come from another one.
    func testUpdateMatcherAcceptsOnlyItsOwnAdmission() throws {
        let update = try PrivateConfigSamples.request()
        let operation = ControlOperationID(rawValue: PrivateConfigSamples.uuid(70))
        let other = ControlHostIncarnation(rawValue: PrivateConfigSamples.uuid(99))
        let accepted = PrivateEditorReply(requestID: update.requestID, hostIncarnation: update.incarnation, answer: .admission(.accepted(operation)))
        XCTAssertEqual(try accepted.admission(answering: update), .accepted(operation))

        let changed = PrivateEditorReply(requestID: update.requestID, hostIncarnation: other, answer: .admission(.rejected(.changedIncarnation)))
        XCTAssertEqual(try changed.admission(answering: update), .rejected(.changedIncarnation))

        let cases: [(PrivateEditorReply, PrivateEditorReplyMismatch)] = [
            (PrivateEditorReply(requestID: ControlRequestID(rawValue: PrivateConfigSamples.uuid(98)), hostIncarnation: update.incarnation, answer: .admission(.accepted(operation))), .otherRequest),
            (PrivateEditorReply(requestID: update.requestID, hostIncarnation: other, answer: .admission(.accepted(operation))), .otherIncarnation),
            (PrivateEditorReply(requestID: update.requestID, hostIncarnation: other, answer: .admission(.rejected(.queueFull))), .otherIncarnation),
            (PrivateEditorReply(requestID: update.requestID, hostIncarnation: update.incarnation, answer: .refused(.queueFull)), .unpairedAnswer),
            (PrivateEditorReply(requestID: update.requestID, hostIncarnation: update.incarnation, answer: .observation(try sampleObservation())), .unpairedAnswer),
        ]
        for (reply, expected) in cases {
            XCTAssertThrowsError(try reply.admission(answering: update)) {
                XCTAssertEqual($0 as? PrivateEditorReplyMismatch, expected)
            }
        }
    }

    /// A read is answered only by an observation or a refusal for its own request ID. An observation never comes from
    /// another incarnation; only a refusal for a changed incarnation may.
    func testReadMatcherAcceptsOnlyItsOwnObservationOrRefusal() throws {
        let read = try sampleRead()
        let other = ControlHostIncarnation(rawValue: PrivateConfigSamples.uuid(99))
        let observation = try sampleObservation()
        let observed = PrivateEditorReply(requestID: read.requestID, hostIncarnation: read.incarnation, answer: .observation(observation))
        XCTAssertEqual(try observed.answer(answering: read), .observation(observation))
        let changed = PrivateEditorReply(requestID: read.requestID, hostIncarnation: other, answer: .refused(.changedIncarnation))
        XCTAssertEqual(try changed.answer(answering: read), .refused(.changedIncarnation))

        let cases: [(PrivateEditorReply, PrivateEditorReplyMismatch)] = [
            (PrivateEditorReply(requestID: ControlRequestID(rawValue: PrivateConfigSamples.uuid(98)), hostIncarnation: read.incarnation, answer: .observation(observation)), .otherRequest),
            (PrivateEditorReply(requestID: read.requestID, hostIncarnation: other, answer: .observation(observation)), .otherIncarnation),
            (PrivateEditorReply(requestID: read.requestID, hostIncarnation: other, answer: .refused(.hostStopping)), .otherIncarnation),
            (PrivateEditorReply(requestID: read.requestID, hostIncarnation: read.incarnation, answer: .admission(.rejected(.queueFull))), .unpairedAnswer),
        ]
        for (reply, expected) in cases {
            XCTAssertThrowsError(try reply.answer(answering: read)) {
                XCTAssertEqual($0 as? PrivateEditorReplyMismatch, expected)
            }
        }
    }

    // MARK: - Reply cap and the maximum observation

    /// The reply cap is the whole frame. A reply body padded to exactly the cap decodes, and one byte more is refused
    /// before it is scanned.
    func testReplyExactCapAcceptedAndCapPlusOneRefused() throws {
        let cap = PrivateConfigurationFrame.maxEditorReplyFrameBytes
        let reply = sampleReply(.refused(.queueFull))
        var body = Array(try bodyText(reply).utf8)
        body.append(contentsOf: repeatElement(UInt8(ascii: " "), count: cap - 16 - body.count))
        XCTAssertEqual(PrivateConfigurationFrame.frameByteCount(bodyCount: body.count), cap)
        XCTAssertEqual(try PrivateConfigurationDecoder.decodeReply(PrivateConfigurationFrameBody(kind: .editorReply, bytes: SecretBytes(body))), reply)
        body.append(UInt8(ascii: " "))
        XCTAssertThrowsError(try PrivateConfigurationDecoder.decodeReply(PrivateConfigurationFrameBody(kind: .editorReply, bytes: SecretBytes(body)))) {
            XCTAssertEqual($0 as? PrivateConfigurationWireError, .frameTooLarge)
        }
    }

    /// The maximum fixture spans every approved count and text ceiling, and its bypass list sits exactly on the aggregate.
    func testMaximumFixtureSpansEveryApprovedBound() throws {
        let observation = try PrivateEditorMaximumFixture.observation(distinct: true)
        let runtime = observation.runtime
        XCTAssertNil(observation.resourceViolation())
        XCTAssertEqual(runtime.upstreams.count, DomainResourceField.upstreams.limit)
        XCTAssertEqual(runtime.tunnels.definitions.count, DomainResourceField.tunnelDefinitions.limit)
        XCTAssertEqual(runtime.dns.entries.count, DomainResourceField.dnsEntries.limit)
        XCTAssertTrue(runtime.dns.entries.allSatisfy { $0.servers.count == DomainResourceField.dnsServers.limit })
        XCTAssertEqual(runtime.dns.interceptRules.count, DomainResourceField.interceptRules.limit)
        XCTAssertEqual(runtime.proxy.allowedClients.count, DomainResourceField.allowedClients.limit)
        XCTAssertEqual(runtime.routing.forceProxyHosts.count, DomainResourceField.forceProxyHosts.limit)
        XCTAssertEqual(runtime.routing.noProxyHosts.count, DomainResourceField.noProxyHosts.limit)
        XCTAssertEqual(runtime.dns.dohProviders.count, DomainResourceField.dohProviders.limit)
        XCTAssertEqual(runtime.profileName.utf8.count, DomainResourceField.profileName.limit)
        XCTAssertEqual(runtime.routing.pacURL.byteCount, DomainResourceField.pacURL.limit)
        XCTAssertEqual(observation.preferences.preferredBrowserTestURL.byteCount, DomainResourceField.browserTestURL.limit)
        XCTAssertEqual(
            runtime.dns.interceptRules.first?.pattern.utf8.count,
            DomainResourceField.interceptPattern.utf8Limit(wildcardPrefix: true)
        )
        // The bypass list is exactly at its canonical aggregate: one more byte crosses it.
        let hosts = runtime.routing.noProxyHosts
        XCTAssertNil(DomainResourceCheck.strings(hosts, count: .noProxyHosts, item: .noProxyPattern, encodedWithin: .noProxyList))
        var over = hosts
        over[over.count - 1] += "a"
        XCTAssertEqual(
            DomainResourceCheck.strings(over, count: .noProxyHosts, item: .noProxyPattern, encodedWithin: .noProxyList),
            DomainResourceViolation(.noProxyList, DomainResourceField.noProxyList.limit)
        )
    }

    /// The maximum observation's exact reply size, from the counting pass, and a full round trip through the reader and
    /// the decoder. Distinct and shared texts have the same width.
    func testMaximumObservationFitsTheReplyCapAndRoundTrips() throws {
        let reply = try PrivateEditorMaximumFixture.reply(distinct: true)
        let body = try PrivateConfigurationEncoder.measureBody(reply)
        XCTAssertEqual(body, try PrivateConfigurationEncoder.measureBody(PrivateEditorMaximumFixture.reply(distinct: false)))
        XCTAssertEqual(body, Self.maximumReplyBodyBytes)
        XCTAssertLessThanOrEqual(PrivateConfigurationFrame.frameByteCount(bodyCount: body), PrivateConfigurationFrame.maxEditorReplyFrameBytes)

        let frame = try PrivateConfigurationEncoder.encode(reply).bytes()
        XCTAssertEqual(frame.count, PrivateConfigurationFrame.frameByteCount(bodyCount: body))
        XCTAssertEqual(try PrivateConfigurationDecoder.decodeReply(readFrame(frame, kind: .editorReply)), reply)
    }

    /// The exact body of `PrivateEditorMaximumFixture.reply`, pinned so a change to the reply shape shows its cost.
    static let maximumReplyBodyBytes = 7_487_859

    // MARK: - Redaction and coding

    func testReplyRedactsValuesAndHasNoGenericCoding() throws {
        var observation = try sampleObservation()
        observation.preferences.preferredBrowserTestURL = PrivateURLValue("https://example.test/?token=PREF-TOKEN-3")
        let reply = sampleReply(.observation(observation))
        let described = String(describing: reply) + String(reflecting: reply) + String(describing: observation)
            + String(describing: observation.preferences) + "\(Mirror(reflecting: reply).children.map { "\($0.value)" })"
        XCTAssertFalse(described.contains("PAC-TOKEN-7"))
        XCTAssertFalse(described.contains("PREF-TOKEN-3"))
        XCTAssertTrue(described.contains("v4"), "baselines are described")
        for value in [reply as Any, observation, observation.preferences, observation.components, try sampleRead()] {
            XCTAssertNil(value as? any Encodable)
            XCTAssertNil(value as? any Decodable)
        }
    }

    // MARK: - Helpers

    private func sampleRead() throws -> PrivateEditorReadRequest {
        PrivateEditorReadRequest(
            requestID: ControlRequestID(rawValue: PrivateConfigSamples.uuid(5)),
            incarnation: ControlHostIncarnation(rawValue: PrivateConfigSamples.uuid(2)),
            budget: try ControlWireBudget(5_000)
        )
    }

    private func sampleObservation(
        components: PrivateComponentSlots<PrivateComponentState>? = nil
    ) throws -> PrivateEditorObservation {
        let request = try PrivateConfigSamples.request()
        let module = PrivateModuleState(lifecycleRevision: try PrivateConfigSamples.lifecycleRevision(4), enabled: true, fenced: false)
        return try PrivateEditorObservation(
            terminal: false,
            runtime: request.runtime,
            platform: request.platform,
            preferences: PrivatePreferences(
                showMenuBarIcon: true, floatingWindowEnabled: false, globalShortcutEnabled: false,
                preferredBrowserTestURL: PrivateURLValue("https://example.com/"), fileLoggingEnabled: true,
                automaticUpdateChecks: false
            ),
            launchAtLogin: false,
            components: components ?? PrivateComponentSlots(
                runtime: .verified(PrivateConfigSamples.baseline(.runtime, version: 4)),
                platform: .verified(PrivateConfigSamples.baseline(.platform, version: 3)),
                preferences: .absent(PrivateConfigSamples.baseline(.preferences, version: 2))
            ),
            modules: PrivateModuleSlots(proxy: module, dns: module, tunnels: module)
        )
    }

    private func sampleReply(_ answer: PrivateEditorAnswer) -> PrivateEditorReply {
        PrivateEditorReply(
            requestID: ControlRequestID(rawValue: PrivateConfigSamples.uuid(5)),
            hostIncarnation: ControlHostIncarnation(rawValue: PrivateConfigSamples.uuid(2)),
            answer: answer
        )
    }

    private func roundTrip(_ reply: PrivateEditorReply) throws -> PrivateEditorReply {
        try PrivateConfigurationDecoder.decodeReply(readFrame(PrivateConfigurationEncoder.encode(reply).bytes(), kind: .editorReply))
    }

    private func bodyText(_ reply: PrivateEditorReply) throws -> String {
        let frame = try PrivateConfigurationEncoder.encode(reply).bytes()
        let start = try XCTUnwrap(frame.firstIndex(of: 0x0A)) + 1
        return String(decoding: frame[start..<(frame.count - 1)], as: UTF8.self)
    }

    private func readFrame(_ bytes: [UInt8], kind: PrivateConfigurationFrame.Kind) throws -> PrivateConfigurationFrameBody {
        let reader = PrivateConfigurationFrameReader(expecting: kind)
        var offset = 0
        while offset < bytes.count {
            let (step, consumed) = try reader.consume(bytes[offset...])
            offset += consumed
            if case .frame(let body) = step {
                guard offset == bytes.count else { throw Failure() }
                return body
            }
        }
        throw Failure()
    }

    /// `text` with `original` replaced. The original must be present, so a mutation cannot silently miss.
    private func replacing(_ text: String, _ original: String, with replacement: String) -> String {
        XCTAssertTrue(text.contains(original), "fixture lacks \(original)")
        return text.replacingOccurrences(of: original, with: replacement)
    }

    private func refusal(_ text: String) -> PrivateConfigurationWireError? {
        do {
            _ = try PrivateConfigurationDecoder.decodeReply(
                PrivateConfigurationFrameBody(kind: .editorReply, bytes: SecretBytes(Array(text.utf8))))
            return nil
        } catch {
            return error as? PrivateConfigurationWireError
        }
    }
}
