import Foundation
import ProxyKernel
import ConduitShared

// Test-only single-request sizing candidate, derived from Candidate.swift. Not part of
// Package.swift, not a production protocol, not an accepted wire schema, and not a
// config cap. Names and kinds below are candidate-only.
//
// ======================================================================================
// WARNING: THE GENERIC CODABLE MIRROR BELOW IS A DELIBERATE TEST-ONLY SHORTCUT.
//
// `V` is a generic JSON-value Codable mirror. It exists only so this probe can measure
// the bytes of one complete envelope. It is NOT the private configuration codec that
// decision 0018 approves. The approved private configuration value must NOT conform to
// general Codable: only its dedicated explicit private codec may encode or decode URL
// plaintext. Events, status, admission replies and outcome lookup stay secret-free.
// This file exercises none of those rules. Its numbers are sizing evidence only.
// ======================================================================================
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

// Candidate-only envelope. It is one value: there is no public half and no private half.
// Its body carries every frozen explicit runtime field (the three URL values included,
// schemaVersion excluded) and every platform field except the app-owned launchAtLogin.
// It carries NO caller-supplied receipts: receipts are authoritative outputs of the store
// after a verified write, so the request cannot supply them.
let encoder = ControlRuntimeCodec.makeEncoder()
let fixedID = "00000000-0000-0000-0000-000000000001"
let artificialTokens = ["ARTIFICIAL-PAC-TOKEN", "ARTIFICIAL-HEALTH-TOKEN", "ARTIFICIAL-DOH-TOKEN"]

struct Row: Codable {
    let fixture: String
    let rawConfigBytes: Int
    let singleFrameBytes: Int
    let roundTripEqual: Bool
    let containsArtificialURLTokens: Bool
}

func measure(_ name: String, _ config: ProxyConfig) throws -> Row {
    precondition(config.validate().isEmpty, "candidate fixture must validate: \(name)")
    precondition(config.schemaVersion == ProxyConfig.currentSchemaVersion, "candidate fixture uses the current schema: \(name)")

    // Raw size: the canonical ProxyConfig JSON, as the current encoder writes it.
    let raw = try CanonicalJSON.encoder().encode(config)

    // Runtime fields: every encoded ProxyConfig key except schemaVersion. The three URL keys
    // stay in this object, because the single envelope carries them explicitly.
    var runtime = try JSONDecoder().decode([String:V].self, from: raw)
    precondition(runtime.removeValue(forKey: "schemaVersion") != nil, "raw config must carry schemaVersion: \(name)")

    // Platform fields: every PlatformIntegrationConfig key except the app-owned launchAtLogin.
    var platform = try JSONDecoder().decode([String:V].self, from: encoder.encode(PlatformIntegrationConfig()))
    precondition(platform.removeValue(forKey: "launchAtLogin") != nil, "platform config must carry launchAtLogin")

    // Workflow request: expected-prior revisions, generation, request/incarnation/budget,
    // then the frozen runtime and platform objects. Revisions are caller expectations,
    // not receipts.
    let body = V.object([
        "requestID": .string(fixedID),
        "expectedIncarnation": .string(fixedID),
        "budget": .int(1000),
        "generation": .int(7),
        "expectedPriorRuntimeRevision": .int(0),
        "expectedPriorPlatformRevision": .int(0),
        "runtime": .object(runtime),
        "platform": .object(platform),
    ])
    let frame = V.object([
        "version": .int(2),
        "kind": .string("candidate-single-config-request"),
        "correlation": .string(fixedID),
        "body": body,
    ])
    let frameBytes = try encoder.encode(frame)

    // Only the artificial_urls fixture has tokens, and the single envelope must carry them.
    // Other fixtures must not contain them. This does not prove ordinary events or status are
    // token-free; that is a production obligation for the explicit private codec.
    let containsTokens = artificialTokens.contains { frameBytes.range(of: Data($0.utf8)) != nil }
    precondition(containsTokens == (name == "artificial_urls"), "token presence must match the fixture: \(name)")

    // Round trip: decode the frame bytes back through the same mirror, rebuild ProxyConfig,
    // and require equality with the input. schemaVersion is restored from the current schema.
    let decoded = try JSONDecoder().decode(V.self, from: frameBytes)
    guard case .object(let root) = decoded,
          case .object(let decodedBody)? = root["body"],
          case .object(var decodedRuntime)? = decodedBody["runtime"],
          case .object(let decodedPlatform)? = decodedBody["platform"]
    else { preconditionFailure("candidate frame lost its runtime or platform object: \(name)") }
    decodedRuntime["schemaVersion"] = .int(ProxyConfig.currentSchemaVersion)
    let rebuilt = try JSONDecoder().decode(ProxyConfig.self, from: encoder.encode(decodedRuntime))
    let equal = rebuilt == config
    precondition(equal, "round trip changed the runtime config: \(name)")

    // Platform round trip: launchAtLogin is absent and defaults to false, matching the default.
    let rebuiltPlatform = try JSONDecoder().decode(PlatformIntegrationConfig.self, from: encoder.encode(decodedPlatform))
    precondition(rebuiltPlatform == PlatformIntegrationConfig(), "round trip changed the platform config: \(name)")

    // Single envelope size: the encoded frame plus its line feed, as the frame codec writes it.
    return Row(
        fixture: name,
        rawConfigBytes: raw.count,
        singleFrameBytes: frameBytes.count + 1,
        roundTripEqual: equal,
        containsArtificialURLTokens: containsTokens
    )
}

