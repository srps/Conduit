import Darwin
import Foundation
import ProxyKernel
import ProxyControlBridge
import ConduitShared

enum DisplayBoundsFixture {
    /// The unit that costs the most to encode: a NUL is six encoded bytes, a quote or backslash two, a multibyte scalar its own width, and a
    /// combining mark or a ZWJ sequence stays inside one Character, so a cut lands on its boundary.
    static let wideUnit = "\u{0}\"\\é\u{301}\u{20AC}👨\u{200D}👩\u{200D}👧"

    static func text(atLeast bytes: Int, unit: String = wideUnit) -> String {
        var value = ""
        while value.utf8.count < bytes { value += unit }
        return value
    }

    static func uuid(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012X", value))!
    }

    static func stamp() -> ControlRuntimeStamp {
        ControlRuntimeStamp(
            incarnation: ControlHostIncarnation(rawValue: uuid(1)),
            presentationRevision: ControlPresentationRevision(rawValue: 9)!,
            configRevision: ControlConfigRevision(rawValue: 2)!,
            lifecycleRevision: ControlLifecycleRevision(rawValue: 5)!
        )
    }

    /// A kernel snapshot in which every displayed kernel text carries `value`: the scalars, the bindings' hosts, the upstream and tunnel rows,
    /// one connection and the DNS override. Each optional field is present, so no field is absent by accident.
    static func kernel(text value: String) -> ProxyOrchestratorSnapshot {
        var kernel = ProxyOrchestratorSnapshot()
        kernel.runtimeStatus.activeUpstream = value
        kernel.runtimeStatus.lastHealthSummary = value
        kernel.proxyError = value
        kernel.dnsError = value
        kernel.tunnelsError = value
        kernel.vpnInterfaceName = value
        kernel.lastAuthFallbackReason = value
        kernel.tunnelDNSOverrideStatus = .unavailable(reason: value)
        var bindings = ProxyOrchestratorBindings(proxyHost: nil, proxyPort: 8080, dnsHost: nil)
        bindings.proxyHost = value
        bindings.socksHost = value
        bindings.localPACHost = value
        bindings.dnsHost = value
        bindings.transparentProxyHost = value
        kernel.bindings = bindings
        return kernel
    }

    static func project(_ kernel: ProxyOrchestratorSnapshot, profileName: String) throws -> ControlRuntimeSnapshot {
        try RuntimeSnapshotControlProjection.snapshot(
            kernel, stamp: stamp(), profileName: profileName, collectionRevisions: ControlCollectionRevisions()
        )
    }
}


let shape = CommandLine.arguments[1]
let started = DispatchTime.now().uptimeNanoseconds
func mark(_ stage: String) {
    var usage = rusage()
    precondition(getrusage(RUSAGE_SELF, &usage) == 0)
    var stats = malloc_statistics_t()
    malloc_zone_statistics(nil, &stats)
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { ptr in
        ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    precondition(result == KERN_SUCCESS)
    print("stage=\(stage) seconds=\(Double(DispatchTime.now().uptimeNanoseconds-started)/1e9) peakRSSBytes=\(usage.ru_maxrss) residentBytes=\(info.resident_size) physicalFootprintBytes=\(info.phys_footprint) mallocInUseBytes=\(stats.size_in_use)")
    fflush(stdout)
}
func input() -> String {
    switch shape {
    case "url-dense": return String(repeating: "http://x ", count: 1820)
    case "userinfo-dense": return String(repeating: "http://u:p@x ", count: 1260)
    case "plain-short": return String(repeating: "a", count: 32)
    case "redacted-short": return "Bearer " + String(repeating: "A", count: 4096)
    case "plain-cap-over": return String(repeating: "a", count: 1025)
    case "nul-cap-over": return String(repeating: "\u{0}", count: 1025)
    case "sanitizer-input-limit": return String(repeating: "a", count: 16384)
    case "omitted-input": return String(repeating: "a", count: 16385)
    case "double-input-limit": return String(repeating: "a", count: 32768)
    default: preconditionFailure("unknown synthetic case")
    }
}
let limits = try ControlFrameLimits(maxFrameBytes: 1 << 20) // experiment-only roomy cap; no selected shipping profile
@inline(never) func send(sample: Bool) throws -> Data {
    let raw = input()
    let kernel = DisplayBoundsFixture.kernel(text: raw)
    let projected = try DisplayBoundsFixture.project(kernel, profileName: raw)
    let message = ControlRuntimeMessage(correlation: ControlRequestID(rawValue: DisplayBoundsFixture.uuid(99)), body: .frame(.snapshot(projected)))
    let frame = try ControlRuntimeCodec.encodeFrame(message, limits: limits)
    if sample {
        print("rawBytesPerField=\(raw.utf8.count) frameBytes=\(frame.count) notices=\(projected.displayNotices.count)")
        mark("sender-overlap")
    }
    withExtendedLifetime((raw,kernel,projected,message)) {}
    return frame
}
@inline(never) func roundTrip(sample: Bool) throws -> Int {
    var frame: Data? = try send(sample: sample)
    if sample { mark("wire-only") }
    let decoded = try ControlRuntimeCodec.decodeFullFrame(frame!, limits: limits)
    frame = nil
    guard case .frame(.snapshot(let snapshot)) = decoded.body else { preconditionFailure("snapshot expected") }
    precondition(snapshot.displayNotices.count == ((shape == "plain-short" || shape == "redacted-short") ? 0 : 14))
    if shape == "omitted-input" || shape == "double-input-limit" { precondition(snapshot.profileName == ControlDisplayText.omittedValue) }
    else if shape == "plain-short" { precondition(snapshot.profileName == String(repeating: "a", count: 32)) }
    else if shape == "redacted-short" { precondition(snapshot.profileName == "Bearer <redacted>") }
    else { precondition(snapshot.profileName.utf8.count == 1024) }
    if sample { mark("decoded-only") }
    withExtendedLifetime(decoded) {}
    return snapshot.profileName.utf8.count + snapshot.displayNotices.count
}
mark("baseline")
let one = try roundTrip(sample: true)
mark("after-first-release")
var checksum = one
for _ in 0..<2 { checksum += try roundTrip(sample: false) }
mark("after-2-released")
print("checksum=\(checksum) iterations=3 fixture=DisplayBoundsFixture single-active=true")
