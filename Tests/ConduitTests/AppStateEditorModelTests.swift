// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
import ConduitShared
@testable import Conduit
@testable import ConduitRuntime
@testable import PlatformMac
import ProxyControlBridge
@testable import ProxyKernel

/// An independent bounded model of the editor's causal authority (decisions 0015, 0018, 0027 and 0035). The oracle keeps the files as
/// the host does, by version, content and DNS bit, and answers every request as the host answers it: a write under the file's own
/// baseline lands, any other is `notAttempted(.baselineMismatch)`. It never consults the ledger's rules. Every history over edits,
/// submissions, every kind of settlement (an unknown one both landed and not), another client's write, and this client's own saved
/// commands (a DNS Stop's disable save, a saved Start's commit), sent, executed and delivered in any order through the production
/// `ownCommandSent` / `ownCommandEnded` path, is run against `RuntimeEditorLedger`; after each step:
///
/// 1. a clean draft is exactly what the client's own last verified write put on disk, never a newer edit;
/// 2. a held baseline is a version this client's own causal chain produced, never another client's;
/// 3. the values `saved` claims are exactly what the file holds at the held baseline;
/// 4. once any write of this client's has an effect it cannot know, landed or not, or a save met an edit made outside the host, the file
///    has no authority;
/// 5. once nothing of this client's is out, no mismatch is held and no chained write is stranded, whoever else wrote; with no other
///    writer and nothing unknown it also holds the file's current version: authority is never given up unnecessarily;
/// 6. a refused draft is taken as explained (`takeExplainedMismatch`) only while it is still the current draft and after the file moved
///    past the baseline it was refused under, at most once; and it is, once every own write that could explain it has been delivered.
@MainActor
final class AppStateEditorModelTests: XCTestCase {
    private enum Step: CaseIterable {
        case edit
        case submit
        /// The host's answer to the submission in flight: it lands under the file's own baseline, else `baselineMismatch`.
        case settleHost
        case settleNotPersisted
        case settleStoreBusy
        /// The file was edited outside the host since its baseline (decision 0027): the store answers `conflict` and writes nothing.
        case settleConflict
        case settleUnknownLanded
        case settleUnknownNotLanded
        case settleInternalLanded
        case settleInternalNotLanded
        case settleLostLanded
        case settleLostNotLanded
        case notAdmitted
        case foreignWrite
        case sendStop
        case sendStart
        /// The host runs the oldest own command not yet run: its write lands on the file's current version.
        case execute
        case deliverOldest
        case deliverNewest
        case deliverOldestLost
        case deliverOldestInternal
        /// The editor asks whether the draft a `baselineMismatch` refused may go again (`takeExplainedMismatch`), only after a refusal.
        case takeExplained
    }

    private struct Command {
        let requestID: ControlRequestID
        let isStart: Bool
        /// The runtime and platform versions its write was conditional on, and the runtime version it produced, once it ran.
        var ran: (runtime: UInt64, platform: UInt64, produced: UInt64)?
    }

    /// The host's view of the files, and what this client caused.
    private struct Oracle {
        var runtimeVersion: UInt64 = 1
        let platformVersion: UInt64 = 1
        /// What each runtime version holds: the draft content and the DNS bit.
        var contents: [UInt64: (content: Int, dns: Bool)] = [1: (0, false)]
        /// Versions this client's own writes produced.
        var ownVersions: Set<UInt64> = [1]
        var foreignWritten = false
        /// A write of this client's ended with an effect it cannot know, or a save met an outside edit: either way the contract takes the
        /// file's authority away until an explicit reload.
        var unknownOwnEffect = false
        var draftContent = 0
        var nextContent = 1
        /// The content of the client's last verified own submission.
        var cleanContent = 0
        /// The submission in flight: its content and the runtime version it was submitted under.
        var inFlight: (content: Int, under: UInt64?)?
        /// Own saved commands sent and not yet delivered, in send order.
        var commands: [Command] = []
        /// The draft content the host last refused with `baselineMismatch`, and the runtime version it was submitted under; cleared once
        /// the editor takes it as explained.
        var refused: (content: Int, under: UInt64)?
    }

    private let namespace = PrivateBaselineNamespace(rawValue: UUID())
    private let incarnation = ControlHostIncarnation(rawValue: UUID())
    private static let depth = 5
    private static let walks = 4_000
    private static let walkLength = 24

    private func baseline(_ file: ControlConfigWorkflowFile, _ version: UInt64) -> PrivateBaseline {
        PrivateBaseline(namespace: namespace, component: file, version: version)
    }

    /// A component write; the pairing is consistent by construction, so a refusal is a fixture bug.
    private func write(_ outcome: ControlConfigWorkflowWrite, _ file: ControlConfigWorkflowFile, _ version: UInt64?) -> ControlComponentWrite {
        guard let built = try? ControlComponentWrite(write: outcome, baseline: outcome.isVerified ? version.map { baseline(file, $0) } : nil)
        else { preconditionFailure("an inconsistent fixture write") }
        return built
    }

    /// The draft content as a config value the ledger freezes. Only `profileName` varies.
    private func draft(_ content: Int) -> ProxyConfig {
        var config = GenericDefaults.shared.makeConfig()
        config.profileName = "content-\(content)"
        return config
    }

    private func ledger(preferences: AppPreferences = AppPreferences()) throws -> RuntimeEditorLedger {
        let config = draft(0)
        let platform = PlatformIntegrationConfig()
        let zero = ControlLifecycleRevision(rawValue: 0)!
        let module = PrivateModuleState(lifecycleRevision: zero, enabled: false, fenced: false)
        let observation = try PrivateConfigurationBridge.makeObservation(
            config: config, platform: platform, preferences: preferences, terminal: false,
            components: PrivateComponentSlots(
                runtime: .verified(baseline(.runtime, 1)), platform: .verified(baseline(.platform, 1)),
                preferences: .verified(baseline(.preferences, 1))
            ),
            modules: PrivateModuleSlots(proxy: module, dns: module, tunnels: module)
        )
        return RuntimeEditorLedger(observation: observation, config: config, platform: platform, preferences: preferences)
    }

    private static let stopCommand = ControlRuntimeCommand.stop(.dns)
    private static let startCommand = ControlRuntimeCommand.start(.proxy, ifModuleRevision: ControlLifecycleRevision(rawValue: 0)!)

    // MARK: The model

