// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation

/// An append-only log file that rolls over by size.
///
/// The previous writer did two things wrong that only show up after the
/// fact, which is the only time a log matters. It opened with
/// `createFile(atPath:contents: nil)`, which **truncates** — every flip of
/// the Settings toggle erased whatever the last session had written. And it
/// never rolled, so a file that was on would grow without bound. This opens
/// `O_APPEND | O_CREAT` (never truncating), counts what it writes, and at
/// `maxBytes` shifts `log → log.1 → … → log.N` and starts a fresh file.
/// 5 MiB × 3 archives is the default — the same order of ceiling Tailscale
/// and Little Snitch put on theirs.
///
/// All file work happens on one serial queue; `write` returns immediately.
/// `flush()` drains the queue and exists for tests and for shutdown.
package final class RotatingLogFile: @unchecked Sendable {
    package let url: URL
    private let maxBytes: Int
    private let archives: Int
    private let queue = DispatchQueue(label: "io.github.srps.Conduit.logfile", qos: .utility)
    private var fd: Int32 = -1
    private var size = 0

    package init(url: URL, maxBytes: Int = 5 << 20, archives: Int = 3) {
        self.url = url
        self.maxBytes = maxBytes
        self.archives = archives
        queue.async { self.open() }
    }

    deinit {
        if fd >= 0 { Darwin.close(fd) }
    }

    package func write(_ data: Data) {
        queue.async { self.append(data) }
    }

    package func flush() {
        queue.sync {}
    }

    package func close() {
        queue.sync {
            if fd >= 0 { Darwin.close(fd) }
            fd = -1
        }
    }

    // MARK: - Queue-confined

    private func open() {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        fd = Darwin.open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else { return }
        var st = stat()
        size = fstat(fd, &st) == 0 ? Int(st.st_size) : 0
    }

    private func append(_ data: Data) {
        guard fd >= 0 else { return }
        if size + data.count > maxBytes, size > 0 {
            rotate()
        }
        data.withUnsafeBytes { buf in
            var offset = 0
            while offset < buf.count {
                let n = Darwin.write(fd, buf.baseAddress! + offset, buf.count - offset)
                if n <= 0 { break }
                offset += n
            }
        }
        size += data.count
    }

    private func rotate() {
        Darwin.close(fd)
        fd = -1
        let fm = FileManager.default
        let base = url.path
        // Oldest first, so each rename lands on a name that is free.
        try? fm.removeItem(atPath: "\(base).\(archives)")
        if archives > 1 {
            for i in stride(from: archives - 1, through: 1, by: -1) {
                try? fm.moveItem(atPath: "\(base).\(i)", toPath: "\(base).\(i + 1)")
            }
        }
        try? fm.moveItem(atPath: base, toPath: "\(base).1")
        open()
    }
}
