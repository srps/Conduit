// SPDX-License-Identifier: Apache-2.0
import Foundation
import ConduitShared
import PlatformMac
import XCTest
@testable import ConduitRuntime
@testable import ProxyKernel

/// The per-module lifecycle intent (decisions 0015, 0035 and 0036) and the runtime-only DNS lifecycle commit it persists through.
@MainActor
final class RuntimeModuleIntentTests: XCTestCase {
    private func request(
        proxy: RuntimeModuleAction = .none,
        dns: RuntimeModuleAction = .none,
        tunnels: RuntimeModuleAction = .none,
        expected: PrivateModuleSlots<Int?> = PrivateModuleSlots(proxy: nil, dns: nil, tunnels: nil)
    ) -> RuntimeLifecycleRequest {
        RuntimeLifecycleRequest(actions: PrivateModuleSlots(proxy: proxy, dns: dns, tunnels: tunnels), expectedRevisions: expected)
    }

    private func admitted(_ intents: inout RuntimeModuleIntents, _ request: RuntimeLifecycleRequest) throws -> RuntimeLifecycleTicket {
        try intents.admit(request).get()
    }

    // MARK: - Scenarios

    /// An explicit DNS Start after a DNS Stop stages the enable for its file while the fence and the permission stay in force until it is
    /// authorized. A Stop before the write revokes the staged target.
    func testAnExplicitDNSStartStagesTheEnableBeforeItsFenceClears() throws {
        var intents = RuntimeModuleIntents(dnsEnabled: true)
        intents.stop([.dns], reason: .session)
        XCTAssertFalse(intents.dnsConfigured, "the Stop's save projects the disable")
        let group = try admitted(&intents, request(dns: .start))
        XCTAssertTrue(intents.stagedDNSForwarderEnabled(for: group.group), "the pending explicit Start's own write stages the enable")
        XCTAssertFalse(intents.dnsConfigured, "which is not yet persisted intent")
        XCTAssertTrue(intents.modules.dns.fenced, "the fence protects runtime activation until the verified write")
        XCTAssertFalse(intents.modules.dns.enabled)
        XCTAssertEqual(intents.authorize(group), [.dns])
        XCTAssertFalse(intents.modules.dns.fenced)
        XCTAssertTrue(intents.modules.dns.enabled)

        var revoked = RuntimeModuleIntents(dnsEnabled: false)
        _ = try admitted(&revoked, request(dns: .start))
        revoked.stop([.dns], reason: .session)
        XCTAssertFalse(revoked.dnsConfigured, "a newer Stop revokes the pending target before an unstarted write")
    }

    /// A held Start and a failed Start leave the permission and the fence they found, so nothing can act on them later. This holds for an
    /// initially enabled DNS, for a DNS fenced by a Stop, and for a Start that replaced an authorized one still unsettled.
    func testHeldAndFailedExplicitStartsCreateNoPermission() throws {
        for (dnsEnabled, stopFirst) in [(true, false), (false, false), (true, true)] {
            var intents = RuntimeModuleIntents(dnsEnabled: dnsEnabled)
            if stopFirst { intents.stop([.dns], reason: .session) }
            let before = intents.modules.dns
            let held = try admitted(&intents, request(dns: .start))
            intents.retire(held)
            XCTAssertEqual(intents.modules.dns.enabled, before.enabled, "held: \(dnsEnabled) \(stopFirst)")
            XCTAssertEqual(intents.modules.dns.fenced, before.fenced, "held: \(dnsEnabled) \(stopFirst)")
            XCTAssertEqual(intents.modules.dns.pending, stopFirst ? .stopSave(revision: held.dnsIntentRevision) : nil,
                           "held: a disable save the Start displaced is owed again")

            let failed = try admitted(&intents, request(dns: .start))
            XCTAssertEqual(intents.authorize(failed), [.dns])
            let replacing = try admitted(&intents, request(dns: .start))
            intents.settle(.dns, ticket:failed, succeeded: false)
            XCTAssertNil(intents.modules.dns.authorized, "the replaced authorization is gone")
            XCTAssertEqual(intents.authorize(replacing), [.dns])
            intents.settle(.dns, ticket:replacing, succeeded: false)
            XCTAssertEqual(intents.modules.dns.enabled, before.enabled, "failed: the chain restores the pre-Start state")
            XCTAssertEqual(intents.modules.dns.fenced, before.fenced, "failed: \(dnsEnabled) \(stopFirst)")
            XCTAssertFalse(intents.conditionalActivationAllowed(replacing))
        }
    }

    /// An explicit DNS Start admitted over the disable save a session Stop still owes takes the obligation over, never ends it (decision
    /// 0015). Ended without its own verified write, it gives the save back keyed to the current DNS intent, so a reload adopts no stale enable,
    /// a facade still waits, and a later group's verified disable fulfils it. Its own verified enable is a newer saved fact that no retire
    /// undoes. A newer DNS Start carries the obligation on, and a facade Stop or a group-ending proxy Start leaves it owed.
    func testAnExplicitDNSStartKeepsTheDisableSaveItDisplacedUntilAWriteVerifies() throws {
        var held = RuntimeModuleIntents(dnsEnabled: true)
        held.stop([.dns], reason: .session)
        let start = try admitted(&held, request(dns: .start))
        XCTAssertEqual(held.modules.dns.pending, .start(RuntimeModuleStart(
            group: start.group, priorEnabled: false, priorFenced: true, displacesOwedSave: true
        )))
        held.retire(start)
        XCTAssertTrue(held.stopSaveIsCurrent(revision: start.dnsIntentRevision), "the displaced disable save is owed again")
        held.observeDurableDNS(true)
        XCTAssertFalse(held.dnsConfigured, "a reload adopts no stale enable while it is owed")
        XCTAssertEqual(held.admit(request(proxy: .start, dns: .configuredStart, tunnels: .start)), .failure(.busy(.dns)))
        let proxy = try captured(&held, admitted(&held, request(proxy: .start)))
        XCTAssertEqual(proxy.dnsStaged, false)
        held.recordVerifiedDNSWrite(false, for: proxy)
        XCTAssertNil(held.modules.dns.pending, "a later group's verified disable fulfils it")

        // A facade's configured Start may not displace it from the explicit Start that carries it either.
        var carried = RuntimeModuleIntents(dnsEnabled: true)
        carried.stop([.dns], reason: .session)
        let carrier = try admitted(&carried, request(dns: .start))
        let before = carried
        XCTAssertEqual(carried.admit(request(proxy: .start, dns: .configuredStart, tunnels: .start)), .failure(.busy(.dns)))
        XCTAssertEqual(carried, before, "the refusal changes nothing")
        // A verified disable staged by another group under the same DNS intent, while the carrier is still pending, is the owed disable.
        let beside = try captured(&carried, admitted(&carried, request(proxy: .start)))
        XCTAssertEqual(beside.dnsStaged, false)
        carried.recordVerifiedDNSWrite(false, for: beside)
        carried.retire(carrier)
        XCTAssertNil(carried.modules.dns.pending, "that write fulfilled it, so the retired carrier gives nothing back")

        var own = RuntimeModuleIntents(dnsEnabled: true)
        own.stop([.dns], reason: .session)
        let enable = try captured(&own, admitted(&own, request(dns: .start)))
        own.recordVerifiedDNSWrite(true, for: enable)
        own.retire(enable)
        XCTAssertNil(own.modules.dns.pending, "its own verified enable resolves the obligation, and the obsolete disable is not restored")
        XCTAssertTrue(own.dnsConfigured)

        // Its own enable verifying late, after a facade Stop or the Quit ended it and gave the save back, is still the newer fact.
        for reason in [RuntimeStopReason.facade, .processQuit] {
            var late = RuntimeModuleIntents(dnsEnabled: true)
            late.stop([.dns], reason: .session)
            let staged = try captured(&late, admitted(&late, request(dns: .start)))
            late.stop(Set(ControlModule.allCases), reason: reason)
            XCTAssertTrue(late.stopSaveIsCurrent(revision: staged.dnsIntentRevision), "\(reason): the Stop gave the save back")
            late.recordVerifiedDNSWrite(true, for: staged)
            XCTAssertNil(late.modules.dns.pending, "\(reason): its own late enable ends the obligation")
            XCTAssertTrue(late.dnsConfigured, "\(reason)")
        }
        // A newer session Stop still wins over that late enable.
        var overtaken = RuntimeModuleIntents(dnsEnabled: true)
        overtaken.stop([.dns], reason: .session)
        let staged = try captured(&overtaken, admitted(&overtaken, request(dns: .start)))
        let newer = overtaken.stop([.dns], reason: .session)
        overtaken.recordVerifiedDNSWrite(true, for: staged)
        XCTAssertTrue(overtaken.stopSaveIsCurrent(revision: newer))
        XCTAssertFalse(overtaken.dnsConfigured)

        let endings: [(String, (inout RuntimeModuleIntents, RuntimeLifecycleTicket) throws -> Int)] = [
            ("a newer DNS Start, retired", { intents, _ in
                let newer = try intents.admit(self.request(dns: .start)).get()
                intents.retire(newer)
                return newer.dnsIntentRevision
            }),
            ("a facade Stop", { intents, ticket in
                intents.stop(Set(ControlModule.allCases), reason: .facade)
                return ticket.dnsIntentRevision
            }),
            ("a proxy Start that ends the group", { intents, ticket in
                _ = try intents.admit(self.request(proxy: .start)).get()
                return ticket.dnsIntentRevision
            }),
        ]
        for (label, end) in endings {
            var intents = RuntimeModuleIntents(dnsEnabled: true)
            intents.stop([.dns], reason: .session)
            let grouped = try admitted(&intents, request(proxy: .start, dns: .start))
            let keyed = try end(&intents, grouped)
            XCTAssertTrue(intents.stopSaveIsCurrent(revision: keyed), "\(label): the disable save is still owed")
            XCTAssertFalse(intents.dnsConfigured, label)
        }
    }