    func testEveryBoundedHistoryKeepsTheCausalAuthorityRules() throws {
        let start = try ledger()
        var transitions = 0
        var covered: [Step: Int] = [:]
        func explore(_ ledger: RuntimeEditorLedger, _ oracle: Oracle, _ path: [Step]) {
            guard path.count < Self.depth else { return }
            for step in Step.allCases {
                var ledger = ledger
                var oracle = oracle
                guard apply(step, &ledger, &oracle) else { continue }
                transitions += 1
                covered[step, default: 0] += 1
                check(ledger, oracle, path + [step])
                explore(ledger, oracle, path + [step])
            }
        }
        check(start, Oracle(), [])
        explore(start, Oracle(), [])

        // Deeper histories, by a fixed-seed walk, so out-of-order chains several commands long are reached.
        var random = SplitMix64(seed: 0x0C0D_0117)
        for _ in 0..<Self.walks {
            var ledger = start
            var oracle = Oracle()
            var path: [Step] = []
            for _ in 0..<Self.walkLength {
                // `edit` is always possible, so a few tries find a step.
                var taken: Step?
                for _ in 0..<64 {
                    let step = Step.allCases.randomElement(using: &random)!
                    if apply(step, &ledger, &oracle) {
                        taken = step
                        break
                    }
                }
                guard let step = taken else { break }
                path.append(step)
                transitions += 1
                covered[step, default: 0] += 1
                check(ledger, oracle, path)
            }
        }
        for step in Step.allCases {
            XCTAssertGreaterThan(covered[step, default: 0], 100, "the model reaches \(step)")
        }
        print("APPSTATE-EDITOR-MODEL transitions=\(transitions) depth=\(Self.depth) walks=\(Self.walks)x\(Self.walkLength)")
    }

    /// The shortest form of the own-Stop race (edit, sendStop, submit, execute, settleHost, deliverOldest) is six steps, past the full
    /// alphabet's exhaustive depth. Every history of six steps over the steps that race is made of, the resubmission check included, is
    /// explored exhaustively, and the race itself must be among them and end with the refused draft explained.
    func testEveryDepthSixHistoryOfTheOwnStopRaceKeepsTheRules() throws {
        let alphabet: [Step] = [.edit, .submit, .settleHost, .sendStop, .execute, .deliverOldest, .deliverNewest, .takeExplained]
        let race: [Step] = [.edit, .sendStop, .submit, .execute, .settleHost, .deliverOldest]
        let start = try ledger()
        var transitions = 0
        var raceExplained: Bool?
        func explore(_ ledger: RuntimeEditorLedger, _ oracle: Oracle, _ path: [Step]) {
            guard path.count < 6 else { return }
            for step in alphabet {
                var ledger = ledger
                var oracle = oracle
                guard apply(step, &ledger, &oracle) else { continue }
                transitions += 1
                check(ledger, oracle, path + [step])
                if path + [step] == race {
                    var taking = ledger
                    raceExplained = taking.takeExplainedMismatch()
                }
                explore(ledger, oracle, path + [step])
            }
        }
        explore(start, Oracle(), [])
        XCTAssertEqual(raceExplained, true, "the race was explored, and its own write explained the refused draft")
        print("APPSTATE-EDITOR-MODEL-RACE transitions=\(transitions) depth=6 alphabet=\(alphabet.count)")
    }

    /// Applies one step to both; false when the step cannot happen in this state.
    private func apply(_ step: Step, _ ledger: inout RuntimeEditorLedger, _ oracle: inout Oracle) -> Bool {
        switch step {
        case .edit:
            oracle.draftContent = oracle.nextContent
            oracle.nextContent += 1
            ledger.edited(.configuration)
            return true
        case .submit:
            guard ledger.needsSubmission(.configuration), ledger.canSubmit(.configuration) else { return false }
            let requestID = ControlRequestID(rawValue: UUID())
            guard let submission = ledger.submitConfiguration(draft(oracle.draftContent), PlatformIntegrationConfig(), requestID: requestID)
            else { return false }
            oracle.inFlight = (oracle.draftContent, submission.baselines.runtime?.version)
            return true
        case .settleHost, .settleNotPersisted, .settleStoreBusy, .settleConflict, .settleUnknownLanded, .settleUnknownNotLanded, .settleInternalLanded,
             .settleInternalNotLanded, .settleLostLanded, .settleLostNotLanded, .notAdmitted:
            return settle(step, &ledger, &oracle)
        case .foreignWrite:
            guard !oracle.foreignWritten else { return false }
            oracle.foreignWritten = true
            oracle.runtimeVersion += 1
            oracle.contents[oracle.runtimeVersion] = (-1, oracle.contents[oracle.runtimeVersion - 1]!.dns)
            return true
        case .sendStop, .sendStart:
            guard oracle.commands.count < 2 else { return false }
            let requestID = ControlRequestID(rawValue: UUID())
            ledger.ownCommandSent(step == .sendStart ? Self.startCommand : Self.stopCommand, requestID: requestID)
            oracle.commands.append(Command(requestID: requestID, isStart: step == .sendStart))
            return true
        case .execute:
            guard let index = oracle.commands.firstIndex(where: { $0.ran == nil }) else { return false }
            let prior = oracle.runtimeVersion
            let current = oracle.contents[prior]!
            oracle.runtimeVersion += 1
            oracle.ownVersions.insert(oracle.runtimeVersion)
            // A saved Start commits the saved pair with DNS's staged bit on; a DNS Stop's disable save turns it off.
            oracle.contents[oracle.runtimeVersion] = (current.content, oracle.commands[index].isStart)
            oracle.commands[index].ran = (prior, oracle.platformVersion, oracle.runtimeVersion)
            return true
        case .deliverOldest, .deliverNewest, .deliverOldestLost, .deliverOldestInternal:
            guard !oracle.commands.isEmpty else { return false }
            let command = step == .deliverNewest ? oracle.commands.removeLast() : oracle.commands.removeFirst()
            switch step {
            case .deliverOldestLost:
                oracle.unknownOwnEffect = true
                ledger.ownCommandEnded(command.requestID, outcome: nil)
            case .deliverOldestInternal:
                oracle.unknownOwnEffect = true
                ledger.ownCommandEnded(command.requestID, outcome: .failed(.internalFailure))
            default:
                ledger.ownCommandEnded(command.requestID, outcome: hostOutcome(of: command))
            }
            return true
        case .takeExplained:
            guard let refused = oracle.refused else { return false }
            if ledger.takeExplainedMismatch() {
                // Only the refused draft goes again, and only once something moved the file past the baseline it was refused under.
                XCTAssertEqual(oracle.draftContent, refused.content, "a draft edited since its refusal was sent again")
                XCTAssertGreaterThan(oracle.runtimeVersion, refused.under, "a refusal nothing moved past was taken as explained")
                XCTAssertFalse(ledger.takeExplainedMismatch(), "an explained refusal is taken at most once")
                oracle.refused = nil
            } else if oracle.draftContent == refused.content, !oracle.foreignWritten, !oracle.unknownOwnEffect, oracle.inFlight == nil,
                      oracle.commands.isEmpty {
                // Nobody else wrote: the refusal was this client's own write, every one of which has now been delivered and chained.
                XCTFail("an own write explained the refusal of the current draft, and the draft was not sent again")
            }
            return true
        }
    }

