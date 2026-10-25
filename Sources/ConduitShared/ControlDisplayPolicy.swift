// SPDX-License-Identifier: Apache-2.0
import Foundation

/// How the display policy changed one displayed field (decision 0029). A field the policy left alone has no notice.
package enum ControlDisplayTreatment: String, Codable, Sendable, Equatable, CaseIterable {
    /// Redacted, then cut at a character boundary to the field's cap.
    case shortened
    /// Replaced whole by `ControlDisplayText.omittedValue`, because the raw input was over the input limit.
    case omitted
}

/// The record that carries a displayed field's notices. A record's notices may name only its own fields.
package enum ControlDisplayOwner: String, Codable, Sendable, Equatable, CaseIterable {
    case snapshot
    case connectionRow
    case upstreamRow
    case tunnelBindingRow
    case dnsHostRow
    case upstreamProbe

    /// The fields this record can display, in canonical order. Its check names every one of them.
    package var fields: [ControlDisplayField] {
        ControlDisplayField.allCases.filter { $0.owner == self }
    }

    /// The most notices a record can carry: one per field, so no field is named twice.
    package var maxNotices: Int {
        fields.count
    }
}

/// Every free-text field the v2 wire displays through the policy. The set is closed. A new displayed field is a new case here, and
/// its owner and cap are part of this table, so nothing else decides a cap.
package enum ControlDisplayField: String, Codable, Sendable, Equatable, CaseIterable {
    case profileName
    case activeUpstream
    case healthSummary
    case proxyError
    case dnsError
    case tunnelsError
    case vpnInterfaceName
    case lastAuthFallbackReason
    case tunnelDNSUnavailableReason
    case proxyHost
    case socksHost
    case localPACHost
    case dnsHost
    case transparentProxyHost
    case connectionDestination
    case connectionUpstream
    case connectionMethod
    case connectionAuthMethod
    case upstreamName
    case upstreamEndpoint
    case tunnelLabel
    case tunnelLocalHost
    case tunnelRemoteHost
    case dnsHostname
    case probeName
    case probeEndpoint

    /// The record that carries this field's notice.
    package var owner: ControlDisplayOwner {
        switch self {
        case .profileName, .activeUpstream, .healthSummary, .proxyError, .dnsError, .tunnelsError, .vpnInterfaceName,
             .lastAuthFallbackReason, .tunnelDNSUnavailableReason, .proxyHost, .socksHost, .localPACHost, .dnsHost,
             .transparentProxyHost:
            .snapshot
        case .connectionDestination, .connectionUpstream, .connectionMethod, .connectionAuthMethod:
            .connectionRow
        case .upstreamName, .upstreamEndpoint:
            .upstreamRow
        case .tunnelLabel, .tunnelLocalHost, .tunnelRemoteHost:
            .tunnelBindingRow
        case .dnsHostname:
            .dnsHostRow
        case .probeName, .probeEndpoint:
            .upstreamProbe
        }
    }

    /// The most UTF-8 bytes the field may hold after redaction. Config-derived names take the configuration display bound, and the
    /// rest are diagnostics and endpoints, which take the diagnostic bound (decision 0029).
    package var maxBytes: Int {
        switch self {
        case .profileName, .upstreamName, .tunnelLabel, .probeName:
            DomainResourceLimits.displayText
        case .activeUpstream, .healthSummary, .proxyError, .dnsError, .tunnelsError, .vpnInterfaceName,
             .lastAuthFallbackReason, .tunnelDNSUnavailableReason, .proxyHost, .socksHost, .localPACHost, .dnsHost,
             .transparentProxyHost, .connectionDestination, .connectionUpstream, .connectionMethod, .connectionAuthMethod,
             .upstreamEndpoint, .tunnelLocalHost, .tunnelRemoteHost, .dnsHostname, .probeEndpoint:
            ControlDisplayField.diagnosticBytes
        }
    }

    /// The position in the canonical order, which a record's notices must follow.
    package var ordinal: Int {
        ControlDisplayField.allCases.firstIndex(of: self) ?? ControlDisplayField.allCases.count
    }

    /// The cap of diagnostic text and endpoints after redaction (decision 0029).
    package static let diagnosticBytes = 512
}

/// The text one record displays, by field, in canonical order. It names every field of the record's owner, with nil for an absent optional.
package typealias ControlDisplayValues = [(field: ControlDisplayField, text: String?)]

/// One notice: a displayed field of its record was shortened or omitted. A field has at most one notice, and a notice needs its field's
/// value to be present.
package struct ControlDisplayNotice: Codable, Sendable, Equatable {
    package let field: ControlDisplayField
    package let treatment: ControlDisplayTreatment

    package init(field: ControlDisplayField, treatment: ControlDisplayTreatment) {
        self.field = field
        self.treatment = treatment
    }
}

