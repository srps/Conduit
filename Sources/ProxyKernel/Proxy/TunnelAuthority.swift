// SPDX-License-Identifier: Apache-2.0

/// The text a tunnel names as its target. `CONNECTCoordinator` writes it into
/// the CONNECT request line and the `Host` header of a request that carries
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
}