    /// What the host answers for an own command, built from the wire types the production path reads.
    private func hostOutcome(of command: Command) -> ControlOperationOutcome {
        guard let ran = command.ran else {
            // It never ran: a DNS Stop completes with no write; a saved Start fails with its closed cause before any commit.
            if command.isStart { return .failed(.effectFailed) }
            return completion(.stop, .settled)
        }
        let runtime = write(.persisted(reportedError: false), .runtime, ran.produced)
        if command.isStart {
            guard let receipt = try? ControlConfigurationReceipt(
                requestID: command.requestID, incarnation: incarnation, runtime: runtime,
                platform: write(.unchanged, .platform, ran.platform), committedDNSForwarderEnabled: true,
                modules: [ControlModuleReceipt(module: .proxy, result: .started)],
                prior: ControlCommitPrior(runtime: baseline(.runtime, ran.runtime), platform: baseline(.platform, ran.platform))
            ) else { preconditionFailure("an inconsistent fixture receipt") }
            return .configurationSettled(receipt)
        }
        guard let disable = try? ControlDNSDisableWrite(prior: baseline(.runtime, ran.runtime), runtime: runtime) else {
            preconditionFailure("an inconsistent fixture disable")
        }
        return completion(.stop, .dnsDisable(disable))
    }

    private func completion(_ command: ControlRuntimeCommandKind, _ result: ControlCommandResult) -> ControlOperationOutcome {
        guard let revision = ControlPresentationRevision(rawValue: 1),
              let built = try? ControlCompletion(command: command, presentationRevision: revision, result: result)
        else { preconditionFailure("an inconsistent fixture completion") }
        return .completed(built)
    }

    /// The host's answer for the submission in flight, applied to the files when it writes.
    private func settle(_ step: Step, _ ledger: inout RuntimeEditorLedger, _ oracle: inout Oracle) -> Bool {
        guard let active = ledger.active, let inFlight = oracle.inFlight else { return false }
        let current = inFlight.under == oracle.runtimeVersion
        let lands: Bool
        switch step {
        case .settleUnknownLanded, .settleInternalLanded, .settleLostLanded: lands = true
        case .settleHost: lands = current
        default: lands = false
        }
        // Only a write under the file's own baseline can land.
        if lands && !current { return false }
        if (step == .settleNotPersisted || step == .settleConflict) && !current { return false }
        oracle.inFlight = nil
        let platformUnchanged = write(.unchanged, .platform, oracle.platformVersion)
        if lands {
            let dns = oracle.contents[oracle.runtimeVersion]!.dns
            oracle.runtimeVersion += 1
            oracle.contents[oracle.runtimeVersion] = (inFlight.content, dns)
            oracle.ownVersions.insert(oracle.runtimeVersion)
        }
        func receipt(_ runtime: ControlComponentWrite, _ platform: ControlComponentWrite, dns: Bool?) -> ControlOperationOutcome {
            guard let built = try? ControlConfigurationReceipt(
                requestID: active.requestID, incarnation: incarnation, runtime: runtime, platform: platform,
                committedDNSForwarderEnabled: dns, modules: []
            ) else { preconditionFailure("an inconsistent fixture receipt") }
            return .configurationSettled(built)
        }
        let heldBehind = write(.notAttempted(.heldBehindRuntime), .platform, nil)
        switch step {
        case .settleHost:
            if current {
                oracle.cleanContent = inFlight.content
                ledger.settled(active.requestID, incarnation: incarnation, outcome: receipt(
                    write(.persisted(reportedError: false), .runtime, oracle.runtimeVersion), platformUnchanged,
                    dns: oracle.contents[oracle.runtimeVersion]!.dns
                ))
            } else {
                if let under = inFlight.under { oracle.refused = (inFlight.content, under) }
                ledger.settled(active.requestID, incarnation: incarnation, outcome: receipt(
                    write(.notAttempted(.baselineMismatch), .runtime, nil), heldBehind, dns: nil
                ))
            }
        case .settleNotPersisted:
            ledger.settled(active.requestID, incarnation: incarnation, outcome: receipt(write(.notPersisted, .runtime, nil), heldBehind, dns: nil))
        case .settleStoreBusy:
            ledger.settled(active.requestID, incarnation: incarnation, outcome: .failed(.storeBusy))
        case .settleConflict:
            // The outside edit makes every held baseline of this file stale for good: only a reload may write it again.
            oracle.unknownOwnEffect = true
            ledger.settled(active.requestID, incarnation: incarnation, outcome: receipt(write(.conflict, .runtime, nil), heldBehind, dns: nil))
        case .settleUnknownLanded, .settleUnknownNotLanded:
            oracle.unknownOwnEffect = true
            ledger.settled(active.requestID, incarnation: incarnation, outcome: receipt(
                write(.unknown(.readbackFailed, reportedError: true), .runtime, nil), platformUnchanged, dns: nil
            ))
        case .settleInternalLanded, .settleInternalNotLanded:
            oracle.unknownOwnEffect = true
            ledger.settled(active.requestID, incarnation: incarnation, outcome: .failed(.internalFailure))
        case .settleLostLanded, .settleLostNotLanded:
            oracle.unknownOwnEffect = true
            ledger.settlementUnknown(active.requestID)
        default:
            ledger.notAdmitted(active.requestID)
        }
        return true
    }

