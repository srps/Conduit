// SPDX-License-Identifier: Apache-2.0
import Foundation
import os
import ProxyKernel
import ConduitShared
import SystemConfiguration

/// All helper output goes through here, into the unified log.
///
/// It used to be `fputs(stderr)` into a file launchd opened for us, rotated
/// by a `newsyslog(8)` drop-in. That pairing never bounded anything: newsyslog
/// renames and compresses the file, but launchd holds the original fd, so a
/// long-lived helper kept writing into an unlinked inode — lines lost, space
/// invisible. Rather than own a second log store for a dozen call sites, the
/// helper now logs where macOS daemons are meant to: the system keeps,
/// rotates and indexes it, and the app mirrors its own lines under the same
/// subsystem, so one query reads both processes in order:
///
///     /usr/bin/log show --predicate 'subsystem == "io.github.srps.Conduit"' --info --last 1d
///
/// Levels: `notice` → `.default`, `warning` → `.error`, `error` → `.fault`.
/// Only `.default` and above persist to disk by default, which is exactly
/// the set worth reading after the fact. Messages are marked public on
/// purpose — the helper logs ports, hosts and peer verdicts, never secrets —
/// because a redacted `<private>` is no better than the undated line it
/// replaces.
enum HelperLog {
    static func error(_ message: String) { write(.fault, message) }
    static func warning(_ message: String) { write(.error, message) }
    static func notice(_ message: String) { write(.default, message) }

    private static let logger = Logger(subsystem: HelperConstants.logSubsystem, category: "helper")

    private static func write(_ type: OSLogType, _ message: String) {
        logger.log(level: type, "\(message, privacy: .public)")
    }
}

