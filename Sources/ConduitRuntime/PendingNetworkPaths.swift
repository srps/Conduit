import ProxyKernel

/// The path updates not yet taken onto the owner, coalesced to at most three: the first, the first one that materially
/// differs from it, and the newest (#198). Keeping only the newest would let a quick excursion such as A → offline → A reach the owner
/// as A alone, so nothing would be invalidated and the settle would treat the burst as unchanged. With the first and the
/// first material change kept, any batch that moved the path away from where it started reaches the owner as a change, while the
/// slot stays bounded whatever the update rate.
struct PendingNetworkPaths: Sendable {
    private var first: NetworkPathState?
    private var excursion: NetworkPathState?
    private var latest: NetworkPathState?

    mutating func append(_ path: NetworkPathState) {
        guard let first else {
            first = path
            latest = path
            return
        }
        // Material, as invalidation judges it: a change only to the cost hints (`isExpensive`, `isConstrained`) must not take
        // the slot and hide a later excursion the proxy acts on.
        if excursion == nil, !path.changedFields(from: first).isEmpty { excursion = path }
        latest = path
    }

    /// The batch in arrival order, without consecutive repeats, and empties the slot.
    mutating func take() -> [NetworkPathState] {
        defer { self = PendingNetworkPaths() }
        var paths: [NetworkPathState] = []
        for path in [first, excursion, latest].compactMap({ $0 }) where paths.last != path {
            paths.append(path)
        }
        return paths
    }
}