    private func check(_ ledger: RuntimeEditorLedger, _ oracle: Oracle, _ path: [Step], line: UInt = #line) {
        let trace = path.map { "\($0)" }.joined(separator: ",")
        // 1. A clean draft is what the client's own last verified write put on disk.
        if !ledger.isDirty(.configuration) {
            XCTAssertEqual(oracle.draftContent, oracle.cleanContent, "a newer draft was marked clean: \(trace)", line: line)
        }
        if let held = ledger.baselines.runtime {
            // 2. Authority comes only from this client's own chain.
            XCTAssertTrue(oracle.ownVersions.contains(held.version), "authority from another client's write: \(trace)", line: line)
            // 3. What `saved` claims is what the file holds at the held baseline.
            if let holds = oracle.contents[held.version] {
                XCTAssertEqual(ledger.saved.config.profileName, "content-\(holds.content)", "saved content: \(trace)", line: line)
                XCTAssertEqual(ledger.saved.config.dnsForwarderEnabled, holds.dns, "saved DNS bit: \(trace)", line: line)
            }
        }
        // 4. An effect this client cannot know leaves the file without authority, whether or not it landed.
        if oracle.unknownOwnEffect {
            XCTAssertNil(ledger.baselines.runtime, "authority kept over an unknown own write: \(trace)", line: line)
        }
        // 5. Nothing stranded once nothing of this client's is out, whoever else wrote and whatever stayed unknown: no held mismatch, no
        //    chained write, no own command.
        if oracle.inFlight == nil, oracle.commands.isEmpty {
            XCTAssertTrue(ledger.heldMismatches.isEmpty, "a mismatch left held: \(trace)", line: line)
            XCTAssertTrue(ledger.chained.isEmpty, "a chained write left stranded: \(trace)", line: line)
            XCTAssertTrue(ledger.ownCommands.isEmpty, line: line)
        }
        //    Liveness: with no other writer and nothing unknown, nothing is given up needlessly.
        if !oracle.foreignWritten, !oracle.unknownOwnEffect, oracle.inFlight == nil, oracle.commands.isEmpty {
            XCTAssertEqual(ledger.baselines.runtime?.version, oracle.runtimeVersion, "own authority lost or behind: \(trace)", line: line)
            XCTAssertEqual(ledger.baselines.platform?.version, oracle.platformVersion, "platform authority lost: \(trace)", line: line)
        }
    }

    // MARK: Focused cases

    private func sendStop(_ ledger: inout RuntimeEditorLedger) -> ControlRequestID {
        let requestID = ControlRequestID(rawValue: UUID())
        ledger.ownCommandSent(Self.stopCommand, requestID: requestID)
        return requestID
    }

    private func disable(_ requestID: ControlRequestID, from prior: UInt64, to produced: UInt64) throws -> ControlOperationOutcome {
        completion(.stop, .dnsDisable(try ControlDNSDisableWrite(
            prior: baseline(.runtime, prior), runtime: write(.persisted(reportedError: false), .runtime, produced)
        )))
    }

    private func mismatch(_ requestID: ControlRequestID) throws -> ControlOperationOutcome {
        .configurationSettled(try ControlConfigurationReceipt(
            requestID: requestID, incarnation: incarnation, runtime: write(.notAttempted(.baselineMismatch), .runtime, nil),
            platform: write(.notAttempted(.heldBehindRuntime), .platform, nil), committedDNSForwarderEnabled: nil, modules: []
        ))
    }

    private func submit(_ ledger: inout RuntimeEditorLedger, _ content: Int) throws -> ControlRequestID {
        let requestID = ControlRequestID(rawValue: UUID())
        _ = try XCTUnwrap(ledger.submitConfiguration(draft(content), PlatformIntegrationConfig(), requestID: requestID))
        return requestID
    }

    /// A write the client caused through its own saved command, delivered before the receipt that leads to its prior, waits for it.
    func testAnOutOfOrderOwnCommandWriteWaitsForTheReceiptThatLeadsToItsPrior() throws {
        var ledger = try ledger()
        ledger.edited(.configuration)
        let update = try submit(&ledger, 1)
        let stop = sendStop(&ledger)
        // The Stop's disable save lands on version 2, which the update's write produced, and is delivered first.
        ledger.ownCommandEnded(stop, outcome: try disable(stop, from: 2, to: 3))
        XCTAssertEqual(ledger.baselines.runtime, baseline(.runtime, 1), "the chained write waits")
        ledger.settled(update, incarnation: incarnation, outcome: .configurationSettled(try ControlConfigurationReceipt(
            requestID: update, incarnation: incarnation, runtime: write(.persisted(reportedError: false), .runtime, 2),
            platform: write(.unchanged, .platform, 1), committedDNSForwarderEnabled: true, modules: []
        )))
        XCTAssertEqual(ledger.baselines.runtime, baseline(.runtime, 3), "the receipt led to the prior, and the chain completed")
        XCTAssertFalse(ledger.saved.config.dnsForwarderEnabled)
        XCTAssertFalse(ledger.isDirty(.configuration))
    }

    /// The app's race: a save submitted while its own DNS Stop is out meets the Stop's write as a mismatch. It is held, the Stop's chain
    /// explains it, and the same draft is offered again once; a newer edit is never resubmitted by the explanation.
    func testAMismatchAnOwnStopExplainsIsHeldAndTheSameDraftGoesAgain() throws {
        for editsAfter in [false, true] {
            var ledger = try ledger()
            let stop = sendStop(&ledger)
            ledger.edited(.configuration)
            let update = try submit(&ledger, 1)
            ledger.settled(update, incarnation: incarnation, outcome: try mismatch(update))
            XCTAssertEqual(ledger.heldMismatches[.runtime], baseline(.runtime, 1), "held while the Stop is out")
            XCTAssertNotNil(ledger.baselines.runtime)
            XCTAssertFalse(ledger.takeExplainedMismatch(), "nothing explained it yet")
            if editsAfter { ledger.edited(.configuration) }
            ledger.ownCommandEnded(stop, outcome: try disable(stop, from: 1, to: 2))
            XCTAssertEqual(ledger.baselines.runtime, baseline(.runtime, 2))
            XCTAssertTrue(ledger.heldMismatches.isEmpty)
            XCTAssertEqual(ledger.takeExplainedMismatch(), !editsAfter, "only the refused draft goes again")
            XCTAssertFalse(ledger.takeExplainedMismatch(), "taken once")
            XCTAssertTrue(ledger.filesNeedingReload.isEmpty)
            XCTAssertTrue(ledger.canSubmit(.configuration))
        }
    }