    /// A companion activation projects DNS's existing intent and never enables it. Its failure, unlike an explicit Start's, changes nothing,
    /// so the prior enable stays for the next explicit request. A Stop of DNS cancels only the companion; the proxy Start stands.
    func testAConditionalActivationNeverEnablesAndADNSStopCancelsOnlyIt() throws {
        var disabled = RuntimeModuleIntents(dnsEnabled: false)
        let off = try admitted(&disabled, request(proxy: .start, dns: .conditionalActivation))
        XCTAssertFalse(disabled.dnsConfigured)
        XCTAssertFalse(disabled.conditionalActivationAllowed(off), "a disabled DNS is a typed no-op")
        XCTAssertEqual(disabled.authorize(off), [.proxy], "the companion is no explicit-enable member, though it shares the input")
        XCTAssertFalse(disabled.modules.dns.enabled)

        var enabled = RuntimeModuleIntents(dnsEnabled: true)
        let on = try admitted(&enabled, request(proxy: .start, dns: .conditionalActivation))
        XCTAssertEqual(enabled.authorize(on), [.proxy])
        XCTAssertTrue(enabled.conditionalActivationAllowed(on))
        enabled.settleConditional(on, succeeded: false)
        XCTAssertTrue(enabled.modules.dns.enabled, "a failed companion keeps the prior enable and fence")
        XCTAssertFalse(enabled.modules.dns.fenced)
        XCTAssertTrue(enabled.dnsConfigured, "and the configured intent")

        var retried = RuntimeModuleIntents(dnsEnabled: false)
        retried.observeDurableDNS(true)
        let explicit = try admitted(&retried, request(proxy: .start, dns: .conditionalActivation))
        XCTAssertEqual(retried.authorize(explicit), [.proxy])
        retried.settleConditional(explicit, succeeded: false)
        XCTAssertFalse(retried.modules.dns.enabled, "a failed companion grants no permission it did not have")
        let later = try admitted(&retried, request(proxy: .start, dns: .conditionalActivation))
        XCTAssertEqual(retried.authorize(later), [.proxy])
        retried.settleConditional(later, succeeded: true)
        XCTAssertTrue(retried.modules.dns.enabled, "a started companion keeps the runtime permission")
        XCTAssertFalse(retried.modules.dns.fenced)

        XCTAssertEqual(enabled.admit(request(dns: .conditionalActivation)), .failure(.invalid), "a companion needs a proxy Start")
        XCTAssertEqual(enabled.admit(request(proxy: .conditionalActivation)), .failure(.invalid))
    }

    /// A verified write's saved enable survives a held or failed Start (decision 0015): the fence and the permission return, the saved
    /// fact does not. A newer DNS Stop wins over a late write of the older enable.
    func testAVerifiedEnableSurvivesItsHeldStartAndLosesToANewerStop() throws {
        var held = RuntimeModuleIntents(dnsEnabled: false)
        held.stop([.dns], reason: .session)
        let group = try admitted(&held, request(dns: .start))
        held.recordVerifiedDNSWrite(held.stagedDNSForwarderEnabled(for: group.group), for:group)
        held.retire(group)
        XCTAssertTrue(held.dnsConfigured, "the next write keeps the enable the file verified")
        XCTAssertTrue(held.modules.dns.fenced, "the prior fence returns")
        XCTAssertFalse(held.modules.dns.enabled, "and no permission is left")

        var failed = RuntimeModuleIntents(dnsEnabled: false)
        let start = try admitted(&failed, request(dns: .start))
        failed.recordVerifiedDNSWrite(true, for:start)
        XCTAssertEqual(failed.authorize(start), [.dns])
        failed.settle(.dns, ticket:start, succeeded: false)
        XCTAssertTrue(failed.dnsConfigured)
        XCTAssertFalse(failed.modules.dns.enabled)

        var late = RuntimeModuleIntents(dnsEnabled: false)
        let staged = try admitted(&late, request(dns: .start))
        late.stop([.dns], reason: .session)
        late.recordVerifiedDNSWrite(true, for:staged)
        XCTAssertFalse(late.dnsConfigured, "the Stop's disable wins over the late older write")
    }

