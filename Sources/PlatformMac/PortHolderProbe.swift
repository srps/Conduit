// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation
import ProxyKernel

/// Names the process listening on a local address, via `libproc`.
///
/// Used to turn "port 3128 is already in use" into "port 3128 is held by
/// corp-proxy-agent (pid 1234, /Library/CorpIT/Proxy/corp-proxy-agent)", which
/// is the difference between a dead end and something the user can act on. The
/// motivating case is a managed corporate proxy agent that claims the same port
/// on every VPN reconnect.
///
/// Deliberately does *not* shell out to `lsof`: this runs on a failed start,
/// where spawning a process that can take seconds to walk every open file on
/// the system would be paid on a path that is already going badly.
///
/// Visibility limits, both benign: `proc_pidfdinfo` returns `EPERM` for
/// processes owned by another user, and sandboxed builds may see nothing at
/// all. Either way the scan simply finds no match and the caller falls back to
/// naming the address alone — the probe never fails, it only sometimes cannot
/// tell.
package struct PortHolderProbe: ListenerPortHolderProbing {
    package init() {}

    package func describeHolder(host: String, port: Int) -> String? {
        // `host` is part of the identity of the conflict, not decoration: a
        // machine can hold the same port on several loopback aliases at once
        // (this app itself binds 127.0.0.1 and 127.44.3.0). Matching on port
        // alone returns whichever process the scan reaches first, so the
        // "actionable" error could name an innocent process while the real
        // conflict stands — worse than saying nothing.
        let wanted = inet_addr(host)
        let matchesAnyAddress = wanted == INADDR_NONE

        for pid in Self.allPIDs() {
            guard Self.process(pid, listensOn: port, address: wanted, anyAddress: matchesAnyAddress) else {
                continue
            }
            return Self.describe(pid)
        }
        return nil
    }

    // MARK: - Process enumeration

    private static func allPIDs() -> [pid_t] {
        // Sizing call first: `proc_listpids` with a nil buffer reports the
        // bytes needed. Over-allocate slightly — the set can grow between the
        // two calls, and a short buffer silently truncates.
        let sizingBytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard sizingBytes > 0 else { return [] }

        let capacity = Int(sizingBytes) / MemoryLayout<pid_t>.size + 32
        var pids = [pid_t](repeating: 0, count: capacity)
        let writtenBytes = pids.withUnsafeMutableBufferPointer { buffer in
            proc_listpids(
                UInt32(PROC_ALL_PIDS),
                0,
                buffer.baseAddress,
                Int32(buffer.count * MemoryLayout<pid_t>.size)
            )
        }
        guard writtenBytes > 0 else { return [] }

        let count = Int(writtenBytes) / MemoryLayout<pid_t>.size
        return pids.prefix(count).filter { $0 > 0 }
    }

    /// Whether `pid` holds a TCP socket listening on `port` at an address that
    /// would block a bind to `address` — i.e. no peer, and either the same
    /// address or a wildcard bind that covers it.
    ///
    /// `anyAddress` is set when the caller's host could not be parsed as an
    /// IPv4 literal (a hostname, or an IPv6 address), in which case the port
    /// alone is the best available signal and narrowing further would report
    /// nothing at all.
    private static func process(
        _ pid: pid_t,
        listensOn port: Int,
        address: in_addr_t,
        anyAddress: Bool
    ) -> Bool {
        let sizingBytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard sizingBytes > 0 else { return false }

        let capacity = Int(sizingBytes) / MemoryLayout<proc_fdinfo>.size + 16
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: capacity)
        let writtenBytes = descriptors.withUnsafeMutableBufferPointer { buffer in
            proc_pidinfo(
                pid,
                PROC_PIDLISTFDS,
                0,
                buffer.baseAddress,
                Int32(buffer.count * MemoryLayout<proc_fdinfo>.size)
            )
        }
        guard writtenBytes > 0 else { return false }

        let count = Int(writtenBytes) / MemoryLayout<proc_fdinfo>.size
        for descriptor in descriptors.prefix(count) {
            guard descriptor.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) else { continue }

            var info = socket_fdinfo()
            let expected = Int32(MemoryLayout<socket_fdinfo>.size)
            let read = proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDSOCKETINFO, &info, expected)
            guard read == expected, info.psi.soi_kind == SOCKINFO_TCP else { continue }

            let tcp = info.psi.soi_proto.pri_tcp
            // Both ports are stored in network byte order.
            let localPort = Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport)))
            let foreignPort = UInt16(bigEndian: UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_fport))

            // A zero foreign port is what separates an accept socket from an
            // established connection that merely involves the same local port.
            guard localPort == port, foreignPort == 0 else { continue }

            // An IPv6 socket may be serving IPv4 clients dual-stack, and a
            // caller host we could not parse gives us nothing to compare, so
            // both fall back to the port match alone.
            guard !anyAddress, info.psi.soi_family == AF_INET else { return true }

            let localAddress = tcp.tcpsi_ini.insi_laddr.ina_46.i46a_addr4.s_addr
            // A wildcard bind (0.0.0.0) occupies the port on every address, so
            // it conflicts with any host the caller asked about.
            if localAddress == INADDR_ANY || localAddress == address {
                return true
            }
        }
        return false
    }

    private static func describe(_ pid: pid_t) -> String {
        // `PROC_PIDPATHINFO_MAXSIZE` is a `#define` of `MAXPATHLEN * 4` and is
        // not imported into Swift; spell it out from `MAXPATHLEN`, which is.
        var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let pathLength = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
        let path = pathLength > 0 ? String(cString: pathBuffer) : nil

        var nameBuffer = [CChar](repeating: 0, count: 256)
        let nameLength = proc_name(pid, &nameBuffer, UInt32(nameBuffer.count))
        let name = nameLength > 0 ? String(cString: nameBuffer) : nil

        // `proc_name` truncates to 15 characters, so prefer the executable's
        // own filename when we have the full path.
        let displayName = path.map { ($0 as NSString).lastPathComponent } ?? name ?? "unknown process"

        if let path, path != displayName {
            return "\(displayName) (pid \(pid), \(path))"
        }
        return "\(displayName) (pid \(pid))"
    }
}
