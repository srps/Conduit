import Foundation
import ProxyKernel
import ConduitShared

// Test-only candidate encoding. It is not a production DTO or accepted wire schema.
indirect enum V: Codable {
    case null, bool(Bool), int(Int), double(Double), string(String), array([V]), object([String:V])
    init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let x = try? c.decode(Bool.self) { self = .bool(x) }
        else if let x = try? c.decode(Int.self) { self = .int(x) }
        else if let x = try? c.decode(Double.self) { self = .double(x) }
        else if let x = try? c.decode(String.self) { self = .string(x) }
        else if let x = try? c.decode([V].self) { self = .array(x) }
        else { self = .object(try c.decode([String:V].self)) }
    }
    func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let x): try c.encode(x)
        case .int(let x): try c.encode(x)
        case .double(let x): try c.encode(x)
        case .string(let x): try c.encode(x)
        case .array(let x): try c.encode(x)
        case .object(let x): try c.encode(x)
        }
    }
}
let encoder = ControlRuntimeCodec.makeEncoder()
let fixedID = "00000000-0000-0000-0000-000000000001"
let secretKeys = ["pacURL", "healthCheckURL", "dohProviders"]
struct Row: Codable {
    let fixture: String
    let rawConfigBytes: Int
    let controlCandidateFrameBytes: Int
    let confidentialCandidateFrameBytes: Int
    let roundTripEqual: Bool
    let fitsBothFrames: [String:Bool]
    let chunks4KiB: Int
    let chunks16KiB: Int
    let largestChunkFrame: Int
}
func chunks(_ data: Data, limit: Int) throws -> (Int,Int) {
    // Fixed headroom for this candidate header, and exact encoded verification below.
    let rawLimit = ((limit - 256) / 4) * 3
    var offset = 0, count = 0, maximum = 0
    while offset < data.count {
        let end = min(offset + rawLimit, data.count)
        let payload = data.subdata(in: offset..<end).base64EncodedString()
        let frame = V.object(["version":.int(1),"kind":.string("candidate-config-chunk"),"transfer":.string(fixedID),"index":.int(count),"final":.bool(end == data.count),"data":.string(payload)])
        let bytes = try encoder.encode(frame).count + 1
        precondition(bytes <= limit)
        maximum = max(maximum,bytes); count += 1; offset = end
    }
    return (count,maximum)
}
func measure(_ name: String, _ config: ProxyConfig) throws -> Row {
    precondition(config.validate().isEmpty, "candidate fixture must validate: \(name)")
    let raw = try CanonicalJSON.encoder().encode(config)
    var safe = try JSONDecoder().decode([String:V].self, from: raw)
    var confidential: [String:V] = [:]
    for key in secretKeys { confidential[key] = safe.removeValue(forKey:key)! }
    let schema = safe.removeValue(forKey:"schemaVersion")!
    var platform = try JSONDecoder().decode([String:V].self, from: encoder.encode(PlatformIntegrationConfig()))
    precondition(platform.removeValue(forKey:"launchAtLogin") != nil)
    let receipt = V.object(["revision":.int(1),"writer":.string(fixedID),"generation":.int(7)])
    let commit = V.object(["runtime":.object(safe),"platform":.object(platform),"runtimeReceipt":receipt,"platformReceipt":receipt,"expectedCommittedRevision":.int(0),"privateBinding":.string(fixedID)])
    let command = V.object(["type":.string("candidate-apply-committed"),"commit":commit])
    let submit = V.object(["requestID":.string(fixedID),"expectedIncarnation":.string(fixedID),"command":command,"budget":.int(1000)])
    let control = V.object(["version":.int(2),"kind":.string("request"),"correlation":.string(fixedID),"body":.object(["type":.string("submit"),"submit":submit])])
    let privateInput = V.object(["version":.int(1),"kind":.string("candidate-confidential-input"),"binding":.string(fixedID),"revision":.int(1),"values":.object(confidential)])
    let controlBytes = try encoder.encode(control), privateBytes = try encoder.encode(privateInput)
    for token in ["ARTIFICIAL-PAC-TOKEN", "ARTIFICIAL-HEALTH-TOKEN", "ARTIFICIAL-DOH-TOKEN"] {
        precondition(controlBytes.range(of: Data(token.utf8)) == nil)
        if name == "artificial_urls" { precondition(privateBytes.range(of: Data(token.utf8)) != nil) }
    }
    var restored = safe; restored["schemaVersion"] = schema
    for (k,v) in confidential { restored[k] = v }
    let rebuilt = try JSONDecoder().decode(ProxyConfig.self, from:encoder.encode(restored))
    precondition(rebuilt == config)
    var fits:[String:Bool] = [:]
    for limit in [16384,65536,262144,1048576] { fits[String(limit)] = controlBytes.count+1 <= limit && privateBytes.count+1 <= limit }
    let small1 = try chunks(controlBytes,limit:4096), small2 = try chunks(privateBytes,limit:4096)
    let large1 = try chunks(controlBytes,limit:16384), large2 = try chunks(privateBytes,limit:16384)
    return Row(fixture:name,rawConfigBytes:raw.count,controlCandidateFrameBytes:controlBytes.count+1,confidentialCandidateFrameBytes:privateBytes.count+1,roundTripEqual:true,fitsBothFrames:fits,chunks4KiB:small1.0+small2.0,chunks16KiB:large1.0+large2.0,largestChunkFrame:max(max(small1.1,small2.1),max(large1.1,large2.1)))
}
func large(_ n:Int) -> ProxyConfig {
    var c = ProxyConfig(); c.profileName = "Corporate VPN"
    c.upstreams = (0..<n).map { UpstreamProxy(name:"corp-\($0)",host:"proxy\($0).example.test",port:8080,priority:$0) }
    c.dnsEntries = (0..<n).map { DomainDNSEntry(domain:"corp\($0).example.test",servers:["192.0.2.1","192.0.2.2"]) }
    c.dnsInterceptRules = (0..<n).map { DNSInterceptRule(pattern:"*.app\($0).example.test",interceptIP:"127.44.3.1") }
    c.tunnelDefinitions = (0..<n).map { TunnelDefinition(localPort:20000+$0,remoteHost:"db\($0).example.test",remotePort:5432,label:"db-\($0)") }
    return c
}
var fixtures:[(String,ProxyConfig)] = [("default",ProxyConfig()),("groups_40",large(40)),("groups_1000",large(1000)),("groups_10000",large(10000))]
for bytes in [1024,16384,65536,1048576] {
    var c=ProxyConfig();c.profileName=String(repeating:"🌟",count:bytes/4);fixtures.append(("profile_utf8_\(bytes)",c))
}
var escaped=large(40); escaped.profileName=String(repeating:"\u{0001}\"\\🌟",count:1024);fixtures.append(("escaping",escaped))
var urls=ProxyConfig();urls.pacURL="https://pac.example.test/proxy.pac?token=ARTIFICIAL-PAC-TOKEN";urls.healthCheckURL="https://health.example.test/?token=ARTIFICIAL-HEALTH-TOKEN";urls.dohProviders=["https://doh.example.test/dns-query?token=ARTIFICIAL-DOH-TOKEN"];fixtures.append(("artificial_urls",urls))
var longURL=ProxyConfig();longURL.healthCheckURL="https://health.example.test/?token="+String(repeating:"x",count:1048576);fixtures.append(("private_url_1MiB",longURL))
let rows=try fixtures.map { try measure($0.0,$0.1) }
FileHandle.standardOutput.write(try CanonicalJSON.encoder().encode(rows));FileHandle.standardOutput.write(Data([10]))
