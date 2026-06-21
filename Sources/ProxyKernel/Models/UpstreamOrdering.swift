// SPDX-License-Identifier: Apache-2.0
import Foundation

package enum UpstreamOrdering {
    package static func orderedIDs(for upstreams: [UpstreamProxy]) -> [UUID] {
        upstreams
            .enumerated()
            .sorted { lhs, rhs in
                if lhs.element.priority == rhs.element.priority {
                    return lhs.offset < rhs.offset
                }
                return lhs.element.priority < rhs.element.priority
            }
            .map(\.element.id)
    }

    package static func reordered(_ upstreams: [UpstreamProxy], orderedIDs: [UUID]) -> [UpstreamProxy] {
        var existing: [UUID: UpstreamProxy] = [:]
        for upstream in upstreams where existing[upstream.id] == nil {
            existing[upstream.id] = upstream
        }
        return orderedIDs.enumerated().compactMap { priority, id in
            guard var upstream = existing[id] else { return nil }
            upstream.priority = priority
            return upstream
        }
    }

    package static func moving(_ upstreams: [UpstreamProxy], id draggedID: UUID, before targetID: UUID?) -> [UpstreamProxy] {
        var orderedIDs = orderedIDs(for: upstreams)
        guard let sourceIndex = orderedIDs.firstIndex(of: draggedID) else { return upstreams }
        orderedIDs.remove(at: sourceIndex)

        if let targetID, let targetIndex = orderedIDs.firstIndex(of: targetID) {
            orderedIDs.insert(draggedID, at: targetIndex)
        } else {
            orderedIDs.append(draggedID)
        }

        return reordered(upstreams, orderedIDs: orderedIDs)
    }

    package static func normalized(_ upstreams: [UpstreamProxy]) -> [UpstreamProxy] {
        reordered(upstreams, orderedIDs: orderedIDs(for: upstreams))
    }
}
