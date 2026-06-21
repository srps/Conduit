// SPDX-License-Identifier: Apache-2.0
import Foundation

package final class RuntimeEventFileWriter: @unchecked Sendable {
    package static let defaultMaxBytes = 1_048_576

    private let fileURL: URL
    private let maxBytes: Int
    private let logger: any LogSink
    private let queue = DispatchQueue(label: "pm-proxy.events-file")
    private let encoder: JSONEncoder

    package init(
        fileURL: URL,
        maxBytes: Int = RuntimeEventFileWriter.defaultMaxBytes,
        logger: any LogSink
    ) {
        precondition(maxBytes > 0, "RuntimeEventFileWriter maxBytes must be positive")
        self.fileURL = fileURL
        self.maxBytes = maxBytes
        self.logger = logger
        self.encoder = CanonicalJSON.encoder()
    }

    package func record(_ event: RuntimeEvent) {
        queue.async { [self] in
            do {
                try append(event)
            } catch {
                logger.log(
                    .warning,
                    "Failed to write events.ndjson: \(error.localizedDescription)",
                    category: .general
                )
            }
        }
    }

    package func flush() {
        queue.sync {}
    }

    private func append(_ event: RuntimeEvent) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var line = try encoder.encode(event)
        line.append(0x0A)
        guard line.count <= maxBytes else {
            logger.log(.warning, "Skipping oversized runtime event for events.ndjson.", category: .general)
            return
        }

        var data = (try? Data(contentsOf: fileURL)) ?? Data()
        data.append(line)
        data = trim(data)
        try data.write(to: fileURL, options: .atomic)
    }

    private func trim(_ data: Data) -> Data {
        guard data.count > maxBytes else { return data }

        var suffix = data.suffix(maxBytes)
        if let newline = suffix.firstIndex(of: 0x0A) {
            suffix = suffix[suffix.index(after: newline)...]
        }
        return Data(suffix)
    }
}
