// SPDX-License-Identifier: Apache-2.0
// pm-tls-check — TLS-inspection diagnostic CLI.
//
// Connects to a host (directly or through an HTTP CONNECT proxy — point it
// at Conduit's own local proxy to see exactly what your tools see),
// captures the presented certificate chain, and classifies it: publicly
// trusted, locally-trusted inspection (Zscaler/Netskope/corp CA), or
// untrusted. `--export-pem` writes the inspection CA(s) for toolchain
// trust (NODE_EXTRA_CA_CERTS, REQUESTS_CA_BUNDLE, curl --cacert, …).
//
// Sibling of pm-vpn-check / pm-auth-check: a standalone, side-effect-free
// diagnostic that needs no daemon.

import Foundation
import Network
import PlatformMac
import Security

@main
struct PMTlsCheck {
    struct Options {
        var host: String
        var port: UInt16 = 443
        var proxyHost: String?
        var proxyPort: UInt16 = 3128
        var exportPEMPath: String?
        var json = false
        var timeoutSeconds: Int = 10
    }

    static func main() {
        guard let options = parseOptions() else {
            printUsage()
            exit(2)
        }

        let capture = captureChain(options: options)
        switch capture {
        case .failure(let message):
            FileHandle.standardError.write(Data("pm-tls-check: \(message)\n".utf8))
            exit(1)
        case .success(let captured):
            let evaluation = TLSInspectionDiagnostics.evaluate(trust: captured.trust, host: options.host)
            let verdict = TLSInspectionDiagnostics.verdict(for: evaluation)
            report(evaluation: evaluation, verdict: verdict, options: options)
            if let pemPath = options.exportPEMPath {
                exportPEM(evaluation: evaluation, chain: captured.chain, to: pemPath)
            }
            // Exit code mirrors the verdict so scripts can branch:
            // 0 = publicly trusted, 3 = inspection (locally trusted),
            // 4 = untrusted.
            switch verdict {
            case .publiclyTrusted: exit(0)
            case .locallyTrustedInspection: exit(3)
            case .untrusted: exit(4)
            }
        }
    }

    // MARK: - Connection / chain capture

    struct CapturedChain {
        let trust: SecTrust
        let chain: [SecCertificate]
    }

    enum CaptureResult {
        case success(CapturedChain)
        case failure(String)
    }