    /// Only a newer DNS intent overrides a verified write. A grouped DNS and tunnels Start whose write has begun is ended by an unrelated
    /// tunnels Stop or a newer tunnels Start; the late verified enable is still the saved fact. A newer DNS Stop or Start still wins.
    func testAVerifiedEnableSurvivesAnUnrelatedMemberEndingItsGroup() throws {
        let unrelated: [(String, (inout RuntimeModuleIntents) throws -> Void)] = [
            ("tunnels Stop", { $0.stop([.tunnels], reason: .session) }),
            ("tunnels Start", { _ = try $0.admit(self.request(tunnels: .start)).get() }),
            ("proxy Stop", { $0.stop([.proxy], reason: .session) }),
        ]
        for (label, end) in unrelated {
            var intents = RuntimeModuleIntents(dnsEnabled: false)
            let group = try captured(&intents, admitted(&intents, request(proxy: .start, dns: .start, tunnels: .start)))
            XCTAssertEqual(group.dnsStaged, true, label)
            try end(&intents)
            XCTAssertFalse(intents.isPending(group), "\(label) ends the whole group")
            intents.recordVerifiedDNSWrite(try XCTUnwrap(group.dnsStaged), for: group)
            intents.retire(group)
            XCTAssertTrue(intents.dnsConfigured, "\(label): no newer DNS intent, so the saved enable is kept")
            XCTAssertFalse(intents.modules.dns.enabled, "\(label): and it grants no permission")
            XCTAssertNil(intents.modules.dns.pending, label)
        }

        var stopped = RuntimeModuleIntents(dnsEnabled: false)
        let stale = try admitted(&stopped, request(dns: .start, tunnels: .start))
        stopped.stop([.tunnels], reason: .session)
        stopped.stop([.dns], reason: .session)
        stopped.recordVerifiedDNSWrite(true, for: stale)
        XCTAssertFalse(stopped.dnsConfigured, "a newer DNS Stop still wins after the group ended")

        var replaced = RuntimeModuleIntents(dnsEnabled: true)
        let older = try admitted(&replaced, request(proxy: .start, dns: .conditionalActivation))
        replaced.stop([.dns], reason: .session)
        let newer = try admitted(&replaced, request(dns: .start))
        replaced.retire(newer)
        replaced.recordVerifiedDNSWrite(true, for: older)
        XCTAssertFalse(replaced.dnsConfigured, "a late older write loses to the newer DNS Stop")
    }

    /// At the maximum counter a DNS Stop cannot take a newer value, and it still wins over the late write of the Start admitted at the
    /// maximum. A Quit there invents no disable and keeps a verified enable, late or not.
    func testAtTheMaximumADNSStopStillWinsOverALateWrite() throws {
        var stopped = RuntimeModuleIntents(counter: Int.max - 1, dnsEnabled: false)
        let start = try admitted(&stopped, request(dns: .start))
        XCTAssertEqual(start.group, Int.max)
        XCTAssertEqual(stopped.stop([.dns], reason: .session), Int.max)
        stopped.recordVerifiedDNSWrite(true, for: start)
        XCTAssertFalse(stopped.dnsConfigured, "the Stop at the maximum wins over the late enable")

        var quit = RuntimeModuleIntents(counter: Int.max - 1, dnsEnabled: false)
        let late = try admitted(&quit, request(dns: .start))
        quit.stop(Set(ControlModule.allCases), reason: .processQuit)
        XCTAssertFalse(quit.dnsConfigured, "Quit ended the Start and invents no enable")
        quit.recordVerifiedDNSWrite(true, for: late)
        XCTAssertTrue(quit.dnsConfigured, "Quit is no DNS intent, so the late verified enable is kept")
        quit.stop(Set(ControlModule.allCases), reason: .processQuit)
        XCTAssertTrue(quit.dnsConfigured, "and a second Quit at the maximum invents no disable")
    }

    /// A newer Start replacing an authorized, unsettled one owns the module at once. The old Start's late completion, successful or failed,
    /// leaves the newer record alone, and the newer Start's failure or hold restores the prior the chain began from.
    func testALateCompletionOfAReplacedStartLeavesTheNewerOneAlone() throws {
        for (stopFirst, oldSucceeded, newer) in [(false, true, "fail"), (true, false, "fail"), (true, true, "hold"), (false, false, "hold")] {
            let label = "stopFirst=\(stopFirst) oldSucceeded=\(oldSucceeded) newer=\(newer)"
            var intents = RuntimeModuleIntents(dnsEnabled: false)
            if stopFirst { intents.stop([.proxy], reason: .session) }
            let original = intents.modules.proxy
            let old = try admitted(&intents, request(proxy: .start))
            XCTAssertEqual(intents.authorize(old), [.proxy], label)
            let replacing = try admitted(&intents, request(proxy: .start))
            let afterAdmission = intents
            intents.settle(.proxy, ticket: old, succeeded: oldSucceeded)
            XCTAssertEqual(intents, afterAdmission, "\(label): the old completion changes nothing")
            XCTAssertFalse(intents.modules.proxy.enabled, "\(label): the replaced, unproven start keeps no permission")
            XCTAssertTrue(intents.isPending(replacing), label)
            if newer == "fail" {
                XCTAssertEqual(intents.authorize(replacing), [.proxy], label)
                intents.settle(.proxy, ticket: replacing, succeeded: false)
            } else {
                intents.retire(replacing)
            }
            XCTAssertEqual(intents.modules.proxy.enabled, original.enabled, "\(label): the original prior returns")
            XCTAssertEqual(intents.modules.proxy.fenced, original.fenced, label)
            XCTAssertNil(intents.modules.proxy.authorized, label)
        }
    }

    /// A companion changes no DNS control (decision 0036): admitted after a DNS Stop, it keeps the Stop's reserved disable save and DNS's
    /// revision; admitted beside a pending explicit DNS Start, it does not cancel that Start.
    func testACompanionKeepsDNSControlAndItsSave() throws {
        var stopped = RuntimeModuleIntents(dnsEnabled: true)
        let save = stopped.stop([.dns], reason: .session)
        let revision = stopped.modules.dns.revision
        let observed = PrivateModuleSlots<Int?>(proxy: stopped.modules.proxy.revision, dns: revision, tunnels: nil)
        _ = try stopped.admit(request(proxy: .start, dns: .conditionalActivation, expected: observed)).get()
        XCTAssertTrue(stopped.stopSaveIsCurrent(revision: save), "the companion keeps the Stop's disable save")
        XCTAssertEqual(stopped.modules.dns.revision, revision, "the companion does not advance DNS's revision")
        XCTAssertTrue(stopped.modules.dns.fenced)

        var starting = RuntimeModuleIntents(dnsEnabled: false)
        _ = try starting.admit(request(dns: .start)).get()
        let pending = starting.modules.dns.pending
        _ = try starting.admit(request(proxy: .start, dns: .conditionalActivation)).get()
        XCTAssertEqual(starting.modules.dns.pending, pending, "the companion does not cancel the explicit DNS Start")
    }

    /// One stale actionable slot rejects the whole request, and the rejection changes nothing.
    func testAStaleSlotRejectsTheWholeRequestUnchanged() throws {
        var intents = RuntimeModuleIntents(dnsEnabled: true)
        let observed = PrivateModuleSlots<Int?>(proxy: intents.modules.proxy.revision, dns: intents.modules.dns.revision, tunnels: nil)
        intents.stop([.dns], reason: .session)
        let before = intents
        XCTAssertEqual(intents.admit(request(proxy: .start, dns: .start, expected: observed)), .failure(.stale(.dns)))
        XCTAssertEqual(intents, before)
    }

