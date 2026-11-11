// SPDX-License-Identifier: Apache-2.0

/// The text a tunnel names as its target. `CONNECTCoordinator` writes it into
/// the CONNECT request line and the `Host` header it sends an upstream, after
/// Conduit's own `Proxy-Authorization`, and a local client chose it.
enum TunnelAuthority {
    /// Whether `text` holds only what a host name, an address or a
    /// `host:port` authority is spelled with: ASCII letters and digits, `.`,
    /// `-`, `_`, `:`, `[` and `]`. A CR or LF would end the request line and
    /// let the client add headers to an authenticated request, a space would
    /// end the target, and a NUL, a control or a non-ASCII byte names no host.
    static func isWritable(_ text: String) -> Bool {
        !text.isEmpty && text.utf8.allSatisfy(isAuthorityByte)
    }

    /// `text` as one printable token for an event or a log line: every byte
    /// `isWritable` refuses becomes `_`, and text over 48 bytes is cut. With
    /// its `target=` key it then stays under the 65 characters at which
    /// `SensitiveValueSanitizer` replaces a run with `<redacted-token>`.
    static func printable(_ text: String) -> String {
        let limit = 48
        let shown = text.utf8.prefix(limit).map { isAuthorityByte($0) ? Character(UnicodeScalar($0)) : "_" }
        return String(shown) + (text.utf8.count > limit ? "..." : "")
    }

    private static func isAuthorityByte(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "0")...UInt8(ascii: "9"):
            true
        case UInt8(ascii: "."), UInt8(ascii: "-"), UInt8(ascii: "_"), UInt8(ascii: ":"), UInt8(ascii: "["), UInt8(ascii: "]"):
            true
        default:
            false
        }
    }
}
