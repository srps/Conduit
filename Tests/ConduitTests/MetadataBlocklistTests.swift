// SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import ProxyKernel

final class MetadataBlocklistTests: XCTestCase {

    // MARK: - Gateway mode ON

    func testBlocksCloudMetadataIPv4() {
        XCTAssertTrue(MetadataBlocklist.isBlocked(host: "169.254.169.254", gatewayMode: true))
    }

    func testBlocksLinkLocalIPv4() {
        XCTAssertTrue(MetadataBlocklist.isBlocked(host: "169.254.1.1", gatewayMode: true))
    }

    func testBlocksLoopbackIPv4() {
        XCTAssertTrue(MetadataBlocklist.isBlocked(host: "127.0.0.1", gatewayMode: true))
    }

    func testBlocksAlternateLoopbackIPv4Forms() {
        XCTAssertTrue(MetadataBlocklist.isBlocked(host: "127.1", gatewayMode: true))
        XCTAssertTrue(MetadataBlocklist.isBlocked(host: "2130706433", gatewayMode: true))
        XCTAssertTrue(MetadataBlocklist.isBlocked(host: "0x7f000001", gatewayMode: true))
        XCTAssertTrue(MetadataBlocklist.isBlocked(host: "017700000001", gatewayMode: true))
    }

    func testBlocksAlternateMetadataIPv4Forms() {
        XCTAssertTrue(MetadataBlocklist.isBlocked(host: "2852039166", gatewayMode: true))
    }

    func testBlocksLocalhost() {
        XCTAssertTrue(MetadataBlocklist.isBlocked(host: "localhost", gatewayMode: true))
    }

    func testBlocksIPv6Loopback() {
        XCTAssertTrue(MetadataBlocklist.isBlocked(host: "::1", gatewayMode: true))
    }

    func testBlocksIPv4MappedIPv6Loopback() {
        XCTAssertTrue(MetadataBlocklist.isBlocked(host: "::ffff:127.0.0.1", gatewayMode: true))
        XCTAssertTrue(MetadataBlocklist.isBlocked(host: "0:0:0:0:0:ffff:127.0.0.1", gatewayMode: true))
        XCTAssertTrue(MetadataBlocklist.isBlocked(host: "::FFFF:7f00:0001", gatewayMode: true))
    }

    func testBlocksIPv4MappedIPv6MetadataAddress() {
        XCTAssertTrue(MetadataBlocklist.isBlocked(host: "::ffff:169.254.169.254", gatewayMode: true))
    }

    func testBlocksIPv4CompatibleIPv6DangerousAddresses() {
        XCTAssertTrue(MetadataBlocklist.isBlocked(host: "::127.0.0.1", gatewayMode: true))
        XCTAssertTrue(MetadataBlocklist.isBlocked(host: "::169.254.169.254", gatewayMode: true))
    }

    func testBlocksBracketedIPv6Loopback() {
        XCTAssertTrue(MetadataBlocklist.isBlocked(host: "[::1]", gatewayMode: true))
    }

    func testBlocksFe80LinkLocal() {
        XCTAssertTrue(MetadataBlocklist.isBlocked(host: "fe80::1", gatewayMode: true))
        XCTAssertTrue(MetadataBlocklist.isBlocked(host: "FE80:0:0:0:0:0:0:1", gatewayMode: true))
        XCTAssertTrue(MetadataBlocklist.isBlocked(host: "fe80::1%lo0", gatewayMode: true))
    }

    func testBlocksFd00UniqueLocal() {
        XCTAssertTrue(MetadataBlocklist.isBlocked(host: "fd00::abcd", gatewayMode: true))
        XCTAssertTrue(MetadataBlocklist.isBlocked(host: "fc00::abcd", gatewayMode: true))
    }

    func testAllowsNormalHostInGateway() {
        XCTAssertFalse(MetadataBlocklist.isBlocked(host: "example.com", gatewayMode: true))
    }

    func testAllowsPublicIPInGateway() {
        XCTAssertFalse(MetadataBlocklist.isBlocked(host: "8.8.8.8", gatewayMode: true))
    }

    func testAllowsPrivateRFC1918InGateway() {
        XCTAssertFalse(MetadataBlocklist.isBlocked(host: "10.0.0.1", gatewayMode: true))
        XCTAssertFalse(MetadataBlocklist.isBlocked(host: "192.168.1.1", gatewayMode: true))
    }

    // MARK: - Resolved-address recheck (DNS-rebinding guard)

    func testResolvedAddressBlocksMetadataAndLoopbackInGateway() {
        XCTAssertTrue(MetadataBlocklist.isBlockedResolvedAddress("169.254.169.254", gatewayMode: true))
        XCTAssertTrue(MetadataBlocklist.isBlockedResolvedAddress("127.0.0.1", gatewayMode: true))
        XCTAssertTrue(MetadataBlocklist.isBlockedResolvedAddress("::1", gatewayMode: true))
        XCTAssertTrue(MetadataBlocklist.isBlockedResolvedAddress("fe80::1", gatewayMode: true))
    }

    func testResolvedAddressAllowsPublicAndPrivateInGateway() {
        // Public and RFC-1918 destinations remain reachable (corporate internal use).
        XCTAssertFalse(MetadataBlocklist.isBlockedResolvedAddress("8.8.8.8", gatewayMode: true))
        XCTAssertFalse(MetadataBlocklist.isBlockedResolvedAddress("10.0.0.5", gatewayMode: true))
    }

    func testResolvedAddressNeverBlocksOutsideGateway() {
        // Non-gateway mode is the local user's own proxy; loopback is legitimate.
        XCTAssertFalse(MetadataBlocklist.isBlockedResolvedAddress("169.254.169.254", gatewayMode: false))
        XCTAssertFalse(MetadataBlocklist.isBlockedResolvedAddress("127.0.0.1", gatewayMode: false))
    }

    // MARK: - Cloud metadata hostnames

    func testBlocksGoogleMetadata() {
        XCTAssertTrue(MetadataBlocklist.isBlocked(host: "metadata.google.internal", gatewayMode: true))
    }

    func testBlocksAzureMetadata() {
        XCTAssertTrue(MetadataBlocklist.isBlocked(host: "metadata.azure.com", gatewayMode: true))
    }

    func testBlocksAzureAPIMetadata() {
        XCTAssertTrue(MetadataBlocklist.isBlocked(host: "metadata.azure-api.net", gatewayMode: true))
    }

    func testBlocksCaseInsensitiveMetadataHostname() {
        XCTAssertTrue(MetadataBlocklist.isBlocked(host: "Metadata.Google.Internal", gatewayMode: true))
    }

    // MARK: - Gateway mode OFF

    func testNeverBlocksWhenNotGateway() {
        XCTAssertFalse(MetadataBlocklist.isBlocked(host: "169.254.169.254", gatewayMode: false))
        XCTAssertFalse(MetadataBlocklist.isBlocked(host: "127.0.0.1", gatewayMode: false))
        XCTAssertFalse(MetadataBlocklist.isBlocked(host: "::1", gatewayMode: false))
        XCTAssertFalse(MetadataBlocklist.isBlocked(host: "localhost", gatewayMode: false))
        XCTAssertFalse(MetadataBlocklist.isBlocked(host: "fe80::1", gatewayMode: false))
    }
}