    /// Superseding one member ends the whole pending group, and only the group's own records: a newer pending operation stays.
    func testSupersedingOneMemberEndsTheWholeGroupOnly() throws {
        var intents = RuntimeModuleIntents(dnsEnabled: true)
        let group = try admitted(&intents, request(proxy: .start, tunnels: .start))
        let newer = try admitted(&intents, request(dns: .start))
        intents.stop([.tunnels], reason: .session)
        XCTAssertFalse(intents.isPending(group))
        XCTAssertNil(intents.modules.proxy.pending, "the proxy member ended with the group")
        XCTAssertTrue(intents.isPending(newer), "the newer DNS Start is not the old group's")
        XCTAssertEqual(intents.modules.proxy.revision, intents.counter, "an ended member takes the superseding revision")
    }

    /// The companion depends on the group's shared input (decision 0035). A DNS Stop, or a newer DNS Start, before that input is adopted
    /// ends the whole group and leaves the newer DNS operation in place. After the group is authorized, a DNS Stop cancels only the companion.
    func testTheCompanionEndsItsGroupBeforeTheSharedInputAndOnlyItselfAfter() throws {
        var stoppedEarly = RuntimeModuleIntents(dnsEnabled: true)
        let early = try admitted(&stoppedEarly, request(proxy: .start, dns: .conditionalActivation))
        stoppedEarly.stop([.dns], reason: .session)
        XCTAssertFalse(stoppedEarly.isPending(early), "a DNS Stop before the shared input ends the whole group")
        XCTAssertEqual(stoppedEarly.authorize(early), [], "a stale group is never authorized")
        stoppedEarly.retire(early)
        XCTAssertNil(stoppedEarly.modules.proxy.pending)
        XCTAssertNotNil(stoppedEarly.modules.dns.pending, "the Stop's own save stays")

        var replaced = RuntimeModuleIntents(dnsEnabled: true)
        let old = try admitted(&replaced, request(proxy: .start, dns: .conditionalActivation))
        let newer = try admitted(&replaced, request(dns: .start))
        XCTAssertFalse(replaced.isPending(old), "a newer DNS Start before the shared input ends the old group")
        XCTAssertTrue(replaced.isPending(newer), "and keeps its own reference")

        var stoppedLate = RuntimeModuleIntents(dnsEnabled: true)
        let late = try admitted(&stoppedLate, request(proxy: .start, dns: .conditionalActivation))
        XCTAssertEqual(stoppedLate.authorize(late), [.proxy])
        stoppedLate.stop([.dns], reason: .session)
        XCTAssertFalse(stoppedLate.conditionalActivationAllowed(late), "after the shared input, a DNS Stop cancels the companion")
        XCTAssertEqual(stoppedLate.modules.proxy.authorized?.group, late.group, "and leaves the started proxy alone")
    }

    /// Another request's pending DNS enable is not yet persisted intent (decisions 0015, 0035 and 0036). A proxy request admitted beside a
    /// pending explicit DNS Start stages the durable false, not that Start's unverified true; once the DNS Start is held and retired, the
    /// proxy request's verified write records the false and its own companion finds nothing to activate.
    func testAProxyRequestNeverStagesAnotherRequestsPendingDNSEnable() throws {
        var intents = RuntimeModuleIntents(dnsEnabled: false)
        let dnsStart = try admitted(&intents, request(dns: .start))
        let proxy = try captured(&intents, admitted(&intents, request(proxy: .start, dns: .conditionalActivation)))
        XCTAssertEqual(proxy.dnsStaged, false, "the proxy request stages the durable value")
        XCTAssertTrue(intents.stagedDNSForwarderEnabled(for: dnsStart.group), "while the DNS Start's own write would stage its enable")
        XCTAssertTrue(intents.isPending(proxy))
        intents.recordVerifiedDNSWrite(try XCTUnwrap(proxy.dnsStaged), for: proxy)
        intents.retire(dnsStart)
        XCTAssertEqual(intents.authorize(proxy), [.proxy])
        XCTAssertFalse(intents.conditionalActivationAllowed(proxy), "no companion acts on the held Start's enable")
        XCTAssertFalse(intents.dnsConfigured, "and the held Start left no persisted enable")
        XCTAssertFalse(intents.stagedDNSForwarderEnabled(for: 0))
    }

    /// Pins the behavior the request-scoped staging chose: a DNS Start admitted after a group without a companion captured does not hold
    /// that group, whose write stages the unchanged durable value (decision 0035: the merged persisted value did not change). A group with
    /// a companion is still held through its DNS revision.
    func testALaterDNSStartLeavesACapturedGroupWithoutACompanionStanding() throws {
        var intents = RuntimeModuleIntents(dnsEnabled: false)
        let proxy = try captured(&intents, admitted(&intents, request(proxy: .start)))
        let dnsStart = try admitted(&intents, request(dns: .start))
        XCTAssertTrue(intents.isPending(proxy), "the proxy group's staged false still stands")
        XCTAssertTrue(intents.isPending(dnsStart))
        XCTAssertEqual(intents.authorize(proxy), [.proxy])

        var withCompanion = RuntimeModuleIntents(dnsEnabled: false)
        let companion = try captured(&withCompanion, admitted(&withCompanion, request(proxy: .start, dns: .conditionalActivation)))
        _ = try admitted(&withCompanion, request(dns: .start))
        XCTAssertFalse(withCompanion.isPending(companion), "a newer DNS admission still ends a group with a companion")
    }

    /// A reload that observes DNS configured on is not itself a permission, but a later explicit proxy Start with its companion may start
    /// DNS once the group's shared input is adopted. A fenced DNS keeps its disable through the same reload.
    func testAConfiguredDNSActivatesOnlyThroughALaterExplicitCompanion() throws {
        var intents = RuntimeModuleIntents(dnsEnabled: false)
        intents.observeDurableDNS(true)
        XCTAssertFalse(intents.modules.dns.enabled, "the observation alone grants no runtime permission")
        let group = try admitted(&intents, request(proxy: .start, dns: .conditionalActivation))
        XCTAssertFalse(intents.conditionalActivationAllowed(group), "not before the shared input is adopted")
        XCTAssertEqual(intents.authorize(group), [.proxy])
        XCTAssertTrue(intents.conditionalActivationAllowed(group), "the explicit companion may activate the configured DNS")
        XCTAssertFalse(intents.modules.dns.fenced)

        var fenced = RuntimeModuleIntents(dnsEnabled: true)
        fenced.stop([.dns], reason: .session)
        fenced.observeDurableDNS(true)
        let blocked = try admitted(&fenced, request(proxy: .start, dns: .conditionalActivation))
        XCTAssertEqual(fenced.authorize(blocked), [.proxy])
        XCTAssertFalse(fenced.conditionalActivationAllowed(blocked), "a Stop's fence keeps DNS off through a reload")
    }

    /// A terminal stop latches and persists no disable, but keeps a DNS save an earlier session Stop reserved.
    func testATerminalStopKeepsAnEarlierStopSaveAndPersistsNoDisable() throws {
        var intents = RuntimeModuleIntents(dnsEnabled: true)
        let saved = intents.stop([.dns], reason: .session)
        intents.stop(Set(ControlModule.allCases), reason: .processQuit)
        XCTAssertTrue(intents.stopSaveIsCurrent(revision: saved))
        XCTAssertEqual(intents.admit(request(proxy: .start)), .failure(.terminated))

        var quit = RuntimeModuleIntents(dnsEnabled: true)
        quit.stop(Set(ControlModule.allCases), reason: .processQuit)
        XCTAssertNil(quit.modules.dns.pending, "Quit reserves no disable save")
        XCTAssertTrue(quit.dnsConfigured, "Quit leaves the durable enable")
    }

