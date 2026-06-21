// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOPosix
import XCTest
@testable import ProxyKernel

final class LocalPACServerTests: XCTestCase {

    private var group: MultiThreadedEventLoopGroup!

    override func setUp() {
        super.setUp()
        group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    }

    override func tearDown() {
        try? group.syncShutdownGracefully()
        group = nil
        super.tearDown()
    }

    func testGETProxyPACReturnsScriptAndHeaders() async throws {
        try await withServer(script: "function FindProxyForURL() { return \"DIRECT\"; }\n") { server in

            let response = try await request(server: server, path: LocalPACServer.pacPath)

            XCTAssertEqual(response.statusCode, 200)
            XCTAssertEqual(response.body, "function FindProxyForURL() { return \"DIRECT\"; }\n")
            XCTAssertEqual(response.headers["Content-Type"], LocalPACServer.contentType)
            XCTAssertEqual(response.headers["Cache-Control"], "no-store, no-cache, must-revalidate")
            XCTAssertEqual(response.headers["Pragma"], "no-cache")
        }
    }

    func testHEADProxyPACReturnsHeadersWithoutBody() async throws {
        let script = "function FindProxyForURL() { return \"PROXY 127.0.0.1:3128\"; }\n"
        try await withServer(script: script) { server in

            let response = try await request(server: server, path: LocalPACServer.pacPath, method: "HEAD")

            XCTAssertEqual(response.statusCode, 200)
            XCTAssertEqual(response.body, "")
            XCTAssertEqual(response.headers["Content-Type"], LocalPACServer.contentType)
            XCTAssertEqual(response.headers["Content-Length"], "\(Data(script.utf8).count)")
        }
    }

    func testUnknownPathReturnsNotFound() async throws {
        try await withServer(script: "DIRECT") { server in

            let response = try await request(server: server, path: "/missing")

            XCTAssertEqual(response.statusCode, 404)
            XCTAssertEqual(response.body, "Not Found\n")
        }
    }

    func testUnsupportedMethodReturnsMethodNotAllowed() async throws {
        try await withServer(script: "DIRECT") { server in

            let response = try await request(server: server, path: LocalPACServer.pacPath, method: "POST")

            XCTAssertEqual(response.statusCode, 405)
            XCTAssertEqual(response.headers["Allow"], "GET, HEAD")
        }
    }

    func testScriptUpdateDoesNotRestartListener() async throws {
        try await withServer(script: "first") { server in
            let port = try XCTUnwrap(server.listeningPort)

            server.updateScript("second")
            let response = try await request(server: server, path: LocalPACServer.pacPath)

            XCTAssertEqual(server.listeningPort, port)
            XCTAssertEqual(response.body, "second")
        }
    }

    func testStopThenRestartBindsFreshListener() async throws {
        let server = LocalPACServer(group: group, logger: DiscardingLogSink())
        try await server.start(port: 0, script: "first")
        XCTAssertTrue(server.isRunning)

        await server.stop()
        XCTAssertFalse(server.isRunning)
        XCTAssertNil(server.listeningPort)

        try await server.start(port: 0, script: "second")

        let response = try await request(server: server, path: LocalPACServer.pacPath)
        XCTAssertEqual(response.body, "second")
        await server.stop()
    }

    private struct HTTPResponse {
        var statusCode: Int
        var headers: [String: String]
        var body: String
    }

    private func request(
        server: LocalPACServer,
        path: String,
        method: String = "GET"
    ) async throws -> HTTPResponse {
        let host = try XCTUnwrap(server.listeningHost)
        let port = try XCTUnwrap(server.listeningPort)
        let url = try XCTUnwrap(URL(string: "http://\(host):\(port)\(path)"))
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        let (data, response) = try await session.data(for: request)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            guard let key = key as? String else { continue }
            headers[key] = String(describing: value)
        }
        return HTTPResponse(
            statusCode: http.statusCode,
            headers: headers,
            body: String(decoding: data, as: UTF8.self)
        )
    }

    private func withServer(
        script: String,
        body: (LocalPACServer) async throws -> Void
    ) async throws {
        let server = LocalPACServer(group: group, logger: DiscardingLogSink())
        try await server.start(port: 0, script: script)
        do {
            try await body(server)
            await server.stop()
        } catch {
            await server.stop()
            throw error
        }
    }
}
