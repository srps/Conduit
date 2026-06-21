// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Shared `JSONEncoder` / `JSONDecoder` factory for the project's
/// external JSON outputs (NDJSON files, snapshot files, control
/// protocol responses, audit log).
///
/// Standardises two strategies the rest of the project varied on
/// silently:
///
///   * `dateEncodingStrategy = .secondsSince1970` — every `Date` field
///     encodes as a Unix-epoch `Double`. Identical performance to the
///     Swift default (`Double` reference-date 2001), but downstream
///     observability tools (Splunk, Datadog, Elastic, `jq`, `date -r`)
///     all natively interpret Unix epoch. Pre-canonicalisation, every
///     external consumer needed to add 978307200 to make sense of
///     `Date.timeIntervalSinceReferenceDate`-style values, and most
///     didn't bother — the timestamps were silently wrong by 31 years
///     in dashboards.
///   * `outputFormatting = .sortedKeys` — deterministic key order in
///     emitted JSON. Already the convention in
///     `RuntimeEventFileWriter`, `pm-proxy` snapshot/status emitters,
///     and `ProxyConfigPersistence`; the factory just makes it
///     uniform. Stable diffs make `pmctl status` output safe to
///     `diff` between snapshots and let property tests pin wire
///     output without flakiness from key-order drift.
///
/// Use the factories at every site that produces or consumes a file
/// or wire format crossing the daemon boundary. Sites that only
/// round-trip in-process (the Keychain payload envelope inside
/// `ProxyCredentials`, helper IPC `HelperRequest`/`HelperResponse`)
/// can keep using `JSONEncoder()` / `JSONDecoder()` since no external
/// consumer parses those — but going through the factory is also
/// fine and removes a class of "which date strategy was this file?"
/// confusion.
package enum CanonicalJSON {

    /// Encoder configured with the project's canonical strategies.
    /// Returns a fresh instance per call (encoders are not Sendable
    /// across actor boundaries; the cost of building one is
    /// negligible compared to the I/O it then drives).
    package static func encoder(prettyPrinted: Bool = false) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = prettyPrinted
            ? [.prettyPrinted, .sortedKeys]
            : [.sortedKeys]
        return encoder
    }

    /// Decoder configured to match `encoder()`. MUST be paired with
    /// the canonical encoder — pairing it with `JSONDecoder()` (no
    /// strategy override) decodes the encoded `Double` as a
    /// reference-date Date, silently shifting every timestamp by 31
    /// years.
    package static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }
}