    /// The quit's final-save precondition (`quitSaveBaselines`): a prior's own verified receipt wins. A file the prior's own settlement
    /// left without authority (a conflict, an unknown write, a failure that may have written) keeps the verified baseline the save was
    /// frozen under, as the save's precondition only: the ledger that settlement leaves gains no authority from it, and the frozen ledger
    /// is unchanged. An unsettled prior leaves the frozen baselines.
    func testTheQuitsFinalSavePreconditionNeverOutranksAVerifiedReceiptOrRestoresAuthority() throws {
        var frozen = try ledger()
        frozen.edited(.configuration)
        let prior = try submit(&frozen, 1)
        frozen.edited(.configuration)
        func settled(_ runtime: ControlComponentWrite) throws -> RuntimeQuitStep {
            .settled(.configurationSettled(try ControlConfigurationReceipt(
                requestID: prior, incarnation: incarnation, runtime: runtime, platform: write(.unchanged, .platform, 1),
                committedDNSForwarderEnabled: runtime.write.isVerified ? false : nil, modules: []
            )))
        }
        let landed = frozen.afterQuitPrior(try settled(write(.persisted(reportedError: false), .runtime, 2)), incarnation: incarnation)
        XCTAssertEqual(frozen.quitSaveBaselines(after: landed).runtime, baseline(.runtime, 2), "the verified own receipt wins")
        let dropping: [RuntimeQuitStep] = [
            try settled(write(.conflict, .runtime, nil)),
            try settled(write(.unknown(.readbackFailed, reportedError: true), .runtime, nil)),
            .settled(.failed(.internalFailure)),
        ]
        for step in dropping {
            let after = frozen.afterQuitPrior(step, incarnation: incarnation)
            XCTAssertNil(after.baselines.runtime, "\(step)")
            XCTAssertEqual(frozen.quitSaveBaselines(after: after).runtime, baseline(.runtime, 1), "the frozen precondition: \(step)")
            XCTAssertTrue(after.filesNeedingReload.contains(.runtime), "no authority restored: \(step)")
            XCTAssertFalse(after.canSubmit(.configuration), "the ordinary editor cannot write it: \(step)")
        }
        XCTAssertEqual(frozen.baselines.runtime, baseline(.runtime, 1), "the frozen ledger is unchanged")
        XCTAssertEqual(frozen.active?.requestID, prior)
        let unsettled = frozen.afterQuitPrior(.unsettled(ControlOperationID(rawValue: UUID())), incarnation: incarnation)
        XCTAssertEqual(frozen.quitSaveBaselines(after: unsettled).runtime, baseline(.runtime, 1))
        XCTAssertEqual(frozen.quitSaveBaselines(after: unsettled).platform, baseline(.platform, 1))
    }

    /// A mismatch an own command could have explained, but which ended without a write, is unexplained: the file loses its authority.
    func testAMismatchTheOwnCommandDidNotExplainLosesAuthorityWhenItEnds() throws {
        var ledger = try ledger()
        let stop = sendStop(&ledger)
        ledger.edited(.configuration)
        let update = try submit(&ledger, 1)
        ledger.settled(update, incarnation: incarnation, outcome: try mismatch(update))
        XCTAssertTrue(ledger.filesNeedingReload.isEmpty, "held while the Stop is out")
        ledger.ownCommandEnded(stop, outcome: completion(.stop, .settled))
        XCTAssertEqual(ledger.filesNeedingReload, [.runtime], "no own write explained it")
        XCTAssertFalse(ledger.takeExplainedMismatch())
    }

    /// With no own work out, a mismatch is another writer's, and the authority is lost at once, offered for reload.
    func testAMismatchWithNoOwnWorkOutLosesAuthorityAtOnce() throws {
        var ledger = try ledger()
        ledger.edited(.configuration)
        let update = try submit(&ledger, 1)
        ledger.settled(update, incarnation: incarnation, outcome: try mismatch(update))
        XCTAssertEqual(ledger.filesNeedingReload, [.runtime])
        XCTAssertNotNil(ledger.baselines.platform, "the platform file held behind was not written")
    }

    /// Found by the model: an own command whose end is unknown takes the file's authority while a save is out; that save's verified
    /// receipt later cannot give it back, since the command's write may still land after it.
    func testAReceiptNeverRestoresAuthorityAnUnknownOwnWriteTookAway() throws {
        var ledger = try ledger()
        ledger.edited(.configuration)
        let update = try submit(&ledger, 1)
        let stop = sendStop(&ledger)
        ledger.ownCommandEnded(stop, outcome: nil)
        XCTAssertNil(ledger.baselines.runtime)
        ledger.settled(update, incarnation: incarnation, outcome: .configurationSettled(try ControlConfigurationReceipt(
            requestID: update, incarnation: incarnation, runtime: write(.persisted(reportedError: false), .runtime, 2),
            platform: write(.unchanged, .platform, 1), committedDNSForwarderEnabled: false, modules: []
        )))
        XCTAssertNil(ledger.baselines.runtime, "only an explicit reload restores it")
        XCTAssertEqual(ledger.filesNeedingReload, [.runtime])
        XCTAssertFalse(ledger.isDirty(.configuration), "the draft itself was saved, as its receipt says")
    }

    /// A chained write whose prior nothing still out can lead to is an own write the editor cannot place: its file loses authority
    /// instead of waiting forever.
    func testAStrandedChainedWriteDropsItsFilesAuthority() throws {
        var ledger = try ledger()
        let stop = sendStop(&ledger)
        ledger.ownCommandEnded(stop, outcome: try disable(stop, from: 5, to: 6))
        XCTAssertEqual(ledger.filesNeedingReload, [.runtime])
        XCTAssertTrue(ledger.chained.isEmpty)
    }

    /// A chained write conditional on a version the file has moved past is causally obsolete and is pruned, not kept.
    func testAnObsoleteChainedWriteIsPruned() throws {
        var ledger = try ledger()
        ledger.edited(.configuration)
        let update = try submit(&ledger, 1)
        let stop = sendStop(&ledger)
        ledger.settled(update, incarnation: incarnation, outcome: .configurationSettled(try ControlConfigurationReceipt(
            requestID: update, incarnation: incarnation, runtime: write(.persisted(reportedError: false), .runtime, 3),
            platform: write(.unchanged, .platform, 1), committedDNSForwarderEnabled: false, modules: []
        )))
        let other = sendStop(&ledger)
        ledger.ownCommandEnded(stop, outcome: try disable(stop, from: 1, to: 2))
        XCTAssertTrue(ledger.chained.isEmpty, "pruned while another own command is still out")
        XCTAssertEqual(ledger.baselines.runtime, baseline(.runtime, 3))
        ledger.ownCommandNotRun(other)
        XCTAssertTrue(ledger.filesNeedingReload.isEmpty)
    }