/// Accepts a record's notices one at a time against its owner: membership, canonical order and the count. The decoder runs it before it
/// keeps an element, and the encoder and the projection run it over the whole array, so one rule set serves every direction.
struct ControlDisplayNoticeCheck {
    private let owner: ControlDisplayOwner
    /// The owner's notice limit, cached once so accepting a notice does not rebuild the owner's filtered field list.
    let limit: Int
    private var lastOrdinal = -1
    private(set) var count = 0

    init(owner: ControlDisplayOwner) {
        self.owner = owner
        limit = owner.maxNotices
    }

    mutating func accept(_ notice: ControlDisplayNotice) throws {
        guard count < limit,
              notice.field.owner == owner,
              notice.field.ordinal > lastOrdinal
        else {
            throw ControlRuntimeWireError.invalidValue
        }
        count += 1
        lastOrdinal = notice.field.ordinal
    }
}

/// The one check of a record's display text and notices (decision 0029). The codec runs it on every encode and decode of a record that
/// carries display text, whatever encoder the value reaches. It never rewrites a value: a value outside the contract is refused.
package enum ControlDisplayCheck {
    /// Refuses a record whose text is over its field's cap, whose field list is not its owner's, or whose notices are not a canonical subset
    /// of its owner's fields. It also refuses a notice whose field is absent, and an `omitted` notice whose value is not the fixed marker.
    /// A kept value with no notice is not refused here: a notice cannot prove the history of text that arrived without one.
    package static func validate(
        owner: ControlDisplayOwner,
        notices: [ControlDisplayNotice],
        values: ControlDisplayValues
    ) throws {
        // Counts first: a caller may build arrays of any length, so both are compared with the owner's finite count before any element is read.
        let fields = owner.fields
        guard values.count == fields.count, notices.count <= fields.count else { throw ControlRuntimeWireError.invalidValue }
        guard values.map({ $0.field }) == fields else { throw ControlRuntimeWireError.invalidValue }
        for value in values {
            if let text = value.text, ControlDisplayText.exceeds(text, limit: value.field.maxBytes) {
                throw ControlRuntimeWireError.invalidValue
            }
        }
        var check = ControlDisplayNoticeCheck(owner: owner)
        for notice in notices {
            try check.accept(notice)
            guard let text = values.first(where: { $0.field == notice.field })?.text else {
                throw ControlRuntimeWireError.invalidValue
            }
            if notice.treatment == .omitted, text != ControlDisplayText.omittedValue {
                throw ControlRuntimeWireError.invalidValue
            }
        }
    }

    /// Decodes a record's notices in one bounded pass. The count is refused as soon as it passes the owner's limit, before the element beyond
    /// it is decoded, even when the container cannot report its count. Each element is checked for membership and order before it is kept.
    package static func decodeNotices<Key: CodingKey>(
        from container: KeyedDecodingContainer<Key>,
        forKey key: Key,
        owner: ControlDisplayOwner
    ) throws -> [ControlDisplayNotice] {
        var list = try container.nestedUnkeyedContainer(forKey: key)
        var check = ControlDisplayNoticeCheck(owner: owner)
        var notices: [ControlDisplayNotice] = []
        if let known = list.count, known > check.limit {
            throw DecodingError.dataCorrupted(.init(codingPath: list.codingPath, debugDescription: "more notices than the record has fields"))
        }
        while !list.isAtEnd {
            guard check.count < check.limit else {
                throw DecodingError.dataCorrupted(.init(codingPath: list.codingPath, debugDescription: "more notices than the record has fields"))
            }
            let notice = try list.decode(ControlDisplayNotice.self)
            do {
                try check.accept(notice)
            } catch {
                throw DecodingError.dataCorrupted(.init(codingPath: list.codingPath, debugDescription: "a notice is outside its record"))
            }
            notices.append(notice)
        }
        return notices
    }

    /// The decode-side form of `validate`: a refusal is a corrupt value at the record's coding path.
    package static func checkDecoded(
        owner: ControlDisplayOwner,
        notices: [ControlDisplayNotice],
        values: ControlDisplayValues,
        codingPath: [any CodingKey]
    ) throws {
        do {
            try validate(owner: owner, notices: notices, values: values)
        } catch {
            throw DecodingError.dataCorrupted(.init(
                codingPath: codingPath, debugDescription: "display text or notices are outside their contract"
            ))
        }
    }

    /// The encode-side form of `validate`: a refusal is an invalid value, so the record is never published.
    package static func checkEncoded(
        _ value: Any,
        owner: ControlDisplayOwner,
        notices: [ControlDisplayNotice],
        values: ControlDisplayValues,
        codingPath: [any CodingKey]
    ) throws {
        do {
            try validate(owner: owner, notices: notices, values: values)
        } catch {
            throw EncodingError.invalidValue(value, .init(
                codingPath: codingPath, debugDescription: "display text or notices are outside their contract"
            ))
        }
    }
}
