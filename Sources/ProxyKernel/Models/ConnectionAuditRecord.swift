// SPDX-License-Identifier: Apache-2.0
import Foundation

/// One row of the connection audit log (`audit.ndjson`). The
/// per-connection forensic record that complements the
/// orchestrator's `RuntimeEventLog` by answering "what sites went through
/// which upstream with which auth, when?".
///
/// The field set is the *enterprise compliance contract*: log pipelines
/// (Splunk, Datadog, GRC review tools) parse these as structured rows,
/// not as prose. **Do not rename or remove fields without a major-version
/// bump and migration documentation** — wire stability matters.
///
/// One record is emitted per completed client connection (not per HTTP
/// request — bytes are aggregated across the connection's lifetime, which
/// is what compliance auditors care about for tunneled CONNECT and
/// keep-alive HTTP). For SOCKS5 each session is one record. For
/// transparent-mode requests, the source-port-derived synthetic
/// connection is one record.
///
/// Sensitive headers (`Authorization`, `Proxy-Authorization`, `Cookie`,
/// `Set-Cookie`, bearer tokens) are NEVER stored in this record — the
/// `authMethod` field carries the *mechanism* (`Negotiate` / `NTLM` /
/// `none`), not the token. Authentication-related auth-failure detail is
/// captured in `outcome` reason strings, which pass through the central
/// `LogSink` sanitizer at emit time.
package struct ConnectionAuditRecord: Codable, Equatable, Sendable {

    /// Stable connection identifier shared with `ActiveConnectionInfo.id`
    /// so audit rows can be correlated with snapshot-derived diagnostics
    /// across the daemon's lifetime.
    package var id: UUID

    /// Wall-clock timestamp when the connection was opened (not when it
    /// closed). Auditors typically want "when did the request happen?",
    /// not "when did the daemon get around to closing it?".
    package var timestamp: Date

    /// Client peer address (IP only — port is noise for compliance).
    /// Omitted for in-process clients (loopback default mode where the
    /// daemon is the only listener and there's no observed peer to log).
    package var clientAddress: String?

    /// Wire protocol seen at the listener.
    package var scheme: Scheme

    /// Destination as observed at the protocol boundary:
    ///   * HTTP/HTTPS proxy mode → request URI / `host:port` from Host header
    ///   * CONNECT tunnel mode   → `host:port` from CONNECT line
    ///   * SOCKS5                → `host:port` (or `address:port`) from SOCKS request
    ///
    /// For plain-HTTP forward-proxy requests the URI's query string is
    /// redacted before storage (replaced with `?<redacted>`) so credentials
    /// passed as query parameters never land in the audit log; see
    /// `SensitiveValueSanitizer.auditTarget`.
    package var target: String

    /// PAC return value applied for this connection, if PAC routing was
    /// active. Format: the raw PAC string (`"PROXY proxy.corp:8080"`,
    /// `"DIRECT"`, `"PROXY a; PROXY b; DIRECT"`). `nil` when PAC routing
    /// was disabled, no PAC URL was configured, or the request hit a
    /// no-proxy bypass.
    package var pacDecision: String?

    /// Upstream actually used for the connection. Format:
    /// `"<name>@<endpoint>"` for proxied flows, the literal string
    /// `"DIRECT"` for direct-mode flows, or `nil` if the connection
    /// failed before an upstream was selected.
    package var chosenUpstream: String?

    /// Authentication mechanism negotiated with the upstream:
    /// `"Negotiate"`, `"NTLM"`, `"Basic"`, `"none"`. **Mechanism only —
    /// not the token.** Auth tokens never appear in this field.
    package var authMethod: String?

    /// Bytes the client sent up through the proxy.
    package var bytesSent: Int

    /// Bytes the proxy delivered back down to the client.
    package var bytesReceived: Int

    /// Connection lifetime, milliseconds.
    package var durationMS: Int

    /// Final disposition. `.success` for any connection that completed
    /// without a structural error (incl. HTTP 4xx / 5xx — those are
    /// "the upstream answered" outcomes, not proxy failures).
    /// `.failure` carries a short reason tag suitable for grep-grouping.
    package var outcome: Outcome

    package enum Scheme: String, Codable, Sendable {
        case http
        case https
        case connect
        case socks5
        case transparent
    }

    package enum Outcome: Equatable, Sendable {
        case success
        case failure(reason: String)
    }

    package init(
        id: UUID,
        timestamp: Date,
        clientAddress: String?,
        scheme: Scheme,
        target: String,
        pacDecision: String?,
        chosenUpstream: String?,
        authMethod: String?,
        bytesSent: Int,
        bytesReceived: Int,
        durationMS: Int,
        outcome: Outcome
    ) {
        self.id = id
        self.timestamp = timestamp
        self.clientAddress = clientAddress
        self.scheme = scheme
        self.target = target
        self.pacDecision = pacDecision
        self.chosenUpstream = chosenUpstream
        self.authMethod = authMethod
        self.bytesSent = bytesSent
        self.bytesReceived = bytesReceived
        self.durationMS = durationMS
        self.outcome = outcome
    }

    /// Canonical encoder for the audit log wire format. Sources from
    /// `CanonicalJSON.encoder()` so the audit file's `timestamp`
    /// fields encode as Unix-epoch `Double` — directly readable by
    /// Splunk / Datadog / `jq` / `date -r` without a 31-year
    /// reference-date offset.
    ///
    /// Returns a fresh instance per access: `JSONEncoder` is a
    /// reference type that is not `Sendable`, and the
    /// `CanonicalJSON.encoder()` factory explicitly documents
    /// "returns a fresh instance per call." Storing a shared
    /// `static let` would violate that contract and risk a
    /// strict-concurrency diagnostic under Swift 6 when the
    /// `FileConnectionAuditSink` encodes on its background queue.
    package static var canonicalEncoder: JSONEncoder { CanonicalJSON.encoder() }

    /// Canonical decoder paired with `canonicalEncoder`. Sources from
    /// `CanonicalJSON.decoder()` so the date strategy round-trips.
    /// Fresh instance per access for the same `Sendable` reasons as
    /// the encoder above.
    package static var canonicalDecoder: JSONDecoder { CanonicalJSON.decoder() }
}

// MARK: - Outcome Codable

extension ConnectionAuditRecord.Outcome: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case reason
    }

    private enum Kind: String, Codable {
        case success
        case failure
    }

    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(Kind.self, forKey: .kind)
        switch kind {
        case .success:
            self = .success
        case .failure:
            let reason = try c.decode(String.self, forKey: .reason)
            self = .failure(reason: reason)
        }
    }

    package func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .success:
            try c.encode(Kind.success, forKey: .kind)
        case let .failure(reason):
            try c.encode(Kind.failure, forKey: .kind)
            try c.encode(reason, forKey: .reason)
        }
    }
}
