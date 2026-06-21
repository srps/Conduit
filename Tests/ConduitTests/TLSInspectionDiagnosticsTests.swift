// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import PlatformMac

final class TLSInspectionDiagnosticsTests: XCTestCase {

    private func cert(_ subject: String, selfSigned: Bool = false) -> TLSCertificateSummary {
        TLSCertificateSummary(
            subject: subject,
            sha256Fingerprint: "AA:BB",
            isSelfSigned: selfSigned
        )
    }

    // MARK: - Verdict

    func testSystemStoreTrustIsPubliclyTrusted() {
        let evaluation = TLSChainEvaluation(
            certificates: [cert("github.com"), cert("Sectigo RSA"), cert("USERTrust RSA", selfSigned: true)],
            trustedOnThisMac: true,
            trustedBySystemStoreOnly: true
        )
        XCTAssertEqual(TLSInspectionDiagnostics.verdict(for: evaluation), .publiclyTrusted)
    }

    func testLocallyTrustedOnlyIsInspection() {
        let evaluation = TLSChainEvaluation(
            certificates: [cert("github.com"), cert("Zscaler Intermediate Root CA"), cert("Zscaler Root CA", selfSigned: true)],
            trustedOnThisMac: true,
            trustedBySystemStoreOnly: false
        )
        XCTAssertEqual(
            TLSInspectionDiagnostics.verdict(for: evaluation),
            .locallyTrustedInspection(vendor: "Zscaler")
        )
    }

    func testLocallyTrustedUnknownVendorIsInspectionWithoutVendor() {
        let evaluation = TLSChainEvaluation(
            certificates: [cert("internal.corp"), cert("Corp Issuing CA 01"), cert("Corp Root CA", selfSigned: true)],
            trustedOnThisMac: true,
            trustedBySystemStoreOnly: false
        )
        XCTAssertEqual(
            TLSInspectionDiagnostics.verdict(for: evaluation),
            .locallyTrustedInspection(vendor: nil)
        )
    }

    func testUntrustedKeepsVendorHint() {
        let evaluation = TLSChainEvaluation(
            certificates: [cert("github.com"), cert("Netskope Certificate Authority", selfSigned: true)],
            trustedOnThisMac: false,
            trustedBySystemStoreOnly: false
        )
        XCTAssertEqual(
            TLSInspectionDiagnostics.verdict(for: evaluation),
            .untrusted(vendor: "Netskope")
        )
    }

    // MARK: - Vendor hints

    func testVendorHintIsCaseInsensitiveAndScansWholeChain() {
        XCTAssertEqual(
            TLSInspectionDiagnostics.vendorHint(in: [cert("leaf"), cert("ZSCALER ROOT CA")]),
            "Zscaler"
        )
        XCTAssertEqual(
            TLSInspectionDiagnostics.vendorHint(in: [cert("FortiGate CA")]),
            "Fortinet FortiGate"
        )
        XCTAssertNil(TLSInspectionDiagnostics.vendorHint(in: [cert("DigiCert Global Root G2")]))
    }

    // MARK: - Export candidates

    func testNoExportForPubliclyTrustedChain() {
        let evaluation = TLSChainEvaluation(
            certificates: [cert("leaf"), cert("root", selfSigned: true)],
            trustedOnThisMac: true,
            trustedBySystemStoreOnly: true
        )
        XCTAssertTrue(TLSInspectionDiagnostics.exportCandidates(evaluation: evaluation).isEmpty)
    }

    func testExportSkipsLeafButKeepsIssuers() {
        let issuers = [cert("Inspection Issuing CA"), cert("Inspection Root", selfSigned: true)]
        let evaluation = TLSChainEvaluation(
            certificates: [cert("github.com")] + issuers,
            trustedOnThisMac: true,
            trustedBySystemStoreOnly: false
        )
        XCTAssertEqual(TLSInspectionDiagnostics.exportCandidates(evaluation: evaluation), issuers)
    }

    func testSingleSelfSignedCertIsExportable() {
        let root = cert("mitmproxy", selfSigned: true)
        let evaluation = TLSChainEvaluation(
            certificates: [root],
            trustedOnThisMac: false,
            trustedBySystemStoreOnly: false
        )
        XCTAssertEqual(TLSInspectionDiagnostics.exportCandidates(evaluation: evaluation), [root])
    }

    // MARK: - PEM

    func testPEMEncodingShapeAndLineLength() {
        let der = Data((0..<200).map { UInt8($0 % 251) })
        let pem = TLSInspectionDiagnostics.pemEncode(der)
        let lines = pem.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.first, "-----BEGIN CERTIFICATE-----")
        XCTAssertEqual(lines.last, "-----END CERTIFICATE-----")
        let body = lines.dropFirst().dropLast()
        XCTAssertTrue(body.allSatisfy { $0.count <= 64 })
        XCTAssertEqual(Data(base64Encoded: body.joined()), der, "PEM body must round-trip the DER")
        XCTAssertTrue(pem.hasSuffix("\n"))
    }
}
