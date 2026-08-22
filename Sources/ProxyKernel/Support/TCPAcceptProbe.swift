// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation

/// Whether something accepts on `host:port`, decided by a real connect.
///
/// Used to notice that the helper's TCP relay is gone. The helper is a
/// LaunchDaemon with `KeepAlive`, so launchd relaunches it after a crash —
/// as an amnesiac: its relay listeners are process state, and the relaunch
/// has none. The app meanwhile keeps `bindings.transparentProxyHost` set
/// and the intercept resolver files keep handing clients that address, so
/// every intercepted domain connects to a port nothing is listening on.
/// The DNS relay has had a liveness probe for this since the VPN-flap work;
/// the TCP relay had nothing, and `ping()` had no production caller at all.
package enum TCPAcceptProbe {
    package static func accepts(host: String, port: Int, timeoutMilliseconds: Int32 = 1_000) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else { return false }

        let rc = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if rc == 0 { return true }
        guard errno == EINPROGRESS else { return false }

        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&pfd, 1, timeoutMilliseconds) == 1 else { return false }
        var err: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len) == 0 else { return false }
        return err == 0
    }
}