func large(_ n: Int) -> ProxyConfig {
    var c = ProxyConfig(); c.profileName = "Corporate VPN"
    c.upstreams = (0..<n).map { UpstreamProxy(name:"corp-\($0)",host:"proxy\($0).example.test",port:8080,priority:$0) }
    c.dnsEntries = (0..<n).map { DomainDNSEntry(domain:"corp\($0).example.test",servers:["192.0.2.1","192.0.2.2"]) }
    c.dnsInterceptRules = (0..<n).map { DNSInterceptRule(pattern:"*.app\($0).example.test",interceptIP:"127.44.3.1") }
    c.tunnelDefinitions = (0..<n).map { TunnelDefinition(localPort:20000+$0,remoteHost:"db\($0).example.test",remotePort:5432,label:"db-\($0)") }
    return c
}

// The same 11 synthetic fixtures as Candidate.swift, in the same order.
var fixtures:[(String,ProxyConfig)] = [("default",ProxyConfig()),("groups_40",large(40)),("groups_1000",large(1000)),("groups_10000",large(10000))]
for bytes in [1024,16384,65536,1048576] {
    var c=ProxyConfig();c.profileName=String(repeating:"🌟",count:bytes/4);fixtures.append(("profile_utf8_\(bytes)",c))
}
var escaped=large(40); escaped.profileName=String(repeating:"\u{0001}\"\\🌟",count:1024);fixtures.append(("escaping",escaped))
var urls=ProxyConfig();urls.pacURL="https://pac.example.test/proxy.pac?token=ARTIFICIAL-PAC-TOKEN";urls.healthCheckURL="https://health.example.test/?token=ARTIFICIAL-HEALTH-TOKEN";urls.dohProviders=["https://doh.example.test/dns-query?token=ARTIFICIAL-DOH-TOKEN"];fixtures.append(("artificial_urls",urls))
var longURL=ProxyConfig();longURL.healthCheckURL="https://health.example.test/?token="+String(repeating:"x",count:1048576);fixtures.append(("private_url_1MiB",longURL))
let rows=try fixtures.map { try measure($0.0,$0.1) }
// External output uses the canonical encoder (Unix-epoch dates, sorted keys), not a plain JSONEncoder.
FileHandle.standardOutput.write(try CanonicalJSON.encoder().encode(rows));FileHandle.standardOutput.write(Data([10]))