    /// After Quit has latched, a late session DNS Stop still fences, but it neither creates a disable save nor drops one an earlier Stop owes
    /// (decision 0015): Quit carries only obligations that predate it.
    func testALateDNSStopAfterQuitCreatesAndDropsNoSave() {
        var quit = RuntimeModuleIntents(dnsEnabled: true)
        quit.stop(Set(ControlModule.allCases), reason: .processQuit)
        quit.stop([.dns], reason: .session)
        XCTAssertNil(quit.modules.dns.pending, "no new disable save after Quit")
        XCTAssertTrue(quit.dnsConfigured, "the configured enable stays")
        XCTAssertTrue(quit.modules.dns.fenced)

        var owed = RuntimeModuleIntents(dnsEnabled: true)
        let saved = owed.stop([.dns], reason: .session)
        owed.stop(Set(ControlModule.allCases), reason: .processQuit)
        owed.stop([.dns], reason: .session)
        XCTAssertTrue(owed.stopSaveIsCurrent(revision: saved), "the save owed before Quit is kept")
        XCTAssertFalse(owed.dnsConfigured, "and still stages its disable")
        XCTAssertTrue(owed.modules.dns.fenced)
    }

    private func facade(_ intents: inout RuntimeModuleIntents) throws -> RuntimeLifecycleTicket {
        try admitted(&intents, request(proxy: .start, dns: .configuredStart, tunnels: .start))
    }

    /// The preparation's capture, observing `observedDNS` or, by default, the configured value the store adopted.
    private func captured(
        _ intents: inout RuntimeModuleIntents,
        _ ticket: RuntimeLifecycleTicket,
        observedDNS: Bool? = nil
    ) throws -> RuntimeLifecycleTicket {
        let observed = observedDNS ?? intents.dnsConfigured
        return try XCTUnwrap(intents.capture(ticket, observedDNS: observed), "the group still stands at its capture")
    }

    /// The legacy facade (decision 0036 keeps it): a whole Stop fences every module and persists no disable; the next facade Start clears
    /// every fence only once authorized, and grants DNS exactly its configured intent without staging an enable.
    func testTheFacadeStopThenStartKeepsTheConfiguredDNSIntent() throws {
        for configured in [false, true] {
            var intents = RuntimeModuleIntents(dnsEnabled: configured)
            intents.stop(Set(ControlModule.allCases), reason: .facade)
            XCTAssertTrue(intents.allFenced)
            XCTAssertNil(intents.modules.dns.pending, "\(configured): a facade Stop reserves no disable save")
            XCTAssertEqual(intents.dnsConfigured, configured, "and keeps the configured intent")

            let queued = try facade(&intents)
            XCTAssertNil(queued.dnsStaged, "a queued facade carries no configuration value")
            let start = try captured(&intents, queued)
            XCTAssertEqual(start.dnsStaged, configured, "\(configured): the facade stages the configured value, never a forced enable")
            XCTAssertTrue(intents.allFenced, "the fences hold until the verified pair is adopted")
            XCTAssertEqual(intents.authorize(start), [.proxy, .dns, .tunnels])
            XCTAssertFalse(intents.modules.dns.fenced, "\(configured): the facade clears DNS's fence")
            XCTAssertEqual(intents.modules.dns.enabled, configured, "\(configured): and grants exactly the configured intent")
            XCTAssertTrue(intents.modules.proxy.enabled)
            XCTAssertTrue(intents.holdsGroup(start))
        }
        var invalid = RuntimeModuleIntents(dnsEnabled: true)
        XCTAssertEqual(invalid.admit(request(proxy: .configuredStart)), .failure(.invalid), "only DNS has a configured Start")
    }

    /// A facade Stop keeps a disable save an earlier session DNS Stop owes. A facade Start while that save is owed is refused whole and
    /// changes nothing; a companion still keeps the save. Once the save settles, a fresh facade Start clears every fence and grants DNS its
    /// configured false.
    func testAFacadeStartWaitsForAnOwedDNSStopSave() throws {
        var intents = RuntimeModuleIntents(dnsEnabled: true)
        let saved = intents.stop([.dns], reason: .session)
        intents.stop(Set(ControlModule.allCases), reason: .facade)
        XCTAssertTrue(intents.stopSaveIsCurrent(revision: saved), "the facade Stop keeps the owed save")
        let before = intents
        XCTAssertEqual(intents.admit(request(proxy: .start, dns: .configuredStart, tunnels: .start)), .failure(.busy(.dns)))
        XCTAssertEqual(intents, before, "the busy refusal changes no record and no counter")
        _ = try admitted(&intents, request(proxy: .start, dns: .conditionalActivation))
        XCTAssertTrue(intents.stopSaveIsCurrent(revision: saved), "a companion has no DNS slot and keeps the save")

        intents.finishStopSave(revision: saved)
        let start = try captured(&intents, facade(&intents))
        XCTAssertEqual(start.dnsStaged, false, "the facade stages the saved disable")
        XCTAssertEqual(intents.authorize(start), [.proxy, .dns, .tunnels])
        XCTAssertFalse(intents.modules.dns.fenced, "the facade clears DNS's fence")
        XCTAssertFalse(intents.modules.dns.enabled, "and grants its configured false")
    }

    /// The facade's configured Start is no DNS configuration intent: a late verified fact of an older group still lands. Before the facade's
    /// capture the fact is what it captures; after it, the facade is held rather than re-staged (decisions 0035 and 0037).
    func testTheFacadeDoesNotSuppressALateSavedFact() throws {
        var queued = RuntimeModuleIntents(dnsEnabled: false)
        let earlier = try admitted(&queued, request(dns: .start))
        let waiting = try facade(&queued)
        XCTAssertFalse(queued.isPending(earlier), "the facade replaced the explicit Start's pending slot")
        queued.recordVerifiedDNSWrite(true, for: earlier)
        XCTAssertTrue(queued.isPending(waiting), "a queued facade bound no value, so the fact does not end it")
        XCTAssertEqual(try captured(&queued, waiting).dnsStaged, true, "its capture uses the saved fact")

        var intents = RuntimeModuleIntents(dnsEnabled: false)
        let explicit = try admitted(&intents, request(dns: .start))
        let start = try captured(&intents, facade(&intents))
        intents.recordVerifiedDNSWrite(true, for: explicit)
        XCTAssertTrue(intents.dnsConfigured, "the explicit Start's verified enable is the saved fact")
        XCTAssertFalse(intents.isPending(start), "the facade captured false, so it is held, not re-staged")
        intents.retire(start)
        XCTAssertTrue(intents.allFenced == false && !intents.modules.dns.enabled, "the held facade grants nothing")
    }