    /// The chain is bounded. Past it, the file gives up its authority explicitly; no fact is evicted silently.
    func testAChainPastItsBoundDropsTheFilesAuthorityInsteadOfAFact() throws {
        var ledger = try ledger()
        ledger.edited(.configuration)
        _ = try submit(&ledger, 1)
        // The submission in flight could lead to any of these priors, so each waits.
        for index in 0..<RuntimeEditorLedger.maximumChainedWrites {
            let stop = sendStop(&ledger)
            ledger.ownCommandEnded(stop, outcome: try disable(stop, from: UInt64(100 + 2 * index), to: UInt64(101 + 2 * index)))
        }
        XCTAssertEqual(ledger.chained.count, RuntimeEditorLedger.maximumChainedWrites)
        XCTAssertNotNil(ledger.baselines.runtime)
        let overflow = sendStop(&ledger)
        ledger.ownCommandEnded(overflow, outcome: try disable(overflow, from: 99, to: 300))
        XCTAssertNil(ledger.baselines.runtime, "the overflow is explicit: the runtime file needs a reload")
        XCTAssertTrue(ledger.chained.isEmpty)
        XCTAssertNotNil(ledger.baselines.platform, "another file's authority is untouched")
    }

    /// Own commands are bounded by the app's command lanes; one past it cannot be tracked, so the files it may write give up authority.
    func testAnOwnCommandPastTheBoundDropsTheFilesItMayWrite() throws {
        XCTAssertEqual(RuntimeEditorLedger.maximumOwnCommands, AppState.maximumCommandsInFlight + ControlModule.allCases.count)
        var ledger = try ledger()
        for _ in 0..<RuntimeEditorLedger.maximumOwnCommands { _ = sendStop(&ledger) }
        XCTAssertNotNil(ledger.baselines.runtime)
        ledger.ownCommandSent(Self.startCommand, requestID: ControlRequestID(rawValue: UUID()))
        XCTAssertNil(ledger.baselines.runtime)
        XCTAssertNil(ledger.baselines.platform)
        XCTAssertNotNil(ledger.baselines.preferences)
    }

    /// The production derivation of an own command's end: which outcomes are proven write-free and which lose authority.
    func testHowAnOwnCommandEndsDecidesItsFilesAuthority() throws {
        let cases: [(ControlRuntimeCommand, ControlOperationOutcome?, keeps: Bool)] = [
            (Self.stopCommand, completion(.stop, .settled), true),
            (Self.stopCommand, .failed(.storeBusy), true),
            (Self.stopCommand, .failed(.staleRevision), false),
            (Self.stopCommand, .failed(.internalFailure), false),
            (Self.stopCommand, nil, false),
            (Self.startCommand, .failed(.effectFailed), true),
            (Self.startCommand, .failed(.staleRevision), true),
            (Self.startCommand, .failed(.internalFailure), false),
            (Self.startCommand, .superseded(by: ControlOperationID(rawValue: UUID())), false),
            (Self.startCommand, nil, false),
        ]
        for (command, outcome, keeps) in cases {
            var ledger = try ledger()
            let requestID = ControlRequestID(rawValue: UUID())
            ledger.ownCommandSent(command, requestID: requestID)
            ledger.ownCommandEnded(requestID, outcome: outcome)
            XCTAssertEqual(ledger.baselines.runtime != nil, keeps, "\(command) \(String(describing: outcome))")
        }
        // A receipt for another request is not this command's write.
        var ledger = try ledger()
        let requestID = ControlRequestID(rawValue: UUID())
        ledger.ownCommandSent(Self.startCommand, requestID: requestID)
        ledger.ownCommandEnded(requestID, outcome: .configurationSettled(try ControlConfigurationReceipt(
            requestID: ControlRequestID(rawValue: UUID()), incarnation: incarnation,
            runtime: write(.persisted(reportedError: false), .runtime, 2), platform: write(.unchanged, .platform, 1),
            committedDNSForwarderEnabled: true, modules: [],
            prior: ControlCommitPrior(runtime: baseline(.runtime, 1), platform: baseline(.platform, 1))
        )))
        XCTAssertNil(ledger.baselines.runtime, "another request's receipt cannot be chained, so the write is unknown")
        // A command that was never this ledger's changes nothing.
        var untouched = try self.ledger()
        untouched.ownCommandEnded(ControlRequestID(rawValue: UUID()), outcome: nil)
        XCTAssertNotNil(untouched.baselines.runtime)
        // A command never run wrote nothing.
        var notRun = try self.ledger()
        let refused = sendStop(&notRun)
        notRun.ownCommandNotRun(refused)
        XCTAssertNotNil(notRun.baselines.runtime)
        XCTAssertTrue(notRun.ownCommands.isEmpty)
    }

    /// A saved Start's own receipt is chained through its exact prior: both files advance and the saved DNS bit follows the commit.
    func testASavedStartsReceiptChainsBothFiles() throws {
        var ledger = try ledger()
        let requestID = ControlRequestID(rawValue: UUID())
        ledger.ownCommandSent(Self.startCommand, requestID: requestID)
        ledger.ownCommandEnded(requestID, outcome: .configurationSettled(try ControlConfigurationReceipt(
            requestID: requestID, incarnation: incarnation, runtime: write(.persisted(reportedError: false), .runtime, 2),
            platform: write(.persisted(reportedError: false), .platform, 2), committedDNSForwarderEnabled: true,
            modules: [ControlModuleReceipt(module: .proxy, result: .started)],
            prior: ControlCommitPrior(runtime: baseline(.runtime, 1), platform: baseline(.platform, 1))
        )))
        XCTAssertEqual(ledger.baselines.runtime, baseline(.runtime, 2))
        XCTAssertEqual(ledger.baselines.platform, baseline(.platform, 2))
        XCTAssertTrue(ledger.saved.config.dnsForwarderEnabled)
        XCTAssertFalse(ledger.isDirty(.configuration), "a command's write is no draft edit")
    }

    /// Only a store-busy failure is proven to precede every write; any other failure loses the files' authority.
    func testOnlyAStoreBusyFailureKeepsTheBaselines() throws {
        for (code, keeps) in [(ControlFailureCode.storeBusy, true), (.internalFailure, false), (.effectFailed, false), (.staleRevision, false)] {
            var ledger = try ledger()
            ledger.edited(.configuration)
            let requestID = try submit(&ledger, 1)
            ledger.settled(requestID, incarnation: incarnation, outcome: .failed(code))
            XCTAssertEqual(ledger.baselines.runtime != nil, keeps, "\(code)")
            XCTAssertTrue(ledger.isDirty(.configuration), "\(code)")
        }
    }

