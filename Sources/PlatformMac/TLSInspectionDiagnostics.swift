// SPDX-License-Identifier: Apache-2.0
// TLS-inspection diagnostics.
//
// Every SASE/corporate-inspection deployment MITMs TLS with a locally
// installed root CA, and the recurring developer pain is discovering that
// fact and wiring the CA into toolchains (`NODE_EXTRA_CA_CERTS`,
// `REQUESTS_CA_BUNDLE`, java keystores…). This module classifies a captured
// server chain:
//
//   publicly trusted   — root chains to the OS-shipped trust store: no
//                        interception on this path.
//   locally trusted    — the chain validates on THIS Mac but not against
//                        the OS store alone: a user/admin/MDM-installed
//                        root is vouching, i.e. TLS inspection (or a
//                        private corporate CA).
//   untrusted          — validates nowhere; inspection root not installed,
//                        captive portal, or a genuinely bad certificate.
//
// The classification core is pure (`verdict(for:)`, `vendorHint(in:)`,
// `pemEncode(_:)`) so it is unit-testable without certificates; the
// SecTrust bridging lives in `evaluate(trust:host:)`.

import CryptoKit
import Foundation
import Security

package struct TLSCertificateSummary: Sendable, Equatable {
    package let subject: String
    package let sha256Fingerprint: String
    package let isSelfSigned: Bool

    package init(subject: String, sha256Fingerprint: String, isSelfSigned: Bool) {
        self.subject = subject
        self.sha256Fingerprint = sha256Fingerprint
        self.isSelfSigned = isSelfSigned
    }
}

package struct TLSChainEvaluation: Sendable, Equatable {
    package let certificates: [TLSCertificateSummary]
    /// Default evaluation: OS store + user/admin/MDM-installed anchors.
    package let trustedOnThisMac: Bool
    /// Evaluation pinned to the OS-shipped anchors only.
    package let trustedBySystemStoreOnly: Bool

    package init(
        certificates: [TLSCertificateSummary],
        trustedOnThisMac: Bool,
        trustedBySystemStoreOnly: Bool
    ) {
        self.certificates = certificates
        self.trustedOnThisMac = trustedOnThisMac
        self.trustedBySystemStoreOnly = trustedBySystemStoreOnly
    }
}

package enum TLSInspectionVerdict: Equatable, Sendable {
    /// Chain anchors in the OS trust store — no interception on this path.
    case publiclyTrusted
    /// Chain anchors in a locally installed root — TLS inspection or a
    /// private corporate CA. `vendor` is a best-effort product hint.
    case locallyTrustedInspection(vendor: String?)
    /// Chain validates nowhere on this machine.
    case untrusted(vendor: String?)

    package var headline: String {
        switch self {
        case .publiclyTrusted:
            return "publicly trusted — no TLS inspection detected on this path"
        case .locallyTrustedInspection(let vendor):
            let by = vendor.map { " by \($0)" } ?? ""
            return "TLS inspection detected\(by) — chain anchors in a locally installed root, not the OS trust store"
        case .untrusted(let vendor):
            if let vendor {
                return "untrusted inspection chain (looks like \(vendor)) — the inspection root is not installed on this Mac"
            }
            return "chain is not trusted on this Mac — inspection root missing, captive portal, or a bad certificate"
        }
    }
}

