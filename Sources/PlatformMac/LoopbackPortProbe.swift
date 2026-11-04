// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation

/// Answers "is anything serving this loopback port?" with a syscall.
///
/// The obvious implementation shells out to `lsof`, and the DNS surface still
/// does. Three reasons not to here:
///
/// 1. **It answers a different question.** `lsof` reports which process holds a
///    socket; what a teardown decision needs to know is whether the address the
///    machine's proxy settings point at is *being served*. A `connect` to
///    loopback answers exactly that, and is unambiguous in a way process
///    inspection is not.
/// 2. **No subprocess, so no path to get wrong.** `lsof` lives at
///    `/usr/sbin/lsof` on macOS 26 and `/usr/bin/lsof` on earlier releases; the
///    DNS probe hardcoded the latter and therefore answered "free" on every
///    modern machine. A syscall has no such failure mode, and no `PATH` to
///    inherit — resolving tool locations from the environment is how an
///    elevated process ends up running someone else's binary.
/// 3. **It is fast and bounded.** A loopback connect either completes or is
///    refused immediately; the timeout below only covers a listener whose
///    accept backlog is full.
///
/// A `bind` probe would avoid opening a connection at all, but it cannot be
/// used for the DNS case (binding port 53 unprivileged fails with `EACCES`
/// whether or not anything holds it) and it misreports listeners that set
/// `SO_REUSEPORT`. Connect is the honest test.
package enum LoopbackPortProbe {

    /// Whether something accepts TCP connections on `127.0.0.1:port`, refuses them, or gave no answer in time.
    ///
    /// The connection is closed immediately. For our own proxy that is an
    /// accepted-and-closed socket, which every server on the platform already
    /// has to tolerate.
    package static func liveness(port: Int, timeout: TimeInterval = 0.25) -> LoopbackLiveness {
        guard port > 0, port <= 65535 else { return .notLive }

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return .inconclusive }
        defer { close(fd) }

        // Non-blocking, so a listener with a full backlog cannot hang teardown.
        let flags = fcntl(fd, F_GETFL, 0)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) >= 0 else { return .inconclusive }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian

        let connectResult = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPointer in
                Darwin.connect(fd, sockPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if connectResult == 0 { return .live }
        guard errno == EINPROGRESS else { return errno == ECONNREFUSED ? .notLive : .inconclusive }

        var pollDescriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let milliseconds = Int32(max(0, (timeout * 1000).rounded()))
        guard poll(&pollDescriptor, 1, milliseconds) > 0 else { return .inconclusive }

        // Writable is not the same as connected: a refused connection also
        // wakes the poll, and only `SO_ERROR` distinguishes them.
        var socketError: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &length) == 0 else { return .inconclusive }
        switch socketError {
        case 0: return .live
        case ECONNREFUSED: return .notLive
        default: return .inconclusive
        }
    }
}

package enum LoopbackLiveness: Sendable, Equatable {
    case live
    /// Refused, or answered by something that is not ours: nothing of ours serves the port.
    case notLive
    /// No answer within the timeout, or the probe could not run.
    case inconclusive

    /// The verdict for settings that several ports serve: live if any port is, inconclusive if none is but one gave no answer.
    package static func any(_ verdicts: some Sequence<LoopbackLiveness>) -> LoopbackLiveness {
        var inconclusive = false
        for verdict in verdicts {
            switch verdict {
            case .live: return .live
            case .inconclusive: inconclusive = true
            case .notLive: break
            }
        }
        return inconclusive ? .inconclusive : .notLive
    }
}