    /// Another request's receipt changes nothing; a receipt naming this request under another incarnation, or carrying a commit prior a
    /// private update never has, is not a fact about this request's write and loses authority.
    func testAReceiptThatIsNotThisRequestsOwnGrantsNothing() throws {
        var other = try ledger()
        other.edited(.configuration)
        let own = try submit(&other, 1)
        let stranger = ControlRequestID(rawValue: UUID())
        other.settled(stranger, incarnation: incarnation, outcome: .configurationSettled(try ControlConfigurationReceipt(
            requestID: stranger, incarnation: incarnation, runtime: write(.persisted(reportedError: false), .runtime, 9),
            platform: write(.persisted(reportedError: false), .platform, 9), committedDNSForwarderEnabled: false, modules: []
        )))
        XCTAssertEqual(other.baselines.runtime, baseline(.runtime, 1))
        XCTAssertEqual(other.active?.requestID, own)
        XCTAssertTrue(other.isDirty(.configuration))

        for (incarnation, prior) in [(ControlHostIncarnation(rawValue: UUID()), nil),
                                     (self.incarnation, ControlCommitPrior(runtime: baseline(.runtime, 1), platform: baseline(.platform, 1)))] {
            var ledger = try ledger()
            ledger.edited(.configuration)
            let requestID = try submit(&ledger, 1)
            ledger.settled(requestID, incarnation: self.incarnation, outcome: .configurationSettled(try ControlConfigurationReceipt(
                requestID: requestID, incarnation: incarnation, runtime: write(.persisted(reportedError: false), .runtime, 2),
                platform: write(.unchanged, .platform, 1), committedDNSForwarderEnabled: false, modules: [], prior: prior
            )))
            XCTAssertNil(ledger.baselines.runtime)
            XCTAssertTrue(ledger.isDirty(.configuration), "nothing it says may mark the draft clean")
        }
    }

    /// Preferences are their own group: a verified receipt rebases and cleans only that draft; a mismatch, which no own command can
    /// explain, loses only the preferences file's authority.
    func testPreferencesSettleOnTheirOwnReceipt() throws {
        var ledger = try ledger()
        ledger.edited(.preferences)
        ledger.edited(.configuration)
        let requestID = ControlRequestID(rawValue: UUID())
        var preferences = AppPreferences()
        preferences.floatingWindowEnabled.toggle()
        _ = try XCTUnwrap(ledger.submitPreferences(preferences, requestID: requestID))
        XCTAssertFalse(ledger.canSubmit(.configuration), "one operation in flight")
        ledger.settled(requestID, incarnation: incarnation, outcome: .preferencesSettled(try ControlPreferencesReceipt(
            requestID: requestID, incarnation: incarnation, preferences: write(.persisted(reportedError: false), .preferences, 2)
        )))
        XCTAssertFalse(ledger.isDirty(.preferences))
        XCTAssertTrue(ledger.isDirty(.configuration))
        XCTAssertEqual(ledger.saved.preferences.floatingWindowEnabled, preferences.floatingWindowEnabled)
        XCTAssertEqual(ledger.baselines.preferences, baseline(.preferences, 2))

        ledger.edited(.preferences)
        let next = ControlRequestID(rawValue: UUID())
        _ = try XCTUnwrap(ledger.submitPreferences(AppPreferences(), requestID: next))
        ledger.settled(next, incarnation: incarnation, outcome: .preferencesSettled(try ControlPreferencesReceipt(
            requestID: next, incarnation: incarnation, preferences: write(.notAttempted(.baselineMismatch), .preferences, nil)
        )))
        XCTAssertEqual(ledger.filesNeedingReload, [.preferences])
        XCTAssertNotNil(ledger.baselines.runtime)
    }

    /// The login-item admin write moves only the platform baseline and the saved flag, and only when it verified.
    func testTheLoginItemWriteMovesOnlyThePlatformFileOnItsOwnVerifiedWrite() throws {
        for verified in [true, false] {
            var ledger = try ledger()
            let requestID = ControlRequestID(rawValue: UUID())
            _ = try XCTUnwrap(ledger.submitLaunchAtLogin(true, requestID: requestID))
            let platform = verified ? write(.persisted(reportedError: false), .platform, 2) : write(.notPersisted, .platform, nil)
            ledger.settled(requestID, incarnation: incarnation, outcome: completion(.setLaunchAtLogin, .platformWrite(platform)))
            XCTAssertEqual(ledger.saved.platform.launchAtLogin, verified)
            XCTAssertEqual(ledger.baselines.platform, baseline(.platform, verified ? 2 : 1))
            XCTAssertEqual(ledger.baselines.runtime, baseline(.runtime, 1))
            XCTAssertFalse(ledger.isDirty(.configuration))
        }
    }

    /// The quit's read of the prior update is exactly that update's own settlement; an unsettled prior leaves the submitted baselines.
    func testTheQuitsViewOfThePriorUpdateIsItsOwnSettlementOnly() throws {
        var ledger = try ledger()
        ledger.edited(.configuration)
        let requestID = try submit(&ledger, 1)
        let unsettled = ledger.afterQuitPrior(.unsettled(ControlOperationID(rawValue: UUID())), incarnation: incarnation)
        XCTAssertEqual(unsettled.baselines.runtime, baseline(.runtime, 1))
        let settled = ledger.afterQuitPrior(.settled(.configurationSettled(try ControlConfigurationReceipt(
            requestID: requestID, incarnation: incarnation, runtime: write(.persisted(reportedError: false), .runtime, 2),
            platform: write(.unchanged, .platform, 1), committedDNSForwarderEnabled: false, modules: []
        ))), incarnation: incarnation)
        XCTAssertEqual(settled.baselines.runtime, baseline(.runtime, 2))
        XCTAssertEqual(settled.saved.config.profileName, "content-1")
        XCTAssertEqual(ledger.baselines.runtime, baseline(.runtime, 1), "the quit's view is a copy")
        let failed = ledger.afterQuitPrior(.settled(.failed(.internalFailure)), incarnation: incarnation)
        XCTAssertNil(failed.baselines.runtime)
    }
}

