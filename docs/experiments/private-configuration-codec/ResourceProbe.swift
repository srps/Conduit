import Darwin
import Foundation
import ProxyKernel
import ProxyControlBridge
import ConduitShared

let kind = CommandLine.arguments[1]
let count = Int(CommandLine.arguments[2])!
let start = DispatchTime.now().uptimeNanoseconds
func mark(_ stage: String) {
    var usage = rusage()
    precondition(getrusage(RUSAGE_SELF, &usage) == 0)
    let elapsed = Double(DispatchTime.now().uptimeNanoseconds-start)/1e9
    print("stage=\(stage) seconds=\(elapsed) maxRSSBytes=\(usage.ru_maxrss)")
    fflush(stdout)
}
mark("baseline")
var config = ProxyConfig()
if kind == "dense" { config.dns.dohProviders = Array(repeating: "", count: count) }
else { config.profileName = String(repeating: "x", count: count) }
let failures = config.validate()
precondition(failures.isEmpty, "synthetic config failed validation")
mark("validated")
let request = try PrivateConfigurationBridge.makeRequest(config: config, platform: PlatformIntegrationConfig(),
    requestID: ControlRequestID(rawValue: UUID()), incarnation: ControlHostIncarnation(rawValue: UUID()),
    budget: ControlWireBudget(5000), expectedConfigRevision: ControlConfigRevision(rawValue: 1)!,
    expectedPlatformRevision: PrivatePlatformRevision(rawValue: 1)!,
    expectedOwnerGeneration: PrivateConfigExpectedGeneration(rawValue: 1)!)
mark("frozen")
let frame = try PrivateConfigurationEncoder.encode(request)
print("frameBytes=\(frame.count)")
mark("encoded")
let reader = PrivateConfigurationFrameReader()
var decodedBody: PrivateConfigurationFrameBody?
try frame.withUnsafeBytes { bytes in
    var index = 0
    while index < bytes.count {
        let result = try reader.consume(bytes[index...])
        precondition(result.consumed > 0)
        index += result.consumed
        if case .frame(let body) = result.step { decodedBody = body }
    }
}
mark("framed")
let decoded = try PrivateConfigurationDecoder.decode(decodedBody!)
mark("decoded")
let result = try PrivateConfigurationBridge.makeValues(from: decoded, localLaunchAtLogin: false)
precondition(result.config == config)
mark("thawed")
withExtendedLifetime((config,request,frame,decodedBody,decoded,result)) {}