package enum TLSInspectionDiagnostics {

    // MARK: - Pure classification

    package static func verdict(for evaluation: TLSChainEvaluation) -> TLSInspectionVerdict {
        let vendor = vendorHint(in: evaluation.certificates)
        if evaluation.trustedBySystemStoreOnly {
            // A public chain that ALSO carries an inspection-vendor name
            // does not exist in practice; system-store trust wins.
            return .publiclyTrusted
        }
        if evaluation.trustedOnThisMac {
            return .locallyTrustedInspection(vendor: vendor)
        }
        return .untrusted(vendor: vendor)
    }

    /// Known inspection-product fingerprints in certificate subjects.
    /// Matching is substring + case-insensitive; first hit wins, ordered
    /// roughly by deployment prevalence.
    package static let knownVendorMarkers: [(marker: String, vendor: String)] = [
        ("zscaler", "Zscaler"),
        ("netskope", "Netskope"),
        ("bluecoat", "Blue Coat / Symantec ProxySG"),
        ("blue coat", "Blue Coat / Symantec ProxySG"),
        ("forcepoint", "Forcepoint"),
        ("websense", "Forcepoint (Websense)"),
        ("palo alto", "Palo Alto Networks"),
        ("paloalto", "Palo Alto Networks"),
        ("fortigate", "Fortinet FortiGate"),
        ("fortinet", "Fortinet"),
        ("cisco umbrella", "Cisco Umbrella"),
        ("mcafee web gateway", "Skyhigh (McAfee) Web Gateway"),
        ("skyhigh", "Skyhigh Security"),
        ("sophos", "Sophos"),
        ("check point", "Check Point"),
        ("checkpoint", "Check Point"),
        ("watchguard", "WatchGuard"),
        ("mitmproxy", "mitmproxy"),
        ("charles proxy", "Charles Proxy"),
        ("burp", "Burp Suite"),
        ("cloudflare gateway", "Cloudflare Gateway"),
    ]

    package static func vendorHint(in certificates: [TLSCertificateSummary]) -> String? {
        for cert in certificates {
            let subject = cert.subject.lowercased()
            for (marker, vendor) in knownVendorMarkers where subject.contains(marker) {
                return vendor
            }
        }
        return nil
    }

    /// The certificates worth exporting for toolchain trust: everything
    /// that is plausibly a locally-installed CA (self-signed roots, and —
    /// when the chain is not publicly trusted — any non-leaf issuer).
    /// For a publicly trusted chain there is nothing to export.
    package static func exportCandidates(
        evaluation: TLSChainEvaluation
    ) -> [TLSCertificateSummary] {
        guard !evaluation.trustedBySystemStoreOnly else { return [] }
        guard evaluation.certificates.count > 1 else {
            return evaluation.certificates.filter(\.isSelfSigned)
        }
        return Array(evaluation.certificates.dropFirst())
    }

    package static func pemEncode(_ der: Data) -> String {
        let base64 = der.base64EncodedString()
        var lines: [String] = ["-----BEGIN CERTIFICATE-----"]
        var index = base64.startIndex
        while index < base64.endIndex {
            let end = base64.index(index, offsetBy: 64, limitedBy: base64.endIndex) ?? base64.endIndex
            lines.append(String(base64[index..<end]))
            index = end
        }
        lines.append("-----END CERTIFICATE-----")
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - SecTrust bridging

    /// Summarize and doubly-evaluate a captured server trust.
    /// `host` rebuilds the SSL policy for the system-store-only evaluation.
    package static func evaluate(trust: SecTrust, host: String) -> TLSChainEvaluation {
        let chain = certificateChain(of: trust)
        let summaries = chain.map(summarize(certificate:))

        var defaultError: CFError?
        let trustedDefault = SecTrustEvaluateWithError(trust, &defaultError)

        let trustedSystemOnly = evaluateAgainstSystemStoreOnly(chain: chain, host: host)

        return TLSChainEvaluation(
            certificates: summaries,
            trustedOnThisMac: trustedDefault,
            trustedBySystemStoreOnly: trustedSystemOnly
        )
    }

    package static func certificateChain(of trust: SecTrust) -> [SecCertificate] {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate] else {
            return []
        }
        return chain
    }

    package static func summarize(certificate: SecCertificate) -> TLSCertificateSummary {
        let subject = (SecCertificateCopySubjectSummary(certificate) as String?) ?? "<unreadable subject>"
        let der = SecCertificateCopyData(certificate) as Data
        let fingerprint = SHA256.hash(data: der)
            .map { String(format: "%02X", $0) }
            .joined(separator: ":")
        let selfSigned: Bool
        if let subjectSeq = SecCertificateCopyNormalizedSubjectSequence(certificate) as Data?,
           let issuerSeq = SecCertificateCopyNormalizedIssuerSequence(certificate) as Data? {
            selfSigned = subjectSeq == issuerSeq
        } else {
            selfSigned = false
        }
        return TLSCertificateSummary(
            subject: subject,
            sha256Fingerprint: fingerprint,
            isSelfSigned: selfSigned
        )
    }

    private static func evaluateAgainstSystemStoreOnly(chain: [SecCertificate], host: String) -> Bool {
        guard !chain.isEmpty else { return false }

        var systemAnchors: CFArray?
        guard SecTrustCopyAnchorCertificates(&systemAnchors) == errSecSuccess,
              let anchors = systemAnchors else {
            return false
        }

        let policy = SecPolicyCreateSSL(true, host as CFString)
        var rebuilt: SecTrust?
        guard SecTrustCreateWithCertificates(chain as CFArray, policy, &rebuilt) == errSecSuccess,
              let systemTrust = rebuilt else {
            return false
        }
        guard SecTrustSetAnchorCertificates(systemTrust, anchors) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(systemTrust, true) == errSecSuccess else {
            return false
        }
        var error: CFError?
        return SecTrustEvaluateWithError(systemTrust, &error)
    }
}