/// `RuntimeEditorSession` over the actual host, its framed client, observer and private editor client, for the order the app cannot
/// force: its own DNS Stop's chained write reaches the editor before the `baselineMismatch` receipt of a save frozen under the older
/// baseline. The save's frame is held before it is sent (the host has no record of it) while the Stop runs and its settlement is handed
/// to the session as `AppState.dispatch` hands it; then the frame goes and meets the Stop's write.
@MainActor
final class RuntimeEditorSessionChainTests: XCTestCase {
    private var harness: InteractiveHostHarness?
    private var observer: RuntimeObserver?

    override func tearDown() async throws {
        observer?.stop()
        observer = nil
        await harness?.tearDown()
        harness = nil
        try await super.tearDown()
    }

    private final class Drafts {
        var config: ProxyConfig
        let platform: PlatformIntegrationConfig
        let preferences: AppPreferences
        init(_ values: (config: ProxyConfig, platform: PlatformIntegrationConfig, preferences: AppPreferences)) {
            config = values.config
            platform = values.platform
            preferences = values.preferences
        }
    }

    private func deadline() -> RuntimeDeadline { .after(.seconds(30), from: .now) }

    /// The refused draft is sent again exactly once and verified when nothing was edited since; an edit made after it was refused is
    /// never sent by that explanation, and stays a dirty draft its own next save writes.
    func testAnOwnStopsWriteChainedBeforeTheMismatchReceiptSendsTheRefusedDraftOnceAndNoLaterEdit() async throws {
        for editsAfter in [false, true] {
            let harness = try makeInteractiveHarness(platform: PlatformIntegrationConfig(), dnsForwarderEnabled: true)
            self.harness = harness
            let host = try await harness.makeHost()
            let composition = RuntimeControlComposition(
                host: host, limits: try RuntimeServiceFixtures.hostLimits(subscribers: 2), timing: .system, scheduling: TaskOwnerScheduling()
            )
            let control = try makeFramedRuntimeClient(
                transport: composition.transport, limits: try ControlFrameLimits(maxFrameBytes: 64 * 1024), wireBudgetCap: .seconds(30)
            )
            let held = HeldPrivateTransport(inner: composition.transport)
            defer { held.release() }
            let editorClient = PrivateEditorClient(transport: held)
            let incarnation = try await control.readSnapshot(deadline: deadline()).stamp.incarnation
            let reading = deadline()
            guard case .observation(let observation) = try await editorClient.read(
                requestID: ControlRequestID(rawValue: UUID()), expectedIncarnation: incarnation,
                budget: try reading.wireBudget(at: .now, cappedAt: .seconds(30)), deadline: reading
            ) else { return XCTFail("the editor read an observation") }
            let drafts = Drafts(try PrivateConfigurationBridge.makeValues(from: observation))
            let original = drafts.config.health.checkInterval
            let observer = RuntimeObserver(
                control: control, presentation: RuntimePresentationAdapter(), incarnation: incarnation,
                rowBudget: ControlRowBudget(maxRows: 10, maxBytes: 1_024)
            )
            self.observer = observer
            observer.start()
            var settled: [(RuntimeEditorLedger.Submission, ControlOperationOutcome)] = []
            let session = RuntimeEditorSession(
                control: control, editor: editorClient, observer: observer, incarnation: incarnation,
                ledger: RuntimeEditorLedger(
                    observation: observation, config: drafts.config, platform: drafts.platform, preferences: drafts.preferences
                ),
                drafts: { (drafts.config, drafts.platform, drafts.preferences) },
                moduleIntents: { _ in PrivateModuleSlots(proxy: .saveOnly, dns: .saveOnly, tunnels: .saveOnly) },
                report: { report in
                    if case .settled(let submission, let outcome) = report { settled.append((submission, outcome)) }
                }
            )
            let frozenUnder = try XCTUnwrap(session.ledger.baselines.runtime)

            drafts.config.health.checkInterval = original + 7
            session.edited(.configuration)
            held.arm(.beforeSend)
            session.save(.configuration)
            await held.waitUntilHeld()

            // The app's own DNS Stop, tracked from before its send to its settlement, exactly as `AppState.dispatch` does.
            let stopID = ControlRequestID(rawValue: UUID())
            session.ownCommandSent(.stop(.dns), requestID: stopID)
            guard case .accepted(let stop) = try await control.submit(
                .stop(.dns), requestID: stopID, expectedIncarnation: incarnation, deadline: deadline()
            ) else { return XCTFail("the Stop was admitted") }
            let stopped = await observer.settlement(of: stop)
            session.ownCommandEnded(outcome: stopped, requestID: stopID)
            XCTAssertNotEqual(session.ledger.baselines.runtime, frozenUnder, "the Stop's chained write moved the baseline first")
            if editsAfter {
                drafts.config.health.checkInterval = original + 9
                session.edited(.configuration)
            }

            held.release()
            await session.settle()
            let saved = try ProxyConfigPersistence.load(in: harness.environment, allowMissing: false)
            let first = try XCTUnwrap(settled.first)
            guard case .configurationSettled(let refusal) = first.1, case .notAttempted(.baselineMismatch) = refusal.runtime.write else {
                return XCTFail("the held save met the Stop's write: \(first.1)")
            }
            XCTAssertEqual(first.0.baselines.runtime, frozenUnder)
            if editsAfter {
                XCTAssertEqual(settled.count, 1, "the explanation sends no newer edit")
                XCTAssertEqual(saved.health.checkInterval, original)
                XCTAssertTrue(session.ledger.isDirty(.configuration))
                XCTAssertTrue(session.ledger.filesNeedingReload.isEmpty, "the editor keeps its authority")
                session.save(.configuration)
                await session.settle()
                XCTAssertEqual(try ProxyConfigPersistence.load(in: harness.environment, allowMissing: false).health.checkInterval, original + 9)
            } else {
                XCTAssertEqual(settled.count, 2, "the refused draft went again once")
                guard case .configurationSettled(let receipt) = settled[1].1 else { return XCTFail("the resubmission settled: \(settled[1].1)") }
                XCTAssertTrue(receipt.runtime.write.isVerified && receipt.platform.write.isVerified)
                XCTAssertEqual(settled[1].0.version, first.0.version, "the same draft version")
                XCTAssertEqual(saved.health.checkInterval, original + 7)
            }
            XCTAssertFalse(saved.dnsForwarderEnabled, "the Stop's disable is kept")
            XCTAssertFalse(session.ledger.isDirty(.configuration))
            XCTAssertTrue(session.ledger.heldMismatches.isEmpty)
            observer.stop()
            self.observer = nil
            await harness.tearDown()
            self.harness = nil
        }
    }
}

/// A fixed-seed generator, so the model's walks are the same on every run.
private struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
