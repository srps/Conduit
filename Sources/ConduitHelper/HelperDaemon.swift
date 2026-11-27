// SPDX-License-Identifier: Apache-2.0
import Foundation
import os
import ProxyKernel
import ConduitShared
import HelperSupport
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
/// Levels: `notice`/`warning` → `.default`, `error` → `.error`; `.fault` is
/// reserved for invariant violations, so Console's loudest column stays
/// meaningful. Only `.default` and above persist to disk by default, which
/// is exactly the set worth reading after the fact. Messages are marked public on
/// purpose — the helper logs ports, hosts and peer verdicts, never secrets —
/// because a redacted `<private>` is no better than the undated line it
/// replaces.
enum HelperLog {
    static func error(_ message: String) { write(.error, message) }
    static func warning(_ message: String) { write(.default, message) }
    static func notice(_ message: String) { write(.default, message) }
    /// Not persisted by default; for the lines only worth reading live.
    static func info(_ message: String) { write(.info, message) }

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

        // kqueue still records an ignored signal, so the withdrawal on SIGTERM runs on the loop, not in a handler.
        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)
        guard fcntl(serverFD, F_SETFL, fcntl(serverFD, F_GETFL) | O_NONBLOCK) == 0 else {
            HelperLog.error("Failed to make the listening socket non-blocking: \(errnoMessage)")
            exit(EXIT_FAILURE)
        }
        let loop = HelperEventLoop(listenFD: serverFD)
        eventLoop = loop

        // Seed from the live console so a helper restarted mid-session can
        // admit teardown at logout without having served a request first.
        let consoleAtStart = consoleUserUID()
        if consoleAtStart != 0 {
            lastConsoleUID = consoleAtStart
        }
        callerIdentity = loadCallerIdentity()
        VPNDNSOverrideLegacyRestore.run(store: SCDynamicStoreLegacyVPNDNSStore(), file: VPNDNSOverrideLegacyFile()) {
            if $0.isFailure { HelperLog.error($0.logLine) } else { HelperLog.notice($0.logLine) }
        }
        vpnDNSOverride = VPNDNSOverridePublisher(
            store: SCDynamicStoreVPNDNSStore(changed: loop.storeTrigger), relay: failoverRelay, report: logVPNDNSOverride
        )
        HelperLog.notice("ConduitHelper daemon listening on \(socketPath)")

        while true {
            switch loop.next(tickDue: vpnDNSOverride.wantsTicks) {
            case .connection:
                serveConnection(listenFD: serverFD)
            case .ownerExited(let pid):
                HelperLog.notice("vpn-dns-override owner pid=\(pid) exited")
                vpnDNSOverride.ownerExited(pid)
            case .storeChanged:
                vpnDNSOverride.sync()
            case .tick:
                vpnDNSOverride.tick()
            case .signal(let number):
                HelperLog.notice("ConduitHelper received signal \(number); stopping")
                vpnDNSOverride.disarm(.helperStopping)
                unlink(HelperConstants.socketPath)
                exit(EXIT_SUCCESS)
            case .failed(let why):
                HelperLog.error("ConduitHelper event loop failed (\(why)); stopping")
                vpnDNSOverride.disarm(.helperStopping)
                unlink(HelperConstants.socketPath)
                exit(EXIT_FAILURE)
            }
            restartDeadFailoverHalves()
            stopFailoverRelayOnceClean()
            followOwner(loop)
        }
    }

    private static func serveConnection(listenFD serverFD: Int32) {
        var clientAddr = sockaddr_un()
        var clientLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                accept(serverFD, sockPtr, &clientLen)
            }
        }
        guard clientFD >= 0 else { return }
        // Only the listener is non-blocking; `HelperLineIO` polls a blocking connection.
        if fcntl(clientFD, F_SETFL, fcntl(clientFD, F_GETFL) & ~O_NONBLOCK) != 0 {
            HelperLog.warning("Could not make the connection blocking (\(errnoMessage)); serving it non-blocking")
        }
        // Who is on the other end, read off the socket before a byte of
        // the request: an identity refusal holds whatever the request says.
        let identity = callerIdentity.identifier.identify(fd: clientFD)
        let callerVerdict = HelperAdmission.callerVerdict(policy: callerIdentity.policy, identity: identity)
        // One accept loop, no threads: whatever a peer is given, every
        // other client waits for. The bound is on the whole request, not
        // on each read, so a peer that drips bytes gains nothing by it.
        // A peer that will be refused whatever it asks gets a fraction.
        let refusalBeforeReading: PeerRefusal?
        if case .refused(let why) = callerVerdict {
            refusalBeforeReading = PeerRefusal(reason: .unauthorized, message: why.message, outcome: why.auditOutcome)
        } else {
            refusalBeforeReading = peerRefusalBeforeReading(clientFD).map(PeerRefusal.init(uidRefusal:))
        }
        let budget = refusalBeforeReading == nil ? TransactionBudget.admitted : TransactionBudget.refused
        // Read the request first even then: at the loginwindow the verdict
        // depends on the command, and the reply must not race the client's
        // write — a client refused before it wrote sees a broken pipe,
        // not the refusal it retries on.
        let read = HelperLineIO.readLine(
            fd: clientFD,
            deadline: HelperLineIO.deadline(afterMilliseconds: budget.requestMilliseconds),
            maxBytes: budget.requestBytes
        )
        if read == .deadlineExceeded {
            HelperLog.warning("Request not received within \(budget.requestMilliseconds) ms; dropping it")
        }
        var request: HelperRequest?
        if case .line(let data) = read, refusalBeforeReading == nil {
            request = try? JSONDecoder().decode(HelperRequest.self, from: data)
        }
        let replyDeadline = HelperLineIO.deadline(afterMilliseconds: budget.replyMilliseconds)
        // The early verdict stands: re-deciding after the wait could admit
        // a peer whose request was deliberately never decoded.
        let refusal = refusalBeforeReading
            ?? peerRefusal(clientFD, command: request?.command, values: request?.values ?? []).map(PeerRefusal.init(uidRefusal:))
        // The audit line is built from what the helper measured and
        // decided, never from the request's values or an error's text:
        // those carry whatever the peer sent. A peer refused early has
        // no command in its line, since its request is never decoded.
        if refusalBeforeReading == nil, refusal?.reason != .unauthorized,
           let request, request.command == .compareNetworkSettings,
           let replyVersion = HelperProtocolVersion.replyVersion(forRequest: request.protocolVersion),
           HelperAdmission.scopedSettingsAdmission(values: request.values) == .invalidArguments {
            let line = HelperAudit.line(identity: identity, verdict: callerVerdict, command: request.command, outcome: .invalidArguments)
            HelperLog.notice(line)
            var response = HelperResponse.error("Invalid scoped network settings")
            response.protocolVersion = replyVersion
            writeLine(fd: clientFD, response: response, deadline: replyDeadline)
            close(clientFD)
            return
        }
        if let refusal {
            let line = HelperAudit.line(identity: identity, verdict: callerVerdict, command: request?.command, outcome: refusal.outcome)
            switch refusal.reason {
            case .unauthorized: HelperLog.warning(line)
            case .noConsoleUser: HelperLog.notice(line)
            }
            writeLine(fd: clientFD, response: .refused(refusal.reason, refusal.message), deadline: replyDeadline)
            close(clientFD)
            return
        }
        let outcome = handleConnection(clientFD, request: request, replyDeadline: replyDeadline, peerPID: identity.pid ?? localPeerPID(clientFD))
        close(clientFD)
        let line = HelperAudit.line(identity: identity, verdict: callerVerdict, command: request?.command, outcome: outcome)
        // A ping changes nothing and arrives every health tick; it is
        // logged where it can be read live without filling the store.
        if request?.command == .ping, outcome == .ok {
            HelperLog.info(line)
        } else {
            HelperLog.notice(line)
        }
    }

    // MARK: - Connection Handling

    /// Returns how it ended, for the audit line.
    private static func handleConnection(_ fd: Int32, request: HelperRequest?, replyDeadline: UInt64, peerPID: pid_t?) -> HelperAuditOutcome {
        guard let request else {
            writeLine(fd: fd, response: .error("Invalid request"), deadline: replyDeadline)
            return .invalidRequest
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
            ), deadline: replyDeadline)
            return .unsupportedVersion
        }
        let (processed, outcome) = processRequest(request, peerPID: peerPID)
        var response = processed
        // Answer in the dialect we were addressed in.
        response.protocolVersion = replyVersion
        // The operation's own time is not the peer's: the reply gets a fresh
        // window once there is something to send.
        writeLine(fd: fd, response: response, deadline: HelperLineIO.deadline(afterMilliseconds: TransactionBudget.admitted.replyMilliseconds))
        return outcome
    }

    /// The reply, and its category for the audit line.
    private static func processRequest(_ request: HelperRequest, peerPID: pid_t?) -> (HelperResponse, HelperAuditOutcome) {
        // One budget for every child the command runs, `networksetup` and
        // `ifconfig` alike. The client's deadline is built from the same number.
        let deadline = HelperLineIO.deadline(afterMilliseconds: HelperSubprocess.operationMilliseconds)
        switch request.command {
        case .ping:
            var response = HelperResponse.ok()
            response.features = HelperFeature.allCases
            return (response, .ok)
        case .vpnDNSOverrideArm:
            return armVPNDNSOverride(values: request.values, peerPID: peerPID)
        case .vpnDNSOverrideDisarm:
            vpnDNSOverride.disarm(.disarmed)
            return (.ok(), .ok)
        case .vpnDNSOverrideStatus:
            var response = HelperResponse.ok()
            response.vpnDNSOverride = vpnDNSOverride.status(caller: peerPID)
            return (response, .ok)
        case .dnsRelayStatus:
            return dnsRelayStatus()
        case .startDNSRelay:
            guard let portStr = request.values.first,
                  let port = Int(portStr), (1...65535).contains(port) else {
                return (.error("Invalid target port"), .invalidArguments)
            }
            return relayOutcome(startDNSRelay(targetPort: port, caller: peerPID))
        case .stopDNSRelay:
            // The key must never name a relay that is gone.
            vpnDNSOverride.disarm(.relayStopped)
            stopDNSRelay()
            return (.ok(), .ok)
        case .startTCPRelay:
            guard request.values.count >= 2,
                  let listenPort = Int(request.values[0]), (1...65535).contains(listenPort),
                  let targetPort = Int(request.values[1]), (1...65535).contains(targetPort) else {
                return (.error("Invalid listen/target port"), .invalidArguments)
            }
            let host = request.values.count >= 3 ? request.values[2] : "127.44.3.0"
            guard HelperInputValidator.validateRelayBindHost(host) else {
                return (.error("Invalid relay bind host"), .invalidArguments)
            }
            return relayOutcome(startTCPRelay(listenPort: listenPort, targetPort: targetPort, host: host, deadline: deadline))
        case .stopTCPRelay:
            stopTCPRelay(deadline: deadline)
            return (.ok(), .ok)
        case .applyDNS, .removeDNS, .applySystemProxy, .clearSystemProxy,
             .setProxyBypass, .setAutoproxyURL, .disableAutoproxy,
             .setWebProxyEndpoint, .setAutoproxy, .setDNSServers, .compareNetworkSettings:
            let args = HelperArguments(command: request.command, values: request.values)
            do {
                try HelperTool.run(arguments: args, deadline: deadline)
                return (.ok(), .ok)
            } catch {
                let outcome: HelperAuditOutcome
                if case HelperToolError.invalidInput = error { outcome = .invalidArguments } else { outcome = .commandFailed }
                return (.error(error.localizedDescription), outcome)
            }
        }
    }

    private static func relayOutcome(_ response: HelperResponse) -> (HelperResponse, HelperAuditOutcome) {
        (response, response.success ? .ok : .relayFailed)
    }

    // MARK: - Socket I/O

    /// What one connection may cost every other client. Requests are a
    /// command and a few values; the ceilings are far above any real one.
    private struct TransactionBudget {
        var requestMilliseconds: Int
        var requestBytes: Int
        var replyMilliseconds: Int

        static let admitted = TransactionBudget(
            requestMilliseconds: HelperTransactionBudget.requestMilliseconds,
            requestBytes: 1_048_576,
            replyMilliseconds: HelperTransactionBudget.replyMilliseconds
        )
        /// Long enough for a request already on its way to land, so the
        /// refusal is what the peer reads. Its content is never decoded.
        static let refused = TransactionBudget(requestMilliseconds: 1_000, requestBytes: 65_536, replyMilliseconds: 1_000)
    }

    /// A peer that stops reading cannot hold the loop on the write either.
    private static func writeLine(fd: Int32, response: HelperResponse, deadline: UInt64) {
        guard var data = try? JSONEncoder().encode(response) else { return }
        data.append(UInt8(ascii: "\n"))
        if !HelperLineIO.writeAll(fd: fd, data, deadline: deadline) {
            HelperLog.warning("Reply not accepted by the peer in time; dropping it")
        }
    }

    // MARK: - Caller identity (#46)

    /// A refusal, the words the peer is given for it, and the category the
    /// audit line records instead of those words.
    private struct PeerRefusal {
        var reason: HelperRefusal
        var message: String
        var outcome: HelperAuditOutcome

        init(reason: HelperRefusal, message: String, outcome: HelperAuditOutcome) {
            self.reason = reason
            self.message = message
            self.outcome = outcome
        }

        init(uidRefusal: HelperRefusal) {
            switch uidRefusal {
            case .unauthorized:
                self.init(reason: .unauthorized, message: "peer is not the console user", outcome: .refusedNotConsoleUser)
            case .noConsoleUser:
                self.init(reason: .noConsoleUser, message: "no console user yet", outcome: .deferredNoConsoleUser)
            }
        }
    }

    private struct CallerIdentity {
        var policy: HelperCallerPolicy
        var identifier: any HelperCallerIdentifying
    }

    /// Read once, at start: `install-helper.sh` writes the pin before it
    /// bootstraps the helper, so a new pin always arrives with a restart.
    /// Until `run()` loads it, nobody is admitted.
    nonisolated(unsafe) private static var callerIdentity = CallerIdentity(
        policy: .untrusted(reason: "caller policy not loaded yet"),
        identifier: UnreadableIdentifier(reason: "caller policy not loaded yet")
    )

    private struct UnreadableIdentifier: HelperCallerIdentifying {
        var reason: String
        func identify(fd: Int32) -> HelperCallerIdentity {
            HelperCallerIdentity(readFailure: reason)
        }
    }

    /// Logs the mode once per start — loudly unless it is enforced — so
    /// "is identity checked on this machine" is one `log show` away.
    private static func loadCallerIdentity() -> CallerIdentity {
        let path = HelperConstants.callerRequirementPath
        var policy = HelperCallerPolicyFile.load(path: path)
        var identifier: any HelperCallerIdentifying
        do {
            if case .enforced(let text) = policy {
                identifier = try SecCodeCallerIdentifier(requirementText: text)
            } else {
                identifier = try SecCodeCallerIdentifier(requirementText: nil)
            }
        } catch {
            // Recovered by refusing everyone, not by dropping the pin: see
            // `HelperCallerPolicy.untrusted`.
            policy = .untrusted(reason: "\(path): \(error)")
            identifier = UnreadableIdentifier(reason: "caller policy does not compile")
        }
        switch policy {
        case .enforced(let text):
            HelperLog.notice("Caller identity ENFORCED from \(path): \(text)")
        case .unenforced:
            HelperLog.warning(
                "Caller identity UNENFORCED: no \(path). Any process of the console user may use this helper. "
                + "Sign the app with scripts/create-signing-identity.sh and ./bundle-app.sh, then rerun sudo ./install-helper.sh."
            )
        case .untrusted(let reason):
            HelperLog.error("Caller identity policy UNTRUSTED, refusing every caller until sudo ./install-helper.sh is rerun: \(reason)")
        }
        return CallerIdentity(policy: policy, identifier: identifier)
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
    /// Reads the peer and the console; `HelperAdmission.refusal` decides.
    private static func peerRefusal(_ fd: Int32, command: HelperCommand?, values: [String]) -> HelperRefusal? {
        var euid: uid_t = 0
        var egid: gid_t = 0
        guard getpeereid(fd, &euid, &egid) == 0 else { return .unauthorized }
        let consoleUID = consoleUserUID()
        if consoleUID != 0 {
            lastConsoleUID = consoleUID
        }
        return HelperAdmission.refusal(
            peerUID: euid,
            consoleUID: consoleUID,
            lastConsoleUID: lastConsoleUID,
            command: command,
            values: values
        )
    }

    /// The refusal this peer gets whatever it sends, known before a byte of
    /// the request is read. See `HelperAdmission.refusalBeforeReading`.
    private static func peerRefusalBeforeReading(_ fd: Int32) -> HelperRefusal? {
        var euid: uid_t = 0
        var egid: gid_t = 0
        guard getpeereid(fd, &euid, &egid) == 0 else { return .unauthorized }
        let consoleUID = consoleUserUID()
        if consoleUID != 0 {
            lastConsoleUID = consoleUID
        }
        return HelperAdmission.refusalBeforeReading(
            peerUID: euid,
            consoleUID: consoleUID,
            lastConsoleUID: lastConsoleUID
        )
    }

    /// Last non-zero console uid seen. Single accept loop, no threads.
    nonisolated(unsafe) private static var lastConsoleUID: uid_t?

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

    nonisolated(unsafe) private static var relay: UDPRelay?
    nonisolated(unsafe) private static var currentDNSRelayTarget: Int?
    nonisolated(unsafe) private static var dnsTCPRelay: TCPRelay?
    nonisolated(unsafe) private static var currentDNSTCPRelayTarget: Int?

    static let dnsTCPRelayMaximumSessions = 64

    private static func startDNSRelay(targetPort: Int, caller: pid_t?) -> HelperResponse {
        failoverStopPending = false
        startFailoverRelay(targetPort: targetPort)
        vpnDNSOverride.relayStarted(caller: caller)
        let udpUnchanged = relay?.isRunning == true && currentDNSRelayTarget == targetPort
        let tcpUnchanged = dnsTCPRelay?.isRunning == true && currentDNSTCPRelayTarget == targetPort
        if udpUnchanged && tcpUnchanged { return .ok() }
        if !udpUnchanged {
            if let dead = relay, !dead.isRunning {
                HelperLog.warning("DNS relay had died in place; restarting")
            }
            stopUDPDNSRelay()
            let r = UDPRelay()
            do {
                try r.start(listenPort: 53, targetPort: targetPort)
                relay = r
                currentDNSRelayTarget = targetPort
                HelperLog.notice("DNS relay started: 127.0.0.1:53 -> 127.0.0.1:\(targetPort)")
            } catch {
                stopDNSTCPRelay()
                return .error(error.localizedDescription)
            }
        }
        if !tcpUnchanged {
            startDNSTCPRelay(targetPort: targetPort)
        }
        return .ok()
    }

    /// Never on the forwarder's own port: the key would then name the forwarder, not the relay.
    private static func startFailoverRelay(targetPort: Int) {
        let port = HelperConstants.vpnDNSOverrideRelayPort
        guard targetPort != port else {
            HelperLog.error("dns-relay failover not started: target=\(targetPort) is the relay's own port")
            return
        }
        let wasRunning = failoverRelay.listeningPort != nil && failoverRelay.target == targetPort
        let failures = failoverRelay.start(targetPort: targetPort)
        for failure in failures {
            HelperLog.error("dns-relay failover start_failed listen=127.0.0.1:\(port) target=127.0.0.1:\(targetPort) \(HelperAudit.bounded(failure))")
        }
        if failures.isEmpty, !wasRunning {
            HelperLog.notice("DNS failover relay started: 127.0.0.1:\(port) -> 127.0.0.1:\(targetPort)")
        }
    }

    /// A half that left on its own comes back on the VPN's servers; until it binds, the key is withdrawn.
    private static func restartDeadFailoverHalves() {
        let (restarted, failures) = failoverRelay.restartDeadHalves()
        guard restarted else { return }
        HelperLog.warning("DNS failover relay had died in place; restarting")
        for failure in failures {
            HelperLog.error("dns-relay failover restart_failed \(HelperAudit.bounded(failure))")
        }
        vpnDNSOverride.relayRestarted()
    }

    private static func startDNSTCPRelay(targetPort: Int) {
        if let dead = dnsTCPRelay, !dead.isRunning {
            HelperLog.warning("DNS TCP relay had died in place; restarting")
        }
        stopDNSTCPRelay()
        let maximum = dnsTCPRelayMaximumSessions
        let r = TCPRelay(maximumSessions: maximum, refusedAtCapacity: { total in
            if total == 1 || total % 100 == 0 {
                HelperLog.warning("dns-relay tcp at_capacity sessions=\(maximum) refused_total=\(total)")
            }
        })
        do {
            try r.start(listenPort: 53, targetPort: targetPort, host: "127.0.0.1")
            dnsTCPRelay = r
            currentDNSTCPRelayTarget = targetPort
            HelperLog.notice("DNS TCP relay started: 127.0.0.1:53 -> 127.0.0.1:\(targetPort)")
        } catch {
            HelperLog.error("dns-relay tcp start_failed listen=127.0.0.1:53 target=127.0.0.1:\(targetPort) udp=\(relay?.isRunning == true ? "running" : "stopped") error=\"\(HelperAudit.bounded(error.localizedDescription))\"")
        }
    }

    private static let failoverRelay = DNSFailoverRelay(
        listenPort: HelperConstants.vpnDNSOverrideRelayPort,
        maximumTCPSessions: dnsTCPRelayMaximumSessions,
        droppedAtCapacity: { total in
            if total == 1 || total % 100 == 0 {
                HelperLog.warning("dns-relay udp at_capacity pending=\(DNSFailoverUDPRelay.maximumPendingQueries) dropped_total=\(total)")
            }
        },
        refusedAtCapacity: { total in
            if total == 1 || total % 100 == 0 {
                HelperLog.warning("dns-relay failover tcp at_capacity sessions=\(dnsTCPRelayMaximumSessions) refused_total=\(total)")
            }
        },
        serverSocket: { change in
            switch change {
            case .unavailable(let server, let reason, let retry):
                HelperLog.warning("dns-relay failover server_unavailable server=\(HelperAudit.safe(server)) error=\"\(HelperAudit.bounded(reason))\" retry_ms=\(retry)")
            case .restored(let server):
                HelperLog.notice("dns-relay failover server_restored server=\(HelperAudit.safe(server))")
            }
        }
    )

    /// Set in `run` once the loop exists, before the first request is served.
    nonisolated(unsafe) private static var vpnDNSOverride: VPNDNSOverridePublisher!

    private static func logVPNDNSOverride(_ outcome: VPNDNSOverrideOutcome) {
        if outcome.isFailure {
            HelperLog.error(outcome.logLine)
        } else {
            HelperLog.notice(outcome.logLine)
        }
    }

    /// Set in `run` before the first request is served.
    nonisolated(unsafe) private static var eventLoop: HelperEventLoop!

    /// After every event the watch follows the arm's owner; an owner that can no longer be watched loses the arm.
    private static func followOwner(_ loop: HelperEventLoop) {
        guard let owner = vpnDNSOverride.arm?.owner else {
            loop.watchOwner(nil)
            return
        }
        switch loop.watchOwner(owner) {
        case .watching:
            break
        case .gone:
            HelperLog.notice("vpn-dns-override owner pid=\(owner) already gone")
            vpnDNSOverride.ownerExited(owner)
        case .failed(let why):
            HelperLog.error("vpn-dns-override: cannot watch owner pid=\(owner): \(why); disarming")
            vpnDNSOverride.disarm(.ownerUnwatched)
        }
    }

    /// An arm is taken only from a caller whose exit the loop is already watching, so no key outlives an unwatched owner.
    private static func armVPNDNSOverride(values: [String], peerPID: pid_t?) -> (HelperResponse, HelperAuditOutcome) {
        let service = values.first ?? ""
        let servers = Array(values.dropFirst())
        guard VPNDNSOverridePublisher.isValidArm(service: service, servers: servers) else {
            return (.error("Invalid VPN DNS override"), .invalidArguments)
        }
        guard let peerPID else {
            HelperLog.warning("vpn-dns-override arm declined: no owner pid")
            return (.error("VPN DNS override declined: the caller's pid is unknown"), .commandFailed)
        }
        switch eventLoop.watchOwner(peerPID) {
        case .watching:
            break
        case .gone:
            return (.error("VPN DNS override declined: the caller has exited"), .commandFailed)
        case .failed(let why):
            HelperLog.error("vpn-dns-override arm declined: cannot watch owner pid=\(peerPID): \(why)")
            return (.error("VPN DNS override declined: the caller cannot be watched"), .commandFailed)
        }
        guard vpnDNSOverride.arm(service: service, servers: servers, owner: peerPID) else {
            return (.error("Invalid VPN DNS override"), .invalidArguments)
        }
        var response = HelperResponse.ok()
        response.vpnDNSOverride = vpnDNSOverride.status(caller: peerPID)
        return (response, .ok)
    }

    private static func localPeerPID(_ fd: Int32) -> pid_t? {
        var pid: pid_t = 0
        var length = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0, pid > 0 else { return nil }
        return pid
    }

    private static func dnsRelayStatus() -> (HelperResponse, HelperAuditOutcome) {
        let status: DNSRelayStatus
        do {
            status = try relay?.status(boundMilliseconds: UDPRelay.statusBoundMilliseconds) ?? .notRunning
        } catch {
            HelperLog.error("DNS relay status failed: \(error.localizedDescription)")
            return (.error("DNS relay status failed: \(error.localizedDescription)"), .commandFailed)
        }
        let tcpListening = dnsTCPRelay?.isRunning == true
        var response = HelperResponse.ok()
        switch status {
        case .notRunning:
            response.dnsRelay = HelperDNSRelayStatus(listening: false, targetPort: nil, target: .notRunning, tcpListening: tcpListening)
        case .relaying(let targetPort, let verdict):
            let target: HelperDNSRelayStatus.Target
            switch verdict {
            case .refused: target = .refused
            case .answered: target = .answered
            case .silent: target = .silent
            }
            response.dnsRelay = HelperDNSRelayStatus(listening: true, targetPort: targetPort, target: target, tcpListening: tcpListening)
        }
        return (response, .ok)
    }

    /// Every relay: the key is never left on half a relay. While a key the session may still hold awaits cleanup,
    /// the fail-safe relay keeps answering it, on the VPN's servers, and stops once a read shows the key gone.
    private static func stopDNSRelay() {
        stopUDPDNSRelay()
        stopDNSTCPRelay()
        guard failoverRelay.target != nil else { return }
        if vpnDNSOverride.cleanupPending {
            failoverRelay.setMode(.vpn)
            failoverStopPending = true
            HelperLog.warning("DNS failover relay kept on the VPN's servers until the key's cleanup completes")
            return
        }
        failoverRelay.stop()
        HelperLog.notice("DNS failover relay stopped")
    }

    nonisolated(unsafe) private static var failoverStopPending = false

    private static func stopFailoverRelayOnceClean() {
        guard failoverStopPending, !vpnDNSOverride.cleanupPending else { return }
        failoverStopPending = false
        failoverRelay.stop()
        HelperLog.notice("DNS failover relay stopped after the key's cleanup")
    }

    private static func stopUDPDNSRelay() {
        guard relay != nil else { return }
        relay?.stop()
        relay = nil
        currentDNSRelayTarget = nil
        HelperLog.notice("DNS relay stopped")
    }

    private static func stopDNSTCPRelay() {
        guard dnsTCPRelay != nil else { return }
        dnsTCPRelay?.stop()
        dnsTCPRelay = nil
        currentDNSTCPRelayTarget = nil
        HelperLog.notice("DNS TCP relay stopped")
    }

    // MARK: - Transparent TCP Relay

    nonisolated(unsafe) private static var tcpRelay: TCPRelay?
    nonisolated(unsafe) private static var currentRelayHost: String?
    nonisolated(unsafe) private static var currentTCPRelay: TCPRelayParameters?

    private static func startTCPRelay(listenPort: Int, targetPort: Int, host: String, deadline: UInt64) -> HelperResponse {
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
                stopTCPRelay(deadline: deadline)
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
            let status = runIfconfig(["lo0", "alias", host, "netmask", "255.255.255.255"], deadline: deadline)
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
            if addsAlias { removeRelayAliasIfNeeded(deadline: deadline) }
            return .error("TCP relay bind on \(host):\(listenPort) failed: \(error.localizedDescription)")
        }
    }

    private static func stopTCPRelay(deadline: UInt64) {
        // 42 of the field log's `stop-tcp-relay` commands arrived with no
        // relay running; a no-op should not claim to have stopped one.
        guard tcpRelay != nil || currentRelayHost != nil else { return }
        tcpRelay?.stop()
        tcpRelay = nil
        currentTCPRelay = nil
        removeRelayAliasIfNeeded(deadline: deadline)
        HelperLog.notice("TCP relay stopped")
    }

    private static func removeRelayAliasIfNeeded(deadline: UInt64) {
        guard let host = currentRelayHost else { return }
        let status = runIfconfig(["lo0", "-alias", host], deadline: deadline)
        if status != 0 {
            HelperLog.warning("ifconfig lo0 -alias \(host) exited \(status)")
        }
        currentRelayHost = nil
    }

    /// -1 for an `ifconfig` that could not be launched or outlived the
    /// command's deadline. Both callers log the status and go on: the bind
    /// that follows an `alias` is the test of it, and a `-alias` that did not
    /// land leaves an address on `lo0` that the next start reuses.
    private static func runIfconfig(_ arguments: [String], deadline: UInt64) -> Int32 {
        do {
            return try HelperSubprocess.run("/sbin/ifconfig", arguments, deadline: deadline).exitCode
        } catch {
            HelperLog.error("ifconfig \(arguments.joined(separator: " ")) did not run: \(error.localizedDescription)")
            return -1
        }
    }
}
