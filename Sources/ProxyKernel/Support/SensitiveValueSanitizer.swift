// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Masks credential-bearing header values before they reach logs, event details,
/// or future on-disk NDJSON sinks.
package enum SensitiveValueSanitizer {
    private static let headerRegex = try! NSRegularExpression(
        pattern: #"(?im)\b(Proxy-Authorization|Authorization|Set-Cookie|Cookie)\s*:\s*[^\r\n]*"#
    )

    private static let bearerRegex = try! NSRegularExpression(
        pattern: #"(?i)\bBearer\s+[^\s,;]+"#
    )

    private static let longBase64LikeRegex = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9+/=_-])[A-Za-z0-9+/=_-]{65,}(?![A-Za-z0-9+/=_-])"#
    )

    private static let urlRegex = try! NSRegularExpression(
        pattern: #"https?://(?:<redacted>|[^\s<>"'])+"#,
        options: [.caseInsensitive]
    )

    /// Observation-only destination. Never use this value for routing or
    /// forwarding: query/fragment bytes belong exclusively to the wire target.
    /// Cut lexically so malformed URL input cannot bypass privacy filtering.
    package static func observableTarget(_ value: String) -> String {
        sanitize(redactSuffix(value))
    }

    package static func auditTarget(_ value: String) -> String {
        observableTarget(value)
    }

    private static func redactSuffix(_ value: String) -> String {
        guard let start = value.firstIndex(where: { $0 == "?" || $0 == "#" }) else { return value }
        return String(value[...start]) + "<redacted>"
    }

    package static func sanitize(_ value: String) -> String {
        guard !value.isEmpty else { return value }

        var output = redactURLs(in: value)
        output = replaceMatches(
            in: output,
            regex: headerRegex,
            template: "$1: <redacted>"
        )
        output = replaceMatches(
            in: output,
            regex: bearerRegex,
            template: "Bearer <redacted>"
        )
        output = replaceMatches(
            in: output,
            regex: longBase64LikeRegex,
            template: "<redacted-token>"
        )
        return output
    }

    private static func redactURLs(in value: String) -> String {
        var result = value
        let matches = urlRegex.matches(
            in: value,
            options: [],
            range: NSRange(value.startIndex..<value.endIndex, in: value)
        ).reversed()

        for match in matches {
            guard let range = Range(match.range, in: result) else { continue }
            let candidate = redactSuffix(String(result[range]))
            guard var components = URLComponents(string: candidate),
                  components.user != nil || components.password != nil else {
                result.replaceSubrange(range, with: candidate)
                continue
            }
            components.user = components.user == nil ? nil : "<redacted>"
            components.password = components.password == nil ? nil : "<redacted>"
            guard let redacted = components.string else { continue }
            result.replaceSubrange(range, with: redacted)
        }
        return result
    }

    private static func replaceMatches(
        in value: String,
        regex: NSRegularExpression,
        template: String
    ) -> String {
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return regex.stringByReplacingMatches(
            in: value,
            options: [],
            range: range,
            withTemplate: template
        )
    }
}
