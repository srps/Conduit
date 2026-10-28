// One-off observation of the kernel connection store's copy-on-write, outside the product: no test, no probe mode, no assertion.
// A second holder stands in for the capture flight's frozen value. Prints one line of numbers per row count.
import Darwin
import Foundation
import ProxyKernel

@main
enum KernelCOWObservation {
    static func inUse() -> Int {
        var stats = malloc_statistics_t()
        malloc_zone_statistics(nil, &stats)
        return Int(stats.size_in_use)
    }

    /// The typical shape of `RuntimeServiceProfileKernels.typical`.
    static func store(_ count: Int) -> ActiveConnectionStore {
        ActiveConnectionStore((0..<count).map { n in
            ActiveConnectionInfo(
                id: UUID(), destination: "host\(n).corp.example.test:443", upstream: "proxy\(n % 4).corp.example.test:8080",
                method: "CONNECT", startedAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(n)),
                lastActivityAt: Date(timeIntervalSince1970: 1_700_000_100 + Double(n)), bytesSent: n * 1_024,
                bytesReceived: n * 4_096, tunnel: n % 2 == 0, authMethod: n % 3 == 0 ? nil : "Negotiate"
            )
        })
    }

    static func main() {
        _ = store(16)  // warm-up, so lazy runtime allocations are not counted below
        for count in [1_000, 10_000] {
            var live = store(count)
            let ids = live.ordered.prefix(2).map(\.id)
            var held = 0, activity = 0, remove = 0, nanos: Int64 = 0
            do {
                let frozen = live
                let before = inUse()
                let started = ContinuousClock.now
                live.update(id: ids[0]) { $0.bytesSent += 1 }  // activity: copies `ordered` only
                let elapsed = started.duration(to: .now).components
                nanos = elapsed.seconds * 1_000_000_000 + elapsed.attoseconds / 1_000_000_000
                activity = inUse() - before
                let afterActivity = inUse()
                live.remove(id: ids[1])  // `ordered` is unique now; the index is still shared, so it is copied
                remove = inUse() - afterActivity
                held = inUse()
                withExtendedLifetime(frozen) {}
            }
            let freed = held - inUse()
            print("{\"rows\":\(count),\"stride\":\(MemoryLayout<ActiveConnectionInfo>.stride),\"orderedCapacity\":\(live.ordered.capacity),"
                  + "\"activityCopyBytes\":\(activity),\"activityCopyNanoseconds\":\(nanos),\"removeCopyBytes\":\(remove),"
                  + "\"releasedOnHolderEndBytes\":\(freed)}")
            withExtendedLifetime(live) {}
        }
    }
}
