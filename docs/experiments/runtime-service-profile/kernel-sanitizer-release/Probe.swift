import Foundation
import Darwin
import Dispatch

@main struct Probe {
    static func allocated() -> Int {
        var stats = malloc_statistics_t()
        malloc_zone_statistics(nil, &stats)
        return Int(stats.size_in_use)
    }
    static func batch(_ value: String, expected: String) -> UInt64 {
        var checksum: UInt64 = 0
        for _ in 0..<256 {
            let result = SensitiveValueSanitizer.sanitize(value)
            precondition(result == expected)
            for byte in result.utf8 { checksum = (checksum &* 16777619) ^ UInt64(byte) }
        }
        return checksum
    }
    static func run(_ name: String, value: String) {
        let expected = SensitiveValueSanitizer.sanitize(value)
        let start = DispatchTime.now().uptimeNanoseconds
        var first = 0
        var last = 0
        var checksum: UInt64 = 0
        for i in 1...11 {
            checksum ^= batch(value, expected: expected)
            if i == 1 { first = allocated() }
            last = allocated()
        }
        let growth = last - first
        let flat = growth < 65536
        var iterations = 11
        if flat {
            for _ in 12...101 { checksum ^= batch(value, expected: expected) }
            iterations = 101
        }
        let final = allocated()
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        print("case=\(name) firstBytes=\(first) after11Bytes=\(last) firstTo11GrowthBytes=\(growth) finalBytes=\(final) firstToFinalGrowthBytes=\(final-first) batches=\(iterations) callsPerBatch=256 outputBytes=\(expected.utf8.count) checksum=\(checksum) elapsedNanoseconds=\(elapsed)")
    }
    static func main() {
        run("normal", value: "host.corp.example.test:443")
        run("url", value: "https://example.test/path?synthetic-query#synthetic-fragment")
        run("userinfo", value: "https://synthetic-user:synthetic-password@example.test/path?synthetic-query")
        run("header", value: "Authorization: Bearer synthetic-fixture-value")
    }
}
