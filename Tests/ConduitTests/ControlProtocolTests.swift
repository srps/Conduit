// SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import ProxyControlBridge
@testable import ProxyKernel
import ConduitShared

final class ControlProtocolTests: XCTestCase {
    func testControlRequestRoundTrips() throws {
        let request = ControlRequest(command: .status)

        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(ControlRequest.self, from: data)

        XCTAssertEqual(decoded, request)
        XCTAssertEqual(decoded.protocolVersion, ControlProtocolVersion.current)
    }

    func testUnknownCommandFailsClosedAtDecodeBoundary() {
        let data = #"{"protocolVersion":1,"command":"unknown-command","arguments":[]}"#.data(using: .utf8)!

        XCTAssertThrowsError(try JSONDecoder().decode(ControlRequest.self, from: data))
    }

    func testStopRequestAndOkResponseRoundTrip() throws {
        let request = ControlRequest(command: .stop)
        let requestData = try JSONEncoder().encode(request)
        XCTAssertEqual(try JSONDecoder().decode(ControlRequest.self, from: requestData).command, .stop)

        let response = ControlResponse.ok()
        let responseData = try JSONEncoder().encode(response)
        let decoded = try JSONDecoder().decode(ControlResponse.self, from: responseData)

        XCTAssertEqual(decoded, response)
        XCTAssertTrue(decoded.success)
        XCTAssertNil(decoded.status)
        XCTAssertNil(decoded.errorMessage)
    }

    func testReloadRequestRoundTrips() throws {
        let request = ControlRequest(command: .reload)
        let requestData = try JSONEncoder().encode(request)
        XCTAssertEqual(try JSONDecoder().decode(ControlRequest.self, from: requestData).command, .reload)
    }

    func testStartAndProfileCommandsRoundTrip() throws {
        let start = ControlRequest(command: .start)
        let startData = try JSONEncoder().encode(start)
        XCTAssertEqual(try JSONDecoder().decode(ControlRequest.self, from: startData).command, .start)

        let profile = ControlRequest(command: .setProfile, arguments: ["Work"])
        let profileData = try JSONEncoder().encode(profile)
        let decodedProfile = try JSONDecoder().decode(ControlRequest.self, from: profileData)

        XCTAssertEqual(decodedProfile.command, .setProfile)
        XCTAssertEqual(decodedProfile.arguments, ["Work"])
    }

    func testStableControlErrorCodeRoundTrips() throws {
        let response = ControlResponse.error(.unsupportedVersion, "Unsupported protocol version.")
        let data = try JSONEncoder().encode(response)
        let decoded = try JSONDecoder().decode(ControlResponse.self, from: data)

        XCTAssertFalse(decoded.success)
        XCTAssertEqual(decoded.errorCode, .unsupportedVersion)
        XCTAssertEqual(decoded.errorMessage, "Unsupported protocol version.")
    }

