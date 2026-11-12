// SPDX-License-Identifier: Apache-2.0

/// The text a tunnel names as its target. `CONNECTCoordinator` writes it into
/// the CONNECT request line and the `Host` header it sends an upstream, after
/// Conduit's own `Proxy-Authorization`, and a local client chose it.
enum TunnelAuthority {
    /// Whether `text` can be written into that request line as one token:
    /// visible ASCII only. A CR or LF would end the line and let the client
    /// add headers to an authenticated request, a space or a tab would end
    /// the target, and a NUL, another control, DEL or a non-ASCII byte has no
    /// place in it. What a client writes after the authority (`?`, `#`) is
    /// carried as it was sent.
    static func isWritable(_ text: String) -> Bool {
        !text.isEmpty && text.utf8.allSatisfy { (0x21...0x7E).contains($0) }
    }

    /// `text` as one printable token for an event or a log line: every byte
    /// other than ASCII letters, digits, `.`, `-`, `_`, `:`, `[` and `]`
    /// becomes `_`, so no `=` or space can forge a field, and text over 48
    /// bytes is cut. With its `target=` key it then stays under the 65
    /// characters at which `SensitiveValueSanitizer` replaces a run with
    /// `<redacted-token>`.
    static func printable(_ text: String) -> String {
        let limit = 48
        let shown = text.utf8.prefix(limit).map { isHostByte($0) ? Character(UnicodeScalar($0)) : "_" }
        return String(shown) + (text.utf8.count > limit ? "..." : "")
    }

    private static func isHostByte(_ byte: UInt8) -> Bool {
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
