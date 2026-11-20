// SPDX-License-Identifier: Apache-2.0
import ConduitShared
import Foundation
import ProxyKernel

/// One `pass` runs at a time; `disarm` may run beside one and lands after it on the serial `work` queue.
@RuntimeActor
package final class VPNResolverOverrideController {
    package struct Inputs: Sendable {
        package var manageSystemDNS: Bool
        package var relayServing: Bool
        package var entriesWanted: Bool
        package var reading: PushedResolverReading
        package var serversInUse: Set<String>

        package init(
            manageSystemDNS: Bool,
            relayServing: Bool,
            entriesWanted: Bool,
            reading: PushedResolverReading,
            serversInUse: Set<String>
        ) {
            self.manageSystemDNS = manageSystemDNS
            self.relayServing = relayServing
            self.entriesWanted = entriesWanted
            self.reading = reading
            self.serversInUse = serversInUse
        }
    }

    package enum Support: Sendable, Equatable {
        case unknown
        case supported
        case unsupported
    }

    package private(set) var support = Support.unknown
    package private(set) var armed: VPNResolverOverrideArm?
    /// An arm whose reply was lost or failed: the helper may hold it until a status shows otherwise.
    package private(set) var unconfirmed: VPNResolverOverrideArm?
    package private(set) var published = false

    private let client: any PrivilegeClient
    private let work: PlatformWork
    private let resolverOrder: any ResolverOrderReading
    private let emit: @RuntimeActor (RuntimeEvent, LogLevel) -> Void
    private var armsInFlight = 0
    private var notFirstReported = false
    private var issued: UInt64 = 0
    private var settled: UInt64 = 0

    package init(
        client: any PrivilegeClient,
        work: PlatformWork,
        resolverOrder: any ResolverOrderReading,
        emit: @escaping @RuntimeActor (RuntimeEvent, LogLevel) -> Void
    ) {
        self.client = client
        self.work = work
        self.resolverOrder = resolverOrder
        self.emit = emit
    }

    package var mayArm: Bool {
        armed != nil || unconfirmed != nil || armsInFlight > 0
    }

    package func decide(_ inputs: Inputs) -> VPNResolverOverrideAction {
        VPNResolverOverridePolicy.decide(VPNResolverOverrideInput(
            helperSupports: support != .unsupported,
            manageSystemDNS: inputs.manageSystemDNS,
            relayServing: inputs.relayServing,
            entriesWanted: inputs.entriesWanted,
            reading: inputs.reading,
            serversInUse: inputs.serversInUse,
            armed: unconfirmed ?? armed
        ))
    }

    package func pass(_ inputs: @RuntimeActor () -> Inputs, pollStatus: Bool) async {
        if pollStatus, mayArm { await status() }
        switch decide(inputs()) {
        case .none:
            return
        case .arm(let target):
            await arm(target)
        case .disarm(let reason):
            await disarm(reason)
        }
    }

    /// Bypasses the policy: the disarm that must land before system DNS is cleared or the relay stops.
    package func disarm(_ reason: VPNResolverOverrideDisarmReason) async {
        guard mayArm else { return }
        let sequence = issue()
        let result = await call(.disarm)
        let fresh = settle(sequence)
        switch result {
        case .success(.disarmed):
            emit(RuntimeEvent(kind: .health, event: "dns.vpn_override_disarmed", detail: "reason=\(reason.rawValue)"), .notice)
            if fresh { forget(withdrawal: VPNDNSOverrideReason.disarmed.rawValue) }
        case .success(.unsupported):
            if fresh { markUnsupported() }
        case .success(let reply):
            failed("disarm", reason: "unexpected_reply_\(Self.name(reply))")
        case .failure(let error):
            failed("disarm", reason: error.localizedDescription)
        }
    }

    package func dnsStopped() {
        if !mayArm { support = .unknown }
    }

    private func arm(_ target: VPNResolverOverrideArm) async {
        armsInFlight += 1
        let sequence = issue()
        let result = await call(.arm(service: target.service, servers: target.servers))
        armsInFlight -= 1
        let fresh = settle(sequence)
        switch result {
        case .success(.armed):
            support = .supported
            let detail = "service=\(target.service) servers=\(target.servers.count)"
            emit(RuntimeEvent(kind: .health, event: "dns.vpn_override_armed", detail: detail), .notice)
            guard fresh else { return }
            armed = target
            unconfirmed = nil
            await status()
        case .success(.unsupported):
            if fresh { markUnsupported() }
        case .success(let reply):
            failed("arm", reason: "unexpected_reply_\(Self.name(reply))")
            if fresh { unconfirmed = target }
        case .failure(let error):
            failed("arm", reason: error.localizedDescription)
            if fresh { unconfirmed = target }
        }
    }

    private func status() async {
        let sequence = issue()
        let result = await call(.status)
        guard settle(sequence) else { return }
        switch result {
        case .success(.status(let state)):
            support = .supported
            await confirm(state)
        case .success(.unsupported):
            markUnsupported()
        case .success(let reply):
            failed("status", reason: "unexpected_reply_\(Self.name(reply))")
        case .failure(let error):
            failed("status", reason: error.localizedDescription)
        }
    }

    /// The helper's arm counts as this app's only when this app armed it with these servers.
    private func confirm(_ state: VPNDNSOverrideState?) async {
        let ours = [unconfirmed, armed].compactMap { $0 }
        guard let state, state.owned,
              let held = ours.first(where: { $0.service == state.serviceID && $0.servers == state.servers }) else {
            forget(withdrawal: state == nil ? VPNDNSOverrideReason.helperStopping.rawValue : "rearmed")
            return
        }
        armed = held
        unconfirmed = nil
        if state.published, !published {
            published = true
            emit(RuntimeEvent(kind: .health, event: "dns.vpn_override_published", detail: "service=\(held.service)"), .notice)
        } else if !state.published, published {
            published = false
            let detail = "reason=\(state.reason ?? "unknown")"
            emit(RuntimeEvent(kind: .health, event: "dns.vpn_override_withdrawn", detail: detail), .notice)
        }
        if published { await checkOrder(service: held.service, port: state.port) }
    }

    /// The order that puts a domainless supplemental resolver first is undocumented; this reports it changing.
    private func checkOrder(service: String, port: Int?) async {
        let reader = resolverOrder
        guard let first = await work.run({ reader.firstResolver() }) else { return }
        let ours = first.nameserver == "127.0.0.1" && first.port == (port ?? HelperConstants.vpnDNSOverrideRelayPort)
        if ours {
            notFirstReported = false
        } else if !notFirstReported {
            notFirstReported = true
            emit(RuntimeEvent(kind: .health, event: "dns.vpn_override_not_first", detail: "service=\(service)"), .warning)
        }
    }

    private func call(_ request: VPNDNSOverrideRequest) async -> Result<VPNDNSOverrideReply, any Error> {
        let client = self.client
        return await work.run { Result { try client.vpnDNSOverride(request) } }
    }

    private func issue() -> UInt64 {
        issued += 1
        return issued
    }

    /// A reply may change state only while no later call has replied, so a late arm reply never undoes a disarm.
    private func settle(_ sequence: UInt64) -> Bool {
        guard sequence > settled else { return false }
        settled = sequence
        return true
    }

    private func forget(withdrawal reason: String) {
        if published {
            emit(RuntimeEvent(kind: .health, event: "dns.vpn_override_withdrawn", detail: "reason=\(reason)"), .notice)
        }
        armed = nil
        unconfirmed = nil
        published = false
        notFirstReported = false
    }

    private func markUnsupported() {
        support = .unsupported
        forget(withdrawal: "unsupported")
    }

    private func failed(_ operation: String, reason: String) {
        let detail = "operation=\(operation) reason=\(reason)"
        emit(RuntimeEvent(kind: .health, event: "dns.vpn_override_failed", detail: detail), .warning)
    }

    private static func name(_ reply: VPNDNSOverrideReply) -> String {
        switch reply {
        case .unsupported: "unsupported"
        case .armed: "armed"
        case .disarmed: "disarmed"
        case .status: "status"
        }
    }
}
