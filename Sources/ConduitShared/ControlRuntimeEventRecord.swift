// SPDX-License-Identifier: Apache-2.0
import Foundation

/// One event on the v2 wire, classified by what this build knows.
///
/// - `known`: a v1-layout event, or a typed event whose family and lifecycle type this
///   build defines. Its own decoder validates it. A malformed known payload, a known
///   outer name with an unknown family or type, or an outer name, kind or detail that
///   disagrees with its payload, is a decode error. It never becomes `unknown`.
/// - `unknown`: a future informational event. Both its outer name and its typed value are
///   ones this build does not define: the name is not a known event name, and the family
///   or the lifecycle type is not known. It keeps only bounded, redacted text, and its
///   structured payload is discarded.
///
/// The decision reads the typed family, and for the lifecycle family its type, before any
/// payload is decoded. An unknown family's payload is never read at all, so its shape is
/// opaque. A record with no `typed` value is the v1 layout, so it is always known.
///
/// The vocabulary is the event worker's: `ControlTypedRuntimeEvent.knownFamilies`,
/// `ControlLifecycleEvent.knownWireTypes` and `ControlLifecycleEvent.knownEventNames`. The
/// only name written here is the `lifecycle` family, the one family whose payload is
/// discriminated by a type, so it is the only family whose type is probed.
package enum ControlRuntimeEventRecord: Codable, Sendable, Equatable {
    case known(ControlRuntimeEvent)
    case unknown(ControlUnknownEventDisplay)

    private enum CodingKeys: String, CodingKey {
        case timestamp
        case kind
        case event
        case detail
        case typed
    }

    /// Only the family of a typed value. Every other key in the value is ignored unread.
    private struct FamilyProbe: Decodable {
        let family: String
    }

    /// Only the lifecycle type of a lifecycle value. Its other fields are not read here.
    private struct LifecycleProbe: Decodable {
        let lifecycle: TypeProbe

        struct TypeProbe: Decodable {
            let type: String
        }
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // The outer fields are required for both branches, so an unknown record still has
        // a time and a name to show. A missing one is malformed, not unknown.
        let timestamp = try container.decode(Date.self, forKey: .timestamp)
        let kind = try container.decode(String.self, forKey: .kind)
        let event = try container.decode(String.self, forKey: .event)
        let detail = try container.decodeIfPresent(String.self, forKey: .detail)

        if try Self.isGenuinelyUnknown(container, event: event) {
            self = .unknown(ControlUnknownEventDisplay(
                timestamp: timestamp, kind: kind, event: event, detail: detail
            ))
            return
        }
        // A known name, a known family or type, or a v1 record: decode it strictly.
        self = .known(try ControlRuntimeEvent(from: decoder))
    }

    /// True only when neither the outer name nor the typed value is one this build knows.
    /// A v1 record has no typed value and is never unknown. A known name with an unknown
    /// typed value is corruption, so it is not unknown either.
    private static func isGenuinelyUnknown(
        _ container: KeyedDecodingContainer<CodingKeys>,
        event: String
    ) throws -> Bool {
        guard container.contains(.typed) else { return false }
        // A typed value must name a family, or it is malformed. The family probe reads nothing
        // else, so an unknown family's payload is never decoded.
        let family = try container.decode(FamilyProbe.self, forKey: .typed).family
        let typedIsKnown: Bool
        if !ControlTypedRuntimeEvent.knownFamilies.contains(family) {
            typedIsKnown = false
        } else if family == "lifecycle" {
            // The lifecycle family's payload is named by its type. A missing payload throws here,
            // as malformed, because a lifecycle value without its type is not an event at all.
            let type = try container.decode(LifecycleProbe.self, forKey: .typed).lifecycle.type
            typedIsKnown = ControlLifecycleEvent.knownWireTypes.contains(type)
        } else {
            typedIsKnown = true
        }
        return !typedIsKnown && !ControlLifecycleEvent.knownEventNames.contains(event)
    }

    package func encode(to encoder: any Encoder) throws {
        switch self {
        case .known(let event):
            try event.encode(to: encoder)
        case .unknown:
            throw EncodingError.invalidValue(self, .init(
                codingPath: encoder.codingPath, debugDescription: "a display record is received, never sent"
            ))
        }
    }
}