enum HelperDaemon {
    static func run() -> Never {
        let socketPath = HelperConstants.socketPath

        unlink(socketPath)

        let serverFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverFD >= 0 else {
            HelperLog.error("Failed to create socket: \(errnoMessage)")
            exit(EXIT_FAILURE)
        }

        var addr = makeUnixAddr(path: socketPath)
        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.bind(serverFD, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            HelperLog.error("Failed to bind \(socketPath): \(errnoMessage)")
            exit(EXIT_FAILURE)
        }

        chmod(socketPath, 0o660)
        chown(socketPath, 0, 20)  // root:staff – all macOS console users are in gid 20

        guard listen(serverFD, 5) == 0 else {
            HelperLog.error("Failed to listen: \(errnoMessage)")
            exit(EXIT_FAILURE)
        }

        signal(SIGTERM) { _ in
            unlink(HelperConstants.socketPath)
            exit(EXIT_SUCCESS)
        }
        signal(SIGINT) { _ in
            unlink(HelperConstants.socketPath)
            exit(EXIT_SUCCESS)
        }

        HelperLog.notice("ConduitHelper daemon listening on \(socketPath)")

        while true {
            var clientAddr = sockaddr_un()
            var clientLen = socklen_t(MemoryLayout<sockaddr_un>.size)
            let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    accept(serverFD, sockPtr, &clientLen)
                }
            }
            guard clientFD >= 0 else { continue }
            // One accept loop, no threads: a peer that connects and never
            // sends its newline would otherwise hold the helper for every
            // other client. Bounded for everyone, not only the refused.
            setReadTimeout(clientFD, seconds: 5)
            if let refusal = peerRefusal(clientFD) {
                // Drain the request the client is about to write, so the
                // reply lands on a socket it is reading rather than racing
                // its write — then say why, instead of EOF. See
                // `HelperRefusal` for what EOF used to turn into.
                _ = readLine(fd: clientFD)
                switch refusal {
                case .unauthorized:
                    HelperLog.warning("Rejected connection from unauthorized peer")
                    writeLine(fd: clientFD, response: .refused(.unauthorized, "peer is not the console user"))
                case .noConsoleUser:
                    HelperLog.notice("Deferred connection: no console user is logged in yet")
                    writeLine(fd: clientFD, response: .refused(.noConsoleUser, "no console user yet"))
                }
                close(clientFD)
                continue
            }
            handleConnection(clientFD)
            close(clientFD)
        }
    }

    // MARK: - Connection Handling

    private static func handleConnection(_ fd: Int32) {
        guard let lineData = readLine(fd: fd),
              let request = try? JSONDecoder().decode(HelperRequest.self, from: lineData)
        else {
            writeLine(fd: fd, response: .error("Invalid request"))
            return
        }
        // A range, not an exact match. The helper outlives the app that
        // installed it, so an older client can legitimately be on the other end
        // — and those clients reject any reply that is not stamped with their
        // own version, then rethrow instead of degrading. An exact-match helper
        // therefore broke every privileged operation for a rolled-back app.
        //
        // Unversioned frames still fail: they decode as 0, which is outside the
        // range, and the threat model requires the helper to reject them.
        guard let replyVersion = HelperProtocolVersion.replyVersion(forRequest: request.protocolVersion) else {
            writeLine(fd: fd, response: .error(
                "Unsupported helper protocol version \(request.protocolVersion); this helper speaks \(HelperProtocolVersion.minimumSupported)–\(HelperProtocolVersion.current)"
            ))
            return
        }
        var response = processRequest(request)
        // Answer in the dialect we were addressed in.
        response.protocolVersion = replyVersion
        writeLine(fd: fd, response: response)
    }

    private static func processRequest(_ request: HelperRequest) -> HelperResponse {
        switch request.command {
        case .ping:
            return .ok()
        case .startDNSRelay:
            guard let portStr = request.values.first,
                  let port = Int(portStr), (1...65535).contains(port) else {
                return .error("Invalid target port")
            }
            return startDNSRelay(targetPort: port)
        case .stopDNSRelay:
            stopDNSRelay()
            return .ok()
        case .startTCPRelay:
            guard request.values.count >= 2,
                  let listenPort = Int(request.values[0]), (1...65535).contains(listenPort),
                  let targetPort = Int(request.values[1]), (1...65535).contains(targetPort) else {
                return .error("Invalid listen/target port")
            }
            let host = request.values.count >= 3 ? request.values[2] : "127.44.3.0"
            guard HelperInputValidator.validateRelayBindHost(host) else {
                return .error("Invalid relay bind host")
            }
            return startTCPRelay(listenPort: listenPort, targetPort: targetPort, host: host)
        case .stopTCPRelay:
            stopTCPRelay()
            return .ok()
        case .applyDNS, .removeDNS, .applySystemProxy, .clearSystemProxy,
             .setProxyBypass, .setAutoproxyURL, .disableAutoproxy,
             .setWebProxyEndpoint, .setAutoproxy, .setDNSServers:
            let args = HelperArguments(command: request.command, values: request.values)
            do {
                try HelperTool.run(arguments: args)
                return .ok()
            } catch {
                return .error(error.localizedDescription)
            }
        }
    }

    // MARK: - Socket I/O

    private static func readLine(fd: Int32) -> Data? {
        var buffer = Data()
        var byte: UInt8 = 0
        while Darwin.read(fd, &byte, 1) == 1 {
            if byte == UInt8(ascii: "\n") { return buffer }
            buffer.append(byte)
            if buffer.count > 1_048_576 { return nil }
        }
        return buffer.isEmpty ? nil : buffer
    }

    private static func writeLine(fd: Int32, response: HelperResponse) {
        guard var data = try? JSONEncoder().encode(response) else { return }
        data.append(UInt8(ascii: "\n"))
        data.withUnsafeBytes { ptr in
            _ = Darwin.write(fd, ptr.baseAddress!, ptr.count)
        }
    }

    // MARK: - Helpers

    private static func makeUnixAddr(path: String) -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        path.withCString { cstr in
            withUnsafeMutableBytes(of: &addr.sun_path) { buf in
                let dst = buf.baseAddress!.assumingMemoryBound(to: CChar.self)
                _ = strlcpy(dst, cstr, maxLen)
            }
        }
        return addr
    }

    /// `nil` means allowed. Root peers are refused as `unauthorized` rather
    /// than deferred: a uid-0 *peer* is never the console user, whatever the
    /// console's state, and nothing is gained by having it wait.
    private static func peerRefusal(_ fd: Int32) -> HelperRefusal? {
        var euid: uid_t = 0
        var egid: gid_t = 0
        guard getpeereid(fd, &euid, &egid) == 0 else { return .unauthorized }
        guard euid != 0 else { return .unauthorized }
        let consoleUID = consoleUserUID()
        guard consoleUID != 0 else { return .noConsoleUser }
        return euid == consoleUID ? nil : .unauthorized
    }

    private static func setReadTimeout(_ fd: Int32, seconds: Int) {
        var tv = timeval(tv_sec: seconds, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    private static func consoleUserUID() -> uid_t {
        var uid: uid_t = 0
        if let name = SCDynamicStoreCopyConsoleUser(nil, &uid, nil) {
            _ = name
            return uid
        }
        return 0
    }

    private static var errnoMessage: String {
        String(cString: strerror(errno))
    }

    // MARK: - DNS UDP Relay

    nonisolated(unsafe) private static var relay: UDPRelay?
    nonisolated(unsafe) private static var currentDNSRelayTarget: Int?

    private static func startDNSRelay(targetPort: Int) -> HelperResponse {
        // Idempotent: 48 of the field log's DNS-relay starts carried the
        // same target as the relay already running. See `TCPRelayPlan`.
        // "Running" is the socket's word, not ours — a relay whose loop
        // died in place is restarted, not reported.
        if let running = relay, running.isRunning, currentDNSRelayTarget == targetPort {
            return .ok()
        }
        if let dead = relay, !dead.isRunning {
            HelperLog.warning("DNS relay had died in place; restarting")
        }
        stopDNSRelay()
        let r = UDPRelay()
        do {
            try r.start(listenPort: 53, targetPort: targetPort)
            relay = r
            currentDNSRelayTarget = targetPort
            HelperLog.notice("DNS relay started: 127.0.0.1:53 -> 127.0.0.1:\(targetPort)")
            return .ok()
        } catch {
            return .error(error.localizedDescription)
        }
    }

    private static func stopDNSRelay() {
        guard relay != nil else { return }
        relay?.stop()
        relay = nil
        currentDNSRelayTarget = nil
        HelperLog.notice("DNS relay stopped")
    }

    // MARK: - Transparent TCP Relay

    nonisolated(unsafe) private static var tcpRelay: TCPRelay?
    nonisolated(unsafe) private static var currentRelayHost: String?
    nonisolated(unsafe) private static var currentTCPRelay: TCPRelayParameters?

    private static func startTCPRelay(listenPort: Int, targetPort: Int, host: String) -> HelperResponse {
        let requested = TCPRelayParameters(listenPort: listenPort, targetPort: targetPort, host: host)
        if let dead = tcpRelay, !dead.isRunning {
            // The accept loop left on its own. Forget the listener, keep the
            // alias: the app's listener on that address is still bound.
            HelperLog.warning("TCP relay had died in place; restarting")
            dead.stop()
            tcpRelay = nil
            currentTCPRelay = nil
        }
        switch TCPRelayPlan.plan(current: currentTCPRelay, requested: requested) {
        case .unchanged:
            return .ok()
        case .repoint:
            // Listener only. The alias stays: the app's transparent-proxy
            // listener is bound to it right now, and this is the re-point
            // that used to pull it out from under that listener.
            tcpRelay?.stop()
            tcpRelay = nil
            currentTCPRelay = nil
        case .start:
            // The alias follows the host, not the call: it goes only when
            // the host changes. Nothing running on the same host — a dead
            // listener, a failed re-point — keeps the alias the app's
            // listener is bound to.
            if let previous = currentRelayHost, previous != host {
                stopTCPRelay()
            } else {
                tcpRelay?.stop()
                tcpRelay = nil
                currentTCPRelay = nil
            }
        }

        // Non-standard loopback addresses (e.g. 127.44.3.0, the transparent-
        // proxy intercept IP) are not bindable/reachable until aliased onto
        // lo0. /32 netmask is the canonical loopback-alias form — a wider
        // mask would make the .0 address a network address. The alias does
        // not survive reboot; it is re-added whenever a relay starts on a
        // host that has none.
        let addsAlias = host != "127.0.0.1" && currentRelayHost != host
        if addsAlias {
            let status = runIfconfig(["lo0", "alias", host, "netmask", "255.255.255.255"])
            if status != 0 {
                // Non-zero also fires when the alias already exists — the
                // bind below is the authoritative test, so log and continue.
                HelperLog.warning("ifconfig lo0 alias \(host) exited \(status); relying on bind to verify")
            }
            currentRelayHost = host
        }

        let r = TCPRelay()
        do {
            try r.start(listenPort: listenPort, targetPort: targetPort, host: host)
            tcpRelay = r
            currentTCPRelay = requested
            HelperLog.notice("TCP relay started: \(host):\(listenPort) -> \(host):\(targetPort)")
            return .ok()
        } catch {
            // Undo only what this call did. An alias that was already there
            // belongs to a listener that is still bound to it; removing it
            // on a failed re-point stranded that listener until the next
            // reassert put the alias back.
            if addsAlias { removeRelayAliasIfNeeded() }
            return .error("TCP relay bind on \(host):\(listenPort) failed: \(error.localizedDescription)")
        }
    }

    private static func stopTCPRelay() {
        // 42 of the field log's `stop-tcp-relay` commands arrived with no
        // relay running; a no-op should not claim to have stopped one.
        guard tcpRelay != nil || currentRelayHost != nil else { return }
        tcpRelay?.stop()
        tcpRelay = nil
        currentTCPRelay = nil
        removeRelayAliasIfNeeded()
        HelperLog.notice("TCP relay stopped")
    }

    private static func removeRelayAliasIfNeeded() {
        guard let host = currentRelayHost else { return }
        let status = runIfconfig(["lo0", "-alias", host])
        if status != 0 {
            HelperLog.warning("ifconfig lo0 -alias \(host) exited \(status)")
        }
        currentRelayHost = nil
    }

    private static func runIfconfig(_ arguments: [String]) -> Int32 {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/sbin/ifconfig")
        task.arguments = arguments
        do {
            try task.run()
        } catch {
            HelperLog.error("failed to launch ifconfig: \(error.localizedDescription)")
            return -1
        }
        task.waitUntilExit()
        return task.terminationStatus
    }
}
