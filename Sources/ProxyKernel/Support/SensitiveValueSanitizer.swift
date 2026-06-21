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
        pattern: #"https?://[^\s<>"']+"#,
        options: [.caseInsensitive]
    )

    /// Sanitizes a connection-audit `target` (the observed destination). The
    /// destination can be an absolute request URI (forward-proxy), an
    /// origin-form request target (`/path?token=…`, with the host in the Host
    /// header), or a `host:port` (CONNECT / SOCKS5). A query string can carry
    /// credentials (`?access_token=`, `?sig=`, `?api_key=`), so everything from
    /// the first `?` is dropped (replaced with `?<redacted>` so its presence is
    /// still visible). In a URL `?` only ever begins the query, and `host:port`
    /// targets contain no `?`, so they pass through unchanged. The standard
    /// sanitizer then masks any userinfo or long tokens left in the host/path.
    package static func auditTarget(_ value: String) -> String {
        var trimmed = value
        if let queryStart = value.firstIndex(of: "?") {
            trimmed = String(value[..<queryStart]) + "?<redacted>"
        }
        return sanitize(trimmed)
    }

    package static func sanitize(_ value: String) -> String {
        guard !value.isEmpty else { return value }

        var output = redactURLUserInfo(in: value)
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

    private static func redactURLUserInfo(in value: String) -> String {
        var result = value
        let matches = urlRegex.matches(
            in: value,
            options: [],
            range: NSRange(value.startIndex..<value.endIndex, in: value)
        ).reversed()

        for match in matches {
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