    /// A reload's newer observation before the capture is the value the facade captures; one after it holds the facade, which is never
    /// rebound (decision 0037). An explicit DNS Start keeps its own enable whatever the observation says.
    func testAFacadeCapturesTheObservationAtPreparationNotAdmission() throws {
        var before = RuntimeModuleIntents(dnsEnabled: false)
        let queued = try facade(&before)
        before.observeDurableDNS(true)
        XCTAssertTrue(before.isPending(queued), "an observation before the capture does not end a queued facade")
        let start = try captured(&before, queued, observedDNS: true)
        XCTAssertEqual(start.dnsStaged, true, "the capture uses the newer observation")
        XCTAssertEqual(before.authorize(start), [.proxy, .dns, .tunnels])
        XCTAssertTrue(before.modules.dns.enabled, "and grants the configured value it captured")

        var after = RuntimeModuleIntents(dnsEnabled: false)
        let bound = try captured(&after, facade(&after))
        after.observeDurableDNS(true)
        XCTAssertTrue(after.dnsConfigured, "the newer observation is still adopted as the fact")
        XCTAssertFalse(after.isPending(bound), "and it holds the captured facade")
        XCTAssertEqual(after.authorize(bound), [], "which is never authorized on the replaced input")
        XCTAssertFalse(after.holdsGroup(bound))

        var explicit = RuntimeModuleIntents(dnsEnabled: false)
        let enable = try captured(&explicit, admitted(&explicit, request(dns: .start)), observedDNS: false)
        XCTAssertEqual(enable.dnsStaged, true, "an explicit DNS Start stages its enable over the observed false")
        explicit.observeDurableDNS(false)
        XCTAssertTrue(explicit.isPending(enable), "and its pending intent keeps the observation from changing what it staged")
    }

    /// A fence governs runtime permission, not whether a verified file observation is a fact. With no pending Start, authorized Start or
    /// owed save, a reload adopts the configured bit and the fence and permission stay; an owed disable save keeps its own intent until it
    /// verifies. A later facade Start after the verified pair grants the configured value.
    func testAFencedReloadAdoptsTheFactButKeepsTheStop() throws {
        var facadeStopped = RuntimeModuleIntents(dnsEnabled: false)
        facadeStopped.stop(Set(ControlModule.allCases), reason: .facade)
        facadeStopped.observeDurableDNS(true)
        XCTAssertTrue(facadeStopped.dnsConfigured, "the facade-stopped DNS adopts the verified observation")
        XCTAssertTrue(facadeStopped.modules.dns.fenced, "and keeps its fence")
        XCTAssertFalse(facadeStopped.modules.dns.enabled, "and gains no permission")
        let start = try captured(&facadeStopped, facade(&facadeStopped))
        XCTAssertEqual(start.dnsStaged, true, "the facade stages the adopted value, not the old one")
        XCTAssertEqual(facadeStopped.authorize(start), [.proxy, .dns, .tunnels])
        XCTAssertFalse(facadeStopped.modules.dns.fenced)
        XCTAssertTrue(facadeStopped.modules.dns.enabled, "a fresh facade Start grants the configured true")

        var owed = RuntimeModuleIntents(dnsEnabled: true)
        let saved = owed.stop([.dns], reason: .session)
        owed.observeDurableDNS(true)
        XCTAssertFalse(owed.dnsConfigured, "an owed disable save keeps its false")
        XCTAssertTrue(owed.stopSaveIsCurrent(revision: saved))

        owed.finishStopSave(revision: saved)
        owed.observeDurableDNS(true)
        XCTAssertTrue(owed.dnsConfigured, "after the save verified, a later edit and reload is a new fact")
        XCTAssertTrue(owed.modules.dns.fenced, "while DNS stays fenced")
        XCTAssertFalse(owed.modules.dns.enabled, "and off")
    }

    /// A reload's observed bit can lower DNS's permission and never raise it.
    func testAReloadObservationNeverRaisesPermission() {
        var intents = RuntimeModuleIntents(dnsEnabled: false)
        intents.observeDurableDNS(true)
        XCTAssertTrue(intents.dnsConfigured, "the durable observation is merged into later writes")
        XCTAssertFalse(intents.modules.dns.enabled, "but it is not an activation permission")
        intents.observeDurableDNS(false)
        XCTAssertFalse(intents.dnsConfigured)

        var fenced = RuntimeModuleIntents(dnsEnabled: true)
        fenced.stop([.dns], reason: .session)
        fenced.observeDurableDNS(true)
        XCTAssertFalse(fenced.dnsConfigured, "a fenced DNS keeps the disable its Stop set")
    }

    /// At the maximum a Start is refused unchanged, and a Stop fences without advancing.
    func testTheMaximumCounterRefusesStartsAndStillFences() {
        var intents = RuntimeModuleIntents(counter: Int.max, dnsEnabled: true)
        let before = intents
        XCTAssertEqual(intents.admit(request(proxy: .start)), .failure(.exhausted))
        XCTAssertEqual(intents, before)
        XCTAssertEqual(intents.stop([.dns], reason: .session), Int.max)
        XCTAssertTrue(intents.modules.dns.fenced)
    }

    // MARK: - Bounded exploration

    private enum Step: CaseIterable {
        case startProxy, startDNS, facade, staleStart, stopProxy, stopDNS, quit
        case authorize, retire, fail, succeed, observeOn, observeOff
    }

    /// A bounded property sweep, not an independent reference model: it drives the production value and reads its own members, priors and
    /// group helpers, then checks properties stated from the decisions. Every sequence of up to four steps from both DNS starting values:
    /// within this alphabet only an authorization raises a permission or clears a fence; a companion's admission changes no DNS control; a
    /// held or failed Start restores the prior its chain began from; a refusal changes nothing; the counter never goes back; a pending explicit DNS
    /// Start stages the enable; an owed disable save is dropped by no step but the authorization of the Start that carries it. The alphabet has no companion settlement: its one runtime grant, never a fence or configured change, is
    /// covered by `testAConditionalActivationNeverEnablesAndADNSStopCancelsOnlyIt`. The independent workflow reference adapter is still due
    /// with the workflow integration.
    func testEveryBoundedSequenceKeepsTheIntentInvariants() {
        let depth = 4
        var sequences: [[Step]] = [[]]
        var frontier: [[Step]] = [[]]
        for _ in 0..<depth {
            frontier = frontier.flatMap { prefix in Step.allCases.map { prefix + [$0] } }
            sequences += frontier
        }
        XCTAssertEqual(sequences.count, 30_941, "1 + 13 + 13^2 + 13^3 + 13^4 sequences")
        var coverage: [String: Int] = [:]
        for dnsEnabled in [false, true] {
            for sequence in sequences {
                if let problem = check(sequence, dnsEnabled: dnsEnabled, coverage: &coverage) {
                    return XCTFail("dnsEnabled=\(dnsEnabled) \(sequence): \(problem)")
                }
            }
        }
        for key in ["authorize.clearedFence", "retire.restored", "fail.restored", "refusal.unchanged", "stale.refused",
                    "terminal.refused", "group.endedByMember", "observe.lowered", "projection.pendingTarget",
                    "quit.lateStopPersistedNothing", "owedSave.givenBack"] {
            XCTAssertGreaterThan(coverage[key] ?? 0, 0, "never reached \(key)")
        }
    }

