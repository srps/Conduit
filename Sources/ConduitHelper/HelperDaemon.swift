// SPDX-License-Identifier: Apache-2.0
import Foundation
import ProxyKernel
import ConduitShared
import SystemConfiguration

enum HelperDaemon {
    static func run() -> Never {
        let socketPath = HelperConstants.socketPath

        unlink(socketPath)

        let serverFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverFD >= 0 else {
            fputs("Failed to create socket: \(errnoMessage)\n", stderr)
            exit(EXIT_FAILURE)
        }

        var addr = makeUnixAddr(path: socketPath)
        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.bind(serverFD, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            fputs("Failed to bind \(socketPath): \(errnoMessage)\n", stderr)
            exit(EXIT_FAILURE)
        }

        chmod(socketPath, 0o660)
        chown(socketPath, 0, 20)  // root:staff – all macOS console users are in gid 20

        guard listen(serverFD, 5) == 0 else {
            fputs("Failed to listen: \(errnoMessage)\n", stderr)
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

        fputs("ConduitHelper daemon listening on \(socketPath)\n", stderr)

        while true {
            var clientAddr = sockaddr_un()
            var clientLen = socklen_t(MemoryLayout<sockaddr_un>.size)
            let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    accept(serverFD, sockPtr, &clientLen)
                }
            }
            guard clientFD >= 0 else { continue }
            guard peerIsAllowed(clientFD) else {
                fputs("Rejected connection from unauthorized peer\n", stderr)
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
        guard request.protocolVersion == HelperProtocolVersion.current else {
            writeLine(fd: fd, response: .error("Unsupported helper protocol version"))
            return
        }
        let response = processRequest(request)
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
             .setProxyBypass, .setAutoproxyURL, .disableAutoproxy, .setDNSServers:
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

    private static func peerIsAllowed(_ fd: Int32) -> Bool {
        var euid: uid_t = 0
        var egid: gid_t = 0
        guard getpeereid(fd, &euid, &egid) == 0 else { return false }
        guard euid != 0 else { return false }
        let consoleUID = consoleUserUID()
        guard consoleUID != 0 else { return false }
        return euid == consoleUID
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

    private static func startDNSRelay(targetPort: Int) -> HelperResponse {
        stopDNSRelay()
        let r = UDPRelay()
        do {
            try r.start(listenPort: 53, targetPort: targetPort)
            relay = r
            fputs("DNS relay started: 127.0.0.1:53 -> 127.0.0.1:\(targetPort)\n", stderr)
            return .ok()
        } catch {
            return .error(error.localizedDescription)
        }
    }

    private static func stopDNSRelay() {
        relay?.stop()
        relay = nil
        fputs("DNS relay stopped\n", stderr)
    }

    // MARK: - Transparent TCP Relay

    nonisolated(unsafe) private static var tcpRelay: TCPRelay?
    nonisolated(unsafe) private static var currentRelayHost: String?

    private static func startTCPRelay(listenPort: Int, targetPort: Int, host: String) -> HelperResponse {
        stopTCPRelay()

        // Non-standard loopback addresses (e.g. 127.44.3.0, the transparent-
        // proxy intercept IP) are not bindable/reachable until aliased onto
        // lo0. /32 netmask is the canonical loopback-alias form — a wider
        // mask would make the .0 address a network address. The alias does
        // not survive reboot; it is re-added on every relay start.
        if host != "127.0.0.1" {
            let status = runIfconfig(["lo0", "alias", host, "netmask", "255.255.255.255"])
            if status != 0 {
                // Non-zero also fires when the alias already exists — the
                // bind below is the authoritative test, so log and continue.
                fputs("ifconfig lo0 alias \(host) exited \(status); relying on bind to verify\n", stderr)
            }
            currentRelayHost = host
        }

        let r = TCPRelay()
        do {
            try r.start(listenPort: listenPort, targetPort: targetPort, host: host)
            tcpRelay = r
            fputs("TCP relay started: \(host):\(listenPort) -> \(host):\(targetPort)\n", stderr)
            return .ok()
        } catch {
            removeRelayAliasIfNeeded()
            return .error("TCP relay bind on \(host):\(listenPort) failed: \(error.localizedDescription)")
        }
    }

    private static func stopTCPRelay() {
        tcpRelay?.stop()
        tcpRelay = nil
        removeRelayAliasIfNeeded()
        fputs("TCP relay stopped\n", stderr)
    }

    private static func removeRelayAliasIfNeeded() {
        guard let host = currentRelayHost else { return }
        let status = runIfconfig(["lo0", "-alias", host])
        if status != 0 {
            fputs("ifconfig lo0 -alias \(host) exited \(status)\n", stderr)
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
            fputs("failed to launch ifconfig: \(error.localizedDescription)\n", stderr)
            return -1
        }
        task.waitUntilExit()
        return task.terminationStatus
    }
}