    func testDaemonMetadataRoundTripsOnStatus() throws {
        let metadata = ControlDaemonMetadata(
            processID: 12345,
            executableName: "ConduitDaemon",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let status = ControlDaemonStatus(
            daemon: metadata,
            configGeneration: 1,
            profileName: "Default",
            state: "stopped",
            healthSummary: "Not started",
            directModeCause: "none",
            isDirectMode: false,
            bindings: ControlBindings(),
            metrics: ControlMetrics(
                requestsHandled: 0,
                failedRequests: 0,
                openConnections: 0,
                inboundConnections: 0,
                successfulRecoveries: 0
            ),
            dnsRunState: "stopped",
            dnsQueryCount: 0,
            dnsCacheHitCount: 0,
            tunnelsRunState: "stopped",
            tunnelActiveCount: 0,
            tunnelSessionCount: 0
        )
        let response = ControlResponse.status(status)

        let data = try JSONEncoder().encode(response)
        let decoded = try JSONDecoder().decode(ControlResponse.self, from: data)

        XCTAssertEqual(decoded.status?.daemon, metadata)
        XCTAssertEqual(decoded.status?.configGeneration, 1)
        XCTAssertEqual(decoded.status?.state, "stopped")
    }

    func testDaemonClientRejectsOversizedRequestFrame() throws {
        let request = ControlRequest(command: .setProfile, arguments: [String(repeating: "x", count: 64)])

        XCTAssertThrowsError(try DaemonClient.encodeRequestFrame(request, maxFrameBytes: 16)) { error in
            XCTAssertEqual(error as? DaemonClientError, .requestTooLarge(16))
        }
    }

    func testDiagRequestRoundTrips() throws {
        let request = ControlRequest(command: .diag)
        let requestData = try JSONEncoder().encode(request)
        XCTAssertEqual(try JSONDecoder().decode(ControlRequest.self, from: requestData).command, .diag)
    }

    func testUpstreamTestRequestAndResponseRoundTrip() throws {
        let request = ControlRequest(command: .testUpstream, arguments: ["corp"])
        let requestData = try JSONEncoder().encode(request)
        let decodedRequest = try JSONDecoder().decode(ControlRequest.self, from: requestData)
        XCTAssertEqual(decodedRequest.command, .testUpstream)
        XCTAssertEqual(decodedRequest.arguments, ["corp"])

        let result = ControlUpstreamTestResult(
            name: "corp",
            endpoint: "127.0.0.1:8080",
            reachable: true,
            latencyMS: 3
        )
        let response = ControlResponse.upstreamTest(result)
        let responseData = try JSONEncoder().encode(response)
        let decodedResponse = try JSONDecoder().decode(ControlResponse.self, from: responseData)

        XCTAssertEqual(decodedResponse, response)
        XCTAssertEqual(decodedResponse.upstreamTest, result)
    }

    func testEventsCommandAndRuntimeEventRoundTrip() throws {
        let request = ControlRequest(command: .events)
        let requestData = try JSONEncoder().encode(request)
        XCTAssertEqual(try JSONDecoder().decode(ControlRequest.self, from: requestData).command, .events)

        let event = ControlRuntimeEvent(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            kind: "lifecycle",
            event: "proxy.starting",
            detail: "reason=test"
        )
        let eventData = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(ControlRuntimeEvent.self, from: eventData)

        XCTAssertEqual(decoded, event)
        XCTAssertEqual(decoded.humanDescription, "2023-11-14T22:13:20.000Z [lifecycle] proxy.starting reason=test")
    }

    func testDiagnosticsSanitizesSecretsInJSON() throws {
        let json = """
        {
          "proxyAuthorization": "Negotiate abcdefghijklmnop",
          "safe": "value",
          "url": "https://user:secret@example.com/proxy.pac",
          "nested": {
            "password": "super-secret",
            "header": "Authorization: Bearer abcdefghijklmnop"
          }
        }
        """.data(using: .utf8)!

        let sanitized = try ControlDiagnostics.sanitizedJSONData(from: json)
        let text = String(decoding: sanitized, as: UTF8.self)

        XCTAssertFalse(text.contains("super-secret"))
        XCTAssertFalse(text.contains("abcdefghijklmnop"))
        XCTAssertFalse(text.contains("user:secret"))
        XCTAssertTrue(text.contains("<redacted>"))
        XCTAssertTrue(text.contains("\"safe\" : \"value\""))
    }

    func testDiagnosticsSanitizesEmbeddedCredentialedURLs() {
        let text = "PAC failed for https://user:secret@example.com/proxy.pac after Authorization: Bearer abcdefghijklmnop"

        let sanitized = ControlDiagnostics.sanitizeString(text)

        XCTAssertFalse(sanitized.contains("user:secret"))
        XCTAssertFalse(sanitized.contains("abcdefghijklmnop"))
        XCTAssertTrue(sanitized.contains("https://%3Credacted%3E:%3Credacted%3E@example.com/proxy.pac"))
        XCTAssertTrue(sanitized.contains("Bearer <redacted>"))
    }

    func testSnapshotDiagnosticsRedactsConnectionsErrorsAndHostnames() throws {
        let json = """
        {
          "activeConnections": [
            {
              "destination": "https://secret.internal.example/path",
              "upstream": "proxy.internal.example:8080",
              "method": "CONNECT"
            }
          ],
          "proxyError": "panic stack trace for secret.internal.example",
          "runtimeStatus": {
            "activeUpstream": "Corporate EU",
            "lastHealthSummary": "failed against proxy.internal.example"
          },
          "tunnelDNSOverrideStatus": {
            "kind": "active",
            "hostnames": ["database.internal.example"]
          },
          "upstreamStatuses": [
            {
              "name": "Corporate EU",
              "endpoint": "proxy.internal.example:8080"
            }
          ]
        }
        """.data(using: .utf8)!

        let sanitized = try ControlDiagnostics.sanitizedJSONData(from: json, fileKind: .snapshot)
        let text = String(decoding: sanitized, as: UTF8.self)

        XCTAssertFalse(text.contains("secret.internal.example"))
        XCTAssertFalse(text.contains("proxy.internal.example"))
        XCTAssertFalse(text.contains("database.internal.example"))
        XCTAssertFalse(text.contains("panic stack trace"))
        XCTAssertTrue(text.contains("\"activeConnections\" : {"))
        XCTAssertTrue(text.contains("\"count\" : 1"))
        XCTAssertTrue(text.contains("\"redacted\" : true"))
    }

    func testConfigDiagnosticsRedactsInfrastructureIdentifiers() throws {
        let json = """
        {
          "profileName": "Corp Sensitive Profile",
          "username": "alice",
          "domain": "CORP",
          "workstation": "alice-macbook",
          "pacURL": "https://pac.internal.example/proxy.pac",
          "upstreams": [
            {
              "name": "Primary",
              "host": "proxy.internal.example",
              "port": 8080
            }
          ],
          "dnsEntries": [
            {
              "domain": "secret.internal.example",
              "servers": ["10.0.0.53"]
            }
          ],
          "tunnelDefinitions": [
            {
              "remoteHost": "database.internal.example",
              "remotePort": 5432
            }
          ],
          "maxConnections": 200
        }
        """.data(using: .utf8)!

        let sanitized = try ControlDiagnostics.sanitizedJSONData(from: json, fileKind: .config)
        let text = String(decoding: sanitized, as: UTF8.self)

        XCTAssertFalse(text.contains("Corp Sensitive Profile"))
        XCTAssertFalse(text.contains("alice"))
        XCTAssertFalse(text.contains("CORP"))
        XCTAssertFalse(text.contains("alice-macbook"))
        XCTAssertFalse(text.contains("pac.internal.example"))
        XCTAssertFalse(text.contains("proxy.internal.example"))
        XCTAssertFalse(text.contains("secret.internal.example"))
        XCTAssertFalse(text.contains("database.internal.example"))
        XCTAssertTrue(text.contains("\"maxConnections\" : 200"))
    }

    func testPreferencesDiagnosticsRedactsBrowserTestURL() throws {
        let json = """
        {
          "preferredBrowserTestURL": "https://sensitive.internal.example/health",
          "showMenuBarIcon": true
        }
        """.data(using: .utf8)!

        let sanitized = try ControlDiagnostics.sanitizedJSONData(from: json, fileKind: .preferences)
        let text = String(decoding: sanitized, as: UTF8.self)

        XCTAssertFalse(text.contains("sensitive.internal.example"))
        XCTAssertTrue(text.contains("\"preferredBrowserTestURL\" : \"<redacted>\""))
        XCTAssertTrue(text.contains("\"showMenuBarIcon\" : true"))
    }

    func testEventDiagnosticsRedactsDetailsButKeepsEventCode() throws {
        let json = """
        {
          "timestamp": "2026-05-05T08:00:00Z",
          "kind": "health",
          "event": "proxy.failed",
          "detail": "failed against secret.internal.example"
        }
        """.data(using: .utf8)!

        let sanitized = try ControlDiagnostics.sanitizedJSONData(from: json, fileKind: .events)
        let text = String(decoding: sanitized, as: UTF8.self)

        XCTAssertFalse(text.contains("secret.internal.example"))
        XCTAssertTrue(text.contains("\"event\" : \"proxy.failed\""))
        XCTAssertTrue(text.contains("\"detail\" : \"<redacted>\""))
    }

    func testManifestDiagnosticsRedactsStateDirectory() throws {
        let json = """
        {
          "stateDirectory": "/Users/alice/Library/Application Support/Conduit",
          "tool": "pmctl diag"
        }
        """.data(using: .utf8)!

        let sanitized = try ControlDiagnostics.sanitizedJSONData(from: json, fileKind: .manifest)
        let text = String(decoding: sanitized, as: UTF8.self)

        XCTAssertFalse(text.contains("/Users/alice"))
        XCTAssertTrue(text.contains("\"stateDirectory\" : \"<redacted>\""))
        XCTAssertTrue(text.contains("\"tool\" : \"pmctl diag\""))
    }

    func testControlResponseRoundTripsStatusPayload() throws {
        let status = ControlDaemonStatus(
            daemon: ControlDaemonMetadata(
                processID: 123,
                executableName: "ConduitDaemon",
                startedAt: Date(timeIntervalSince1970: 1_700_000_000)
            ),
            configGeneration: 7,
            profileName: "Default",
            state: "running",
            activeUpstream: "DIRECT",
            healthSummary: "Healthy",
            directModeCause: "none",
            isDirectMode: false,
            bindings: ControlBindings(proxyHost: "127.0.0.1", proxyPort: 3128),
            metrics: ControlMetrics(
                requestsHandled: 12,
                failedRequests: 1,
                openConnections: 2,
                inboundConnections: 3,
                successfulRecoveries: 4
            ),
            dnsRunState: "stopped",
            dnsQueryCount: 0,
            dnsCacheHitCount: 0,
            tunnelsRunState: "stopped",
            tunnelActiveCount: 0,
            tunnelSessionCount: 0
        )

        let response = ControlResponse.status(status)
        let data = try JSONEncoder().encode(response)
        let decoded = try JSONDecoder().decode(ControlResponse.self, from: data)

        XCTAssertEqual(decoded, response)
        XCTAssertTrue(decoded.success)
        XCTAssertEqual(decoded.status?.daemon?.executableName, "ConduitDaemon")
        XCTAssertEqual(decoded.status?.configGeneration, 7)
        XCTAssertEqual(decoded.status?.bindings.proxyPort, 3128)
    }

    func testStatusDecodingDefaultsMissingDaemonMetadata() throws {
        let json = """
        {
          "profileName": "Default",
          "state": "running",
          "healthSummary": "Healthy",
          "directModeCause": "none",
          "isDirectMode": false,
          "bindings": {},
          "metrics": {
            "requestsHandled": 0,
            "failedRequests": 0,
            "openConnections": 0,
            "inboundConnections": 0,
            "successfulRecoveries": 0
          },
          "dnsRunState": "stopped",
          "dnsQueryCount": 0,
          "dnsCacheHitCount": 0,
          "tunnelsRunState": "stopped",
          "tunnelActiveCount": 0,
          "tunnelSessionCount": 0
        }
        """.data(using: .utf8)!

        let status = try JSONDecoder().decode(ControlDaemonStatus.self, from: json)

        XCTAssertNil(status.daemon)
        XCTAssertEqual(status.configGeneration, 0)
    }

    func testStatusMappingUsesSnapshotAndConfigFields() {
        let snapshot = ProxyOrchestratorSnapshot(
            runtimeStatus: ProxyRuntimeStatus(
                state: .running,
                activeUpstream: "corp-proxy",
                lastHealthSummary: "Healthy (12 ms)",
                metrics: ProxyMetrics(
                    requestsHandled: 12,
                    successfulRecoveries: 1,
                    failedRequests: 2,
                    openConnections: 3,
                    inboundConnections: 4
                )
            ),
            directModeCause: .upstreamsUnreachable,
            dnsRunState: .warning,
            dnsQueryCount: 42,
            dnsCacheHitCount: 7,
            tunnelsRunState: .running,
            tunnelActiveCount: 2,
            tunnelSessionCount: 5,
            bindings: ProxyOrchestratorBindings(
                proxyHost: "127.0.0.1",
                proxyPort: 3128,
                socksHost: "127.0.0.1",
                socksPort: 1080,
                dnsHost: "127.0.0.1",
                dnsPort: 5053
            ),
            lastAuthOutcome: .ntlmFallback,
            lastAuthFallbackReason: "no_credential"
        )
        let config = ProxyConfig(profileName: "Work")

        let status = ControlDaemonStatus(snapshot: snapshot, config: config)

        XCTAssertEqual(status.profileName, "Work")
        XCTAssertEqual(status.state, "running")
        XCTAssertEqual(status.activeUpstream, "corp-proxy")
        XCTAssertEqual(status.directModeCause, "upstreamsUnreachable")
        XCTAssertTrue(status.isDirectMode)
        XCTAssertEqual(status.bindings.proxyPort, 3128)
        XCTAssertEqual(status.metrics.requestsHandled, 12)
        XCTAssertEqual(status.dnsRunState, "warning")
        XCTAssertEqual(status.tunnelsRunState, "running")
        XCTAssertEqual(status.lastAuthOutcome, "ntlmFallback")
        XCTAssertEqual(status.lastAuthFallbackReason, "no_credential")
    }
}