    private func check(_ sequence: [Step], dnsEnabled: Bool, coverage: inout [String: Int]) -> String? {
        var intents = RuntimeModuleIntents(dnsEnabled: dnsEnabled)
        var latest: RuntimeLifecycleTicket?
        var admittedFrom: [Int: RuntimeModuleIntents] = [:]
        for step in sequence {
            let before = intents
            switch step {
            case .startProxy, .startDNS, .facade, .staleStart:
                let asked: RuntimeLifecycleRequest = switch step {
                case .startProxy: request(proxy: .start)
                case .startDNS: request(dns: .start)
                case .facade: request(proxy: .start, dns: .conditionalActivation, tunnels: .start)
                default: request(proxy: .start, expected: PrivateModuleSlots(proxy: intents.modules.proxy.revision - 1, dns: nil, tunnels: nil))
                }
                switch intents.admit(asked) {
                case .success(let ticket):
                    latest = ticket
                    admittedFrom[ticket.group] = before
                case .failure(let refusal):
                    if intents != before { return "a refusal changed the intent" }
                    coverage["refusal.unchanged", default: 0] += 1
                    if case .stale = refusal { coverage["stale.refused", default: 0] += 1 }
                    if refusal == .terminated { coverage["terminal.refused", default: 0] += 1 }
                }
            case .stopProxy:
                let pendingTunnels = intents.modules.tunnels.pending
                intents.stop([.proxy], reason: .session)
                if pendingTunnels != nil, intents.modules.tunnels.pending == nil {
                    coverage["group.endedByMember", default: 0] += 1
                }
            case .stopDNS:
                intents.stop([.dns], reason: .session)
                if before.terminal {
                    // After Quit a late Stop persists nothing: no new save, no owed save dropped, no configured change. Quit already
                    // ended any pending Start, so the slot holds at most the save owed from before it.
                    if intents.modules.dns.pending != before.modules.dns.pending { return "a DNS Stop after Quit changed the owed save" }
                    if intents.dnsConfigured != before.dnsConfigured {
                        return "a DNS Stop after Quit changed the configured intent"
                    }
                    coverage["quit.lateStopPersistedNothing", default: 0] += 1
                } else if intents.dnsConfigured {
                    return "a session DNS Stop left the enable staged"
                }
            case .quit:
                intents.stop(Set(ControlModule.allCases), reason: .processQuit)
            case .authorize:
                guard let group = latest else { continue }
                if !intents.authorize(group).isEmpty {
                    if before.modules.proxy.fenced && !intents.modules.proxy.fenced
                        || before.modules.dns.fenced && !intents.modules.dns.fenced {
                        coverage["authorize.clearedFence", default: 0] += 1
                    }
                }
            case .retire:
                guard let group = latest, let origin = admittedFrom[group.group] else { continue }
                let members = intents.members(of: group.group)
                intents.retire(group)
                for module in members {
                    // A Start that replaced an unsettled authorized one restores that chain's prior; any other, what its admission found.
                    let found = origin.modules[module].authorized.map { ($0.priorEnabled, $0.priorFenced) }
                        ?? (origin.modules[module].enabled, origin.modules[module].fenced)
                    if intents.modules[module].enabled != found.0 || intents.modules[module].fenced != found.1 {
                        return "a held Start left \(module) different from its prior"
                    }
                    coverage["retire.restored", default: 0] += 1
                }
            case .fail, .succeed:
                guard let group = latest else { continue }
                for module in ControlModule.allCases where intents.modules[module].authorized?.group == group.group {
                    let prior = intents.modules[module].authorized!
                    intents.settle(module, ticket: group, succeeded: step == .succeed)
                    if step == .fail {
                        if intents.modules[module].enabled != prior.priorEnabled || intents.modules[module].fenced != prior.priorFenced {
                            return "a failed Start left \(module) different from its prior"
                        }
                        coverage["fail.restored", default: 0] += 1
                    }
                }
            case .observeOn, .observeOff:
                intents.observeDurableDNS(step == .observeOn)
                if before.modules.dns.enabled && !intents.modules.dns.enabled { coverage["observe.lowered", default: 0] += 1 }
            }
            if intents.counter < before.counter { return "the counter went back" }
            if step == .facade, intents.modules.dns != before.modules.dns { return "a companion changed DNS's control" }
            for module in ControlModule.allCases {
                let raised = !before.modules[module].enabled && intents.modules[module].enabled
                let cleared = before.modules[module].fenced && !intents.modules[module].fenced
                if (raised || cleared) && step != .authorize { return "\(step) raised \(module)'s permission or cleared its fence" }
                if case .stopSave = intents.modules[module].pending, module != .dns { return "a save on \(module)" }
            }
            // An owed disable save leaves DNS's slot only with the authorization of the Start that carries it, which follows that Start's
            // own verified write (decision 0015). A held Start gives it back.
            if owesStopSave(before), !owesStopSave(intents), step != .authorize {
                return "\(step) dropped the disable save a session Stop owed"
            }
            if step == .retire, case .start(let start) = before.modules.dns.pending, start.displacesOwedSave,
               case .stopSave = intents.modules.dns.pending {
                coverage["owedSave.givenBack", default: 0] += 1
            }
            if case .start(let pending) = intents.modules.dns.pending, !pending.configured {
                if !intents.stagedDNSForwarderEnabled(for: pending.group) { return "a pending explicit DNS Start staged no enable" }
                // No other request's write stages that unverified enable.
                if intents.stagedDNSForwarderEnabled(for: pending.group &+ 1) != intents.dnsConfigured {
                    return "another group staged a pending DNS Start's enable"
                }
                coverage["projection.pendingTarget", default: 0] += 1
            } else if intents.modules.dns.authorized == nil, case .stopSave = intents.modules.dns.pending,
                      intents.dnsConfigured {
                return "a reserved Stop save stages the enable"
            }
        }
        return nil
    }

    /// Whether DNS's slot owes a session Stop's disable save: the save itself, or a Start that displaced it unresolved.
    private func owesStopSave(_ intents: RuntimeModuleIntents) -> Bool {
        switch intents.modules.dns.pending {
        case .stopSave: true
        case .start(let start): start.displacesOwedSave
        case nil: false
        }
    }

    // MARK: - The runtime-only DNS lifecycle commit

    private static let context = ConfigurationOperationContext(
        requestID: ControlRequestID(rawValue: UUID()),
        hostIncarnation: ControlHostIncarnation(rawValue: UUID()),
        expectedOwnerGeneration: PrivateConfigExpectedGeneration(rawValue: 1)!
    )

    nonisolated private func enabledRuntime() throws -> Data {
        var config = GenericDefaults.shared.makeConfig()
        config.dnsForwarderEnabled = true
        return try ProxyConfigPersistence.stagedFileData(for: config)
    }

    nonisolated private func platformBytes() throws -> Data {
        try PlatformConfigPersistence.stagedData(for: PlatformIntegrationConfig())
    }

    private struct LoadNotAdopted: Error {}

    @RuntimeActor private func load(_ fixture: ConfigurationStoreTests.Fixture) async throws {
        guard case .admitted(let report) = await fixture.store.load(context: Self.context), case .adopted = report.outcome else {
            XCTFail("the fixture's load was not adopted")
            throw LoadNotAdopted()
        }
    }

    @RuntimeActor private func disable(_ fixture: ConfigurationStoreTests.Fixture, current: Bool = true) async -> ConfigurationWriteOutcome? {
        guard case .admitted(let result) = await fixture.store.commitDNSLifecycle(
            enabled: false,
            expecting: fixture.store.baselineToken(for: .runtime),
            context: Self.context,
            claim: ConfigurationWriteClaim { current }
        ) else { return nil }
        return result.runtime
    }

    @RuntimeActor private func writes(_ fixture: ConfigurationStoreTests.Fixture, at path: String) -> Int {
        fixture.access.observations.filter { if case .write(let written, _) = $0 { written == path } else { false } }.count
    }

