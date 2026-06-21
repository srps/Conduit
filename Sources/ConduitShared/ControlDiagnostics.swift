// SPDX-License-Identifier: Apache-2.0
import Foundation

public enum ControlDiagnosticFileKind: String, Sendable {
    case generic
    case status
    case snapshot
    case ready
    case config
    case platform
    case preferences
    case events
    case manifest
}

public enum ControlDiagnostics {
    public static let defaultBundlePrefix = "proxymanager-diag"

    public static func sanitizedJSONData(
        from data: Data,
        fileKind: ControlDiagnosticFileKind = .generic
    ) throws -> Data {
        let object = try JSONSerialization.jsonObject(with: data)
        let sanitized = sanitizedJSONObject(object, fileKind: fileKind)
        return try JSONSerialization.data(withJSONObject: sanitized, options: [.prettyPrinted, .sortedKeys])
    }

    public static func sanitizedJSONObject(
        _ value: Any,
        fileKind: ControlDiagnosticFileKind = .generic
    ) -> Any {
        sanitizedJSONObject(value, fileKind: fileKind, path: [])
    }

    private static func sanitizedJSONObject(
        _ value: Any,
        fileKind: ControlDiagnosticFileKind,
        path: [String]
    ) -> Any {
        switch value {
        case let dictionary as [String: Any]:
            return Dictionary(uniqueKeysWithValues: dictionary.map { key, value in
                let nextPath = path + [key]
                if isSensitiveKey(key) || shouldRedactValue(at: nextPath, fileKind: fileKind) {
                    return (key, redactedValue(for: value) as Any)
                }
                return (key, sanitizedJSONObject(value, fileKind: fileKind, path: nextPath))
            })
        case let array as [Any]:
            return array.map { sanitizedJSONObject($0, fileKind: fileKind, path: path) }
        case let string as String:
            return sanitizeString(string)
        default:
            return value
        }
    }

    public static func sanitizeString(_ value: String) -> String {
        var sanitized = redactEmbeddedURLCredentials(in: value)
        sanitized = redactHeaderLine(sanitized)
        sanitized = redactAuthTokens(in: sanitized)
        return sanitized
    }

    private static func isSensitiveKey(_ key: String) -> Bool {
        let lowercased = key.lowercased()
        return lowercased.contains("authorization")
            || lowercased.contains("cookie")
            || lowercased.contains("password")
            || lowercased.contains("secret")
            || lowercased.contains("token")
            || lowercased == "nthash"
            || lowercased == "nt_hash"
    }

    private static func redactHeaderLine(_ value: String) -> String {
        let sensitiveHeaders = [
            "authorization",
            "proxy-authorization",
            "cookie",
            "set-cookie",
        ]
        return value
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard let colon = trimmed.firstIndex(of: ":") else {
                    return String(line)
                }
                let name = trimmed[..<colon].lowercased()
                guard sensitiveHeaders.contains(String(name)) else {
                    return String(line)
                }
                return "\(trimmed[..<colon]): <redacted>"
            }
            .joined(separator: "\n")
    }

    private static func redactAuthTokens(in value: String) -> String {
        var result = value
        for scheme in ["Bearer", "Basic", "Negotiate", "NTLM"] {
            result = result.replacingOccurrences(
                of: #"(?i)\#(scheme)\s+[A-Za-z0-9+/_=.-]{8,}"#,
                with: "\(scheme) <redacted>",
                options: .regularExpression
            )
        }
        return result
    }

    private static func redactEmbeddedURLCredentials(in value: String) -> String {
        let pattern = #"\bhttps?://[^\s<>"']+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return value }

        var result = value
        let fullRange = NSRange(value.startIndex..<value.endIndex, in: value)
        let matches = regex.matches(in: value, range: fullRange)
        for match in matches.reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            let candidate = String(result[range])
            guard var components = URLComponents(string: candidate),
                  components.user != nil || components.password != nil else {
                continue
            }
            components.user = components.user == nil ? nil : "<redacted>"
            components.password = components.password == nil ? nil : "<redacted>"
            guard let redacted = components.string else { continue }
            result.replaceSubrange(range, with: redacted)
        }
        return result
    }

    private static func redactedValue(for value: Any) -> Any {
        switch value {
        case let array as [Any]:
            return [
                "count": array.count,
                "redacted": true,
            ] as [String: Any]
        case is [String: Any]:
            return ["redacted": true] as [String: Any]
        default:
            return "<redacted>"
        }
    }

    private static func shouldRedactValue(
        at path: [String],
        fileKind: ControlDiagnosticFileKind
    ) -> Bool {
        guard let rawKey = path.last else { return false }
        let key = rawKey.lowercased()

        switch fileKind {
        case .generic, .platform:
            return false
        case .status:
            return statusRedactedKeys.contains(key)
                || localBindingHostKeys.contains(key)
        case .ready:
            return localBindingHostKeys.contains(key)
        case .snapshot:
            return snapshotRedactedKeys.contains(key)
                || localBindingHostKeys.contains(key)
                || key.hasSuffix("error")
                || isTunnelDNSOverridePayload(path)
        case .config:
            return configRedactedKeys.contains(key)
                || isConfigHostValue(path)
        case .preferences:
            return preferencesRedactedKeys.contains(key)
        case .events:
            return eventsRedactedKeys.contains(key)
        case .manifest:
            return manifestRedactedKeys.contains(key)
        }
    }

    private static let localBindingHostKeys: Set<String> = [
        "dnshost",
        "localpachost",
        "proxyhost",
        "sockshost",
    ]

    private static let statusRedactedKeys: Set<String> = [
        "activeupstream",
        "healthsummary",
        "profilename",
    ]

    private static let snapshotRedactedKeys: Set<String> = [
        "activeconnections",
        "activeupstream",
        "destination",
        "endpoint",
        "lasthealthsummary",
        "proxyerror",
        "upstream",
    ]

    private static let configRedactedKeys: Set<String> = [
        "dnsentries",
        "dnsinterceptrules",
        "dohproviders",
        "domain",
        "forceproxyhosts",
        "healthcheckurl",
        "noproxyhosts",
        "pacurl",
        "profilename",
        "remotehost",
        "tunneldefinitions",
        "upstreams",
        "username",
        "workstation",
    ]

    private static let preferencesRedactedKeys: Set<String> = [
        "preferredbrowsertesturl",
    ]

    private static let eventsRedactedKeys: Set<String> = [
        "detail",
    ]

    private static let manifestRedactedKeys: Set<String> = [
        "statedirectory",
    ]

    private static func isTunnelDNSOverridePayload(_ path: [String]) -> Bool {
        let lowercased = path.map { $0.lowercased() }
        guard lowercased.contains("tunneldnsoverridestatus"),
              let key = lowercased.last else {
            return false
        }
        return key == "failed"
            || key == "hostnames"
            || key == "reason"
            || key == "succeeded"
    }

    private static func isConfigHostValue(_ path: [String]) -> Bool {
        let lowercased = path.map { $0.lowercased() }
        guard lowercased.last == "host" else { return false }
        return lowercased.contains("upstreams")
    }
}