    private static func captureChain(options: Options) -> CaptureResult {
        let queue = DispatchQueue(label: "pm-tls-check")
        let semaphore = DispatchSemaphore(value: 0)
        // Single-assignment slots completed exactly once via `finish`.
        nonisolated(unsafe) var result: CaptureResult?
        nonisolated(unsafe) var capturedTrust: SecTrust?

        let tlsOptions = NWProtocolTLS.Options()
        // Diagnostic capture: approve the handshake regardless of trust so
        // the full presented chain is observable even when the inspection
        // root is not installed. Nothing is sent over the connection.
        sec_protocol_options_set_verify_block(
            tlsOptions.securityProtocolOptions,
            { _, secTrust, complete in
                capturedTrust = sec_trust_copy_ref(secTrust).takeRetainedValue()
                complete(true)
            },
            queue
        )

        let parameters = NWParameters(tls: tlsOptions)
        if let proxyHost = options.proxyHost {
            let endpoint = NWEndpoint.hostPort(
                host: NWEndpoint.Host(proxyHost),
                port: NWEndpoint.Port(rawValue: options.proxyPort) ?? 3128
            )
            let proxyConfig = ProxyConfiguration(httpCONNECTProxy: endpoint)
            parameters.preferNoProxies = false
            privacyContextApplyingProxy(parameters: parameters, proxyConfig: proxyConfig)
        }

        guard let port = NWEndpoint.Port(rawValue: options.port) else {
            return .failure("invalid port \(options.port)")
        }
        let connection = NWConnection(
            host: NWEndpoint.Host(options.host),
            port: port,
            using: parameters
        )

        let finish: @Sendable (CaptureResult) -> Void = { outcome in
            queue.async {
                guard result == nil else { return }
                result = outcome
                connection.cancel()
                semaphore.signal()
            }
        }

        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                if let trust = capturedTrust {
                    let chain = TLSInspectionDiagnostics.certificateChain(of: trust)
                    finish(.success(CapturedChain(trust: trust, chain: chain)))
                } else {
                    finish(.failure("handshake completed but no trust object was captured"))
                }
            case .failed(let error):
                finish(.failure("connection failed: \(error)"))
            case .waiting(let error):
                // `waiting` can resolve, but for a diagnostic the first
                // wait reason is the answer the user needs.
                finish(.failure("connection waiting: \(error)"))
            default:
                break
            }
        }

        connection.start(queue: queue)
        if semaphore.wait(timeout: .now() + .seconds(options.timeoutSeconds)) == .timedOut {
            connection.cancel()
            return .failure("timed out after \(options.timeoutSeconds)s")
        }
        return queue.sync { result ?? .failure("internal: no result") }
    }

    /// Proxy configuration rides `NWParameters.PrivacyContext` (macOS 14+);
    /// isolated here so the API surface is one place.
    private static func privacyContextApplyingProxy(
        parameters: NWParameters,
        proxyConfig: ProxyConfiguration
    ) {
        let context = NWParameters.PrivacyContext(description: "pm-tls-check proxy")
        context.proxyConfigurations = [proxyConfig]
        parameters.setPrivacyContext(context)
    }

    // MARK: - Reporting

    private static func report(
        evaluation: TLSChainEvaluation,
        verdict: TLSInspectionVerdict,
        options: Options
    ) {
        if options.json {
            reportJSON(evaluation: evaluation, verdict: verdict, options: options)
            return
        }

        let route = options.proxyHost.map { "via CONNECT proxy \($0):\(options.proxyPort)" } ?? "direct"
        print("pm-tls-check \(options.host):\(options.port) (\(route))")
        print("")
        print("Verdict: \(verdict.headline)")
        print("  trusted on this Mac:        \(evaluation.trustedOnThisMac ? "yes" : "no")")
        print("  trusted by OS store alone:  \(evaluation.trustedBySystemStoreOnly ? "yes" : "no")")
        print("")
        print("Presented chain (leaf first):")
        for (index, cert) in evaluation.certificates.enumerated() {
            let role = index == 0 ? "leaf" : (cert.isSelfSigned ? "root" : "intermediate")
            print("  [\(index)] \(cert.subject) (\(role))")
            print("      sha256 \(cert.sha256Fingerprint)")
        }

        if case .locallyTrustedInspection = verdict {
            print("")
            print("Toolchains that ignore the macOS trust store need the inspection CA explicitly:")
            print("  pm-tls-check \(options.host) --export-pem inspection-ca.pem")
            print("  export NODE_EXTRA_CA_CERTS=$PWD/inspection-ca.pem   # Node.js")
            print("  export REQUESTS_CA_BUNDLE=$PWD/inspection-ca.pem    # Python requests")
            print("  curl --cacert inspection-ca.pem https://…           # curl")
        }
        if case .untrusted(let vendor) = verdict, vendor != nil {
            print("")
            print("An inspection product is on-path but its root CA is not installed on this Mac.")
            print("Ask IT for the root certificate, or capture it with --export-pem and verify its fingerprint with IT before trusting it.")
        }
    }

    private static func reportJSON(
        evaluation: TLSChainEvaluation,
        verdict: TLSInspectionVerdict,
        options: Options
    ) {
        var verdictName: String
        var vendor: String?
        switch verdict {
        case .publiclyTrusted:
            verdictName = "publicly_trusted"
        case .locallyTrustedInspection(let v):
            verdictName = "locally_trusted_inspection"
            vendor = v
        case .untrusted(let v):
            verdictName = "untrusted"
            vendor = v
        }
        var object: [String: Any] = [
            "host": options.host,
            "port": Int(options.port),
            "verdict": verdictName,
            "trustedOnThisMac": evaluation.trustedOnThisMac,
            "trustedBySystemStoreOnly": evaluation.trustedBySystemStoreOnly,
            "chain": evaluation.certificates.map { cert in
                [
                    "subject": cert.subject,
                    "sha256": cert.sha256Fingerprint,
                    "selfSigned": cert.isSelfSigned,
                ] as [String: Any]
            },
        ]
        if let vendor { object["vendor"] = vendor }
        if let proxyHost = options.proxyHost {
            object["proxy"] = "\(proxyHost):\(options.proxyPort)"
        }
        if let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            print(text)
        }
    }

    private static func exportPEM(
        evaluation: TLSChainEvaluation,
        chain: [SecCertificate],
        to path: String
    ) {
        let candidates = TLSInspectionDiagnostics.exportCandidates(evaluation: evaluation)
        guard !candidates.isEmpty else {
            print("")
            print("Nothing to export: the chain is publicly trusted; no locally installed CA is involved.")
            return
        }
        // Match summaries back to SecCertificates by fingerprint.
        let summaries = chain.map(TLSInspectionDiagnostics.summarize(certificate:))
        var pem = ""
        for (certificate, summary) in zip(chain, summaries)
        where candidates.contains(summary) {
            pem += "# \(summary.subject)\n# sha256 \(summary.sha256Fingerprint)\n"
            pem += TLSInspectionDiagnostics.pemEncode(SecCertificateCopyData(certificate) as Data)
        }
        let url = URL(fileURLWithPath: path)
        do {
            try Data(pem.utf8).write(to: url, options: .atomic)
            print("")
            print("Wrote \(candidates.count) certificate(s) to \(path).")
            print("Verify the fingerprint(s) with IT before pointing toolchains at this file.")
        } catch {
            FileHandle.standardError.write(Data("pm-tls-check: could not write \(path): \(error.localizedDescription)\n".utf8))
        }
    }

    // MARK: - Args

    private static func parseOptions() -> Options? {
        var args = Array(CommandLine.arguments.dropFirst())
        guard !args.isEmpty, args[0] != "--help", args[0] != "-h" else { return nil }

        var target = args.removeFirst()
        if target.hasPrefix("https://"), let url = URL(string: target), let host = url.host {
            target = url.port.map { "\(host):\($0)" } ?? host
        }
        var options: Options
        if let colon = target.lastIndex(of: ":"), let port = UInt16(target[target.index(after: colon)...]) {
            options = Options(host: String(target[..<colon]), port: port)
        } else {
            options = Options(host: target)
        }

        var index = 0
        while index < args.count {
            let arg = args[index]
            func value() -> String? {
                index += 1
                return index < args.count ? args[index] : nil
            }
            switch arg {
            case "--proxy":
                guard let raw = value() else { return nil }
                if let colon = raw.lastIndex(of: ":"), let port = UInt16(raw[raw.index(after: colon)...]) {
                    options.proxyHost = String(raw[..<colon])
                    options.proxyPort = port
                } else {
                    options.proxyHost = raw
                }
            case "--export-pem":
                guard let path = value() else { return nil }
                options.exportPEMPath = path
            case "--json":
                options.json = true
            case "--timeout":
                guard let raw = value(), let seconds = Int(raw), seconds > 0 else { return nil }
                options.timeoutSeconds = seconds
            default:
                return nil
            }
            index += 1
        }
        return options
    }

    private static func printUsage() {
        print("""
        pm-tls-check — detect TLS inspection and export the inspection CA

        Usage:
          pm-tls-check <host[:port]> [options]

        Options:
          --proxy <host:port>   Tunnel via an HTTP CONNECT proxy (e.g. Conduit's
                                local proxy, 127.0.0.1:3128) to see what proxied
                                tools actually see.
          --export-pem <path>   Write the locally-installed CA certificate(s) as PEM
                                for NODE_EXTRA_CA_CERTS / REQUESTS_CA_BUNDLE / --cacert.
          --json                Machine-readable output.
          --timeout <seconds>   Connect/handshake timeout (default 10).

        Exit codes: 0 publicly trusted · 3 inspection detected · 4 untrusted chain
        """)
    }
}
