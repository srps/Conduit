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
if kind == "supported" || kind == "escaped-supported" {
    let host = [63,63,63,61].map { String(repeating: "a",count:$0) }.joined(separator:".")
    precondition(host.utf8.count == 253)
    let label = kind == "escaped-supported" ? String(repeating: "\u{01}",count:1024) : String(repeating:"x",count:1024)
    func url(_ id: Int) -> String {
        let prefix = "https://fixture.example/dns-query?token=\(id)-"
        return prefix + String(repeating:"x",count:16384-prefix.utf8.count)
    }
    config.profileName = label
    config.auth.username = String(repeating:"u",count:1024)
    config.auth.domain = String(repeating:"d",count:1024)
    config.auth.workstation = String(repeating:"w",count:1024)
    config.proxy.allowedClients = Array(repeating:"127.0.0.1",count:256)
    config.upstreams = (0..<32).map { UpstreamProxy(name:label,host:host,port:3128,priority:$0) }
    config.routing.pacURL = url(100)
    config.health.checkURL = url(101)
    config.routing.noProxyHosts = (0..<256).map { "np\($0).example" }
    config.routing.forceProxyHosts = Array(repeating:host,count:256)
    config.dns.dohProviders = (0..<8).map(url)
    config.dns.entries = (0..<256).map { _ in DomainDNSEntry(domain:host,servers:Array(repeating:"2001:db8:ffff:ffff:ffff:ffff:ffff:ffff",count:8)) }
    config.dns.interceptRules = (0..<256).map { _ in DNSInterceptRule(pattern:host) }
    config.tunnels.definitions = (0..<128).map { TunnelDefinition(localPort:12000+$0,remoteHost:host,remotePort:443,label:label) }
} else if kind == "dense" { config.dns.dohProviders = Array(repeating: "", count: count) }
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