    /// The disable writes the runtime file alone. An external platform edit neither holds it nor is written over, and the commit gives no
    /// verified pair, so the ordinary coupled apply stays held on the changed platform file.
    @RuntimeActor func testTheDNSDisableWritesOnlyTheRuntimeFileAndAuthorizesNoApply() async throws {
        let fixture = try ConfigurationStoreTests.Fixture(runtime: try enabledRuntime(), platform: try platformBytes())
        defer { fixture.close() }
        try await load(fixture)
        let external = Data("{\"externally\":\"edited\"}".utf8)
        fixture.access.externalEdit(.replace(external), at: fixture.plan.platformConfig.path)

        let disabled = await disable(fixture)
        let outcome = try XCTUnwrap(disabled)
        guard case .persisted = outcome else { return XCTFail("the disable persists, got \(outcome)") }
        XCTAssertEqual(writes(fixture, at: fixture.plan.platformConfig.path), 0, "the platform file is never written")
        XCTAssertEqual(fixture.access.storedBytes(at: fixture.plan.platformConfig.path), external)
        XCTAssertEqual(fixture.store.values?.runtime.dnsForwarderEnabled, false)

        let values = try XCTUnwrap(fixture.store.values)
        guard case .admitted(let coupled) = await fixture.store.commitRuntimeAndPlatform(
            values.runtime, values.platform,
            expecting: ConfigurationSlots(
                runtime: fixture.store.baselineToken(for: .runtime), platform: fixture.store.baselineToken(for: .platform), preferences: nil
            ),
            context: Self.context
        ) else { return XCTFail("the coupled commit was not admitted") }
        XCTAssertNil(coupled.verifiedInput, "the changed platform file still holds the ordinary apply")
    }

    /// The disable respects the runtime file's own external edit: it conflicts, writes nothing and keeps the edit.
    @RuntimeActor func testTheDNSDisableConflictsWithAnExternalRuntimeEdit() async throws {
        let fixture = try ConfigurationStoreTests.Fixture(runtime: try enabledRuntime(), platform: try platformBytes())
        defer { fixture.close() }
        try await load(fixture)
        var edited = GenericDefaults.shared.makeConfig()
        edited.dnsForwarderEnabled = true
        edited.profileName = "Edited"
        let external = try ProxyConfigPersistence.stagedFileData(for: edited)
        fixture.access.externalEdit(.replace(external), at: fixture.plan.config.path)

        let outcome = await disable(fixture)
        XCTAssertEqual(outcome, .conflict)
        XCTAssertEqual(writes(fixture, at: fixture.plan.config.path), 0)
        XCTAssertEqual(fixture.access.storedBytes(at: fixture.plan.config.path), external)
        XCTAssertEqual(fixture.store.values?.runtime.dnsForwarderEnabled, true, "no adopted value claims the disable persisted")
    }

    private enum SidecarEdit: CaseIterable {
        case none, delete, change
    }

    /// The decoded `dnsForwarderEnabled` of the runtime file on disk, through the store's own load and the production decoder.
    @RuntimeActor private func savedDNSEnabled(_ fixture: ConfigurationStoreTests.Fixture) async throws -> Bool? {
        try await load(fixture)
        return fixture.store.values?.runtime.dnsForwarderEnabled
    }

    /// The runtime-only write keeps the legacy guard for both sidecars a runtime file can carry values for (decision 0026): an absent
    /// sidecar holds it, a present unchanged one lets it write, and one deleted or changed since its baseline holds it. No row writes a
    /// sidecar. A persisted row's file decodes to the disable.
    @RuntimeActor func testTheDNSDisableKeepsTheLegacyGuardForBothSidecars() async throws {
        let sidecars: [(ConfigurationComponent, String, Any, () throws -> Data)] = [
            (.platform, "manageSystemProxy", true, platformBytes),
            (.preferences, "showMenuBarIcon", false, { try AppPreferencesPersistence.stagedData(for: AppPreferences()) }),
        ]
        var rows = 0
        for (sidecar, key, value, bytes) in sidecars {
            for present in [false, true] {
                for edit in SidecarEdit.allCases where present || edit == .none {
                    var object = try XCTUnwrap(try JSONSerialization.jsonObject(with: try enabledRuntime()) as? [String: Any])
                    object[key] = value
                    let legacy = try JSONSerialization.data(withJSONObject: object)
                    let platform = sidecar == .platform ? (present ? try bytes() : nil) : try platformBytes()
                    let preferences = sidecar == .preferences && present ? try bytes() : nil
                    let fixture = try ConfigurationStoreTests.Fixture(runtime: legacy, platform: platform, preferences: preferences)
                    defer { fixture.close() }
                    try await load(fixture)
                    let path = fixture.session.configurationFile(for: sidecar).path
                    switch edit {
                    case .none: break
                    case .delete: fixture.access.externalEdit(.remove, at: path)
                    case .change: fixture.access.externalEdit(.replace(Data("{}".utf8)), at: path)
                    }
                    let label = "\(sidecar) present=\(present) edit=\(edit)"
                    let outcome = await disable(fixture)
                    switch (present, edit) {
                    case (false, _):
                        XCTAssertEqual(outcome, .notAttempted(.preservationHeld(.sidecarAbsent)), label)
                        XCTAssertEqual(fixture.access.storedBytes(at: fixture.plan.config.path), legacy, label)
                    case (true, .none):
                        guard case .persisted = outcome else { XCTFail("\(label): \(String(describing: outcome))"); continue }
                        let saved = try await savedDNSEnabled(fixture)
                        XCTAssertEqual(saved, false, "\(label): the saved file decodes to the disable")
                    case (true, _):
                        XCTAssertEqual(outcome, .notAttempted(.preservationHeld(.sidecarChanged)), label)
                        XCTAssertEqual(fixture.access.storedBytes(at: fixture.plan.config.path), legacy, label)
                    }
                    for component in [ConfigurationComponent.platform, .preferences] {
                        XCTAssertEqual(writes(fixture, at: fixture.session.configurationFile(for: component).path), 0, "\(label): \(component)")
                    }
                    rows += 1
                }
            }
        }
        XCTAssertEqual(rows, 8)
    }

    /// An already-disabled file verifies without a write, and a revoked claim writes nothing.
    @RuntimeActor func testAnUnchangedDisableVerifiesAndARevokedClaimWritesNothing() async throws {
        let disabled = try ConfigurationStoreTests.Fixture(
            runtime: try ProxyConfigPersistence.stagedFileData(for: GenericDefaults.shared.makeConfig()), platform: try platformBytes()
        )
        defer { disabled.close() }
        try await load(disabled)
        let unchanged = await disable(disabled)
        guard case .unchanged = try XCTUnwrap(unchanged) else { return XCTFail("an unchanged file verifies, got \(String(describing: unchanged))") }
        XCTAssertEqual(writes(disabled, at: disabled.plan.config.path), 0)

        let revoked = try ConfigurationStoreTests.Fixture(runtime: try enabledRuntime(), platform: try platformBytes())
        defer { revoked.close() }
        try await load(revoked)
        let outcome = await disable(revoked, current: false)
        XCTAssertEqual(outcome, .notAttempted(.superseded))
        XCTAssertEqual(writes(revoked, at: revoked.plan.config.path), 0)
        XCTAssertEqual(revoked.store.values?.runtime.dnsForwarderEnabled, true)
    }
}
