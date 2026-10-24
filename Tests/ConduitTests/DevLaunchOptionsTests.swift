// SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import Conduit
@testable import PlatformMac
@testable import ProxyKernel

/// The `--dev` flag parser, the dev bundle's identity and the state isolation
/// (#23). The composition the parser feeds is the harness's and is covered in
/// `AppStateHarnessTests`; this pins the flags an agent types, the refusals, and
/// the directories a dev instance may not reach, since a flag silently ignored
/// is a screenshot of the wrong state.
final class DevLaunchOptionsTests: XCTestCase {
    private let scratch = URL(fileURLWithPath: "/tmp/conduit-dev-test", isDirectory: true)
    private let devBundle = DevLaunchOptions.devBundleIdentifier
    private var root: URL!

    /// Stands in for the installed app's directories, so the tests never read
    /// the real ones.
    private var installed: URL { root.appendingPathComponent("Application Support/Conduit", isDirectory: true) }
    private var installedLogs: URL { root.appendingPathComponent("Logs/Conduit", isDirectory: true) }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("conduit-dev-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: installed, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: installedLogs, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    private func parse(
        _ args: [String],
        bundle: String? = nil,
        debug: Bool = true
    ) throws -> DevLaunchOptions? {
        try DevLaunchOptions.parse(
            ["Conduit"] + args,
            bundleIdentifier: bundle,
            isDebugBuild: debug,
            defaultStateDirectory: scratch,
            protectedDirectories: [installed, installedLogs]
        )
    }

    func testWithoutTheFlagTheLaunchIsProduction() throws {
        XCTAssertNil(try parse([]))
        XCTAssertNil(try parse(["--port", "3129", "--no-system-proxy", "--no-env"]),
                     "the production flags are AppState's and pass through")
    }

    func testTheFlagAloneTakesTheDefaults() throws {
        let options = try XCTUnwrap(try parse(["--dev"]))
        XCTAssertEqual(options, DevLaunchOptions(stateDirectory: scratch))
    }

    func testEveryFlagLands() throws {
        let options = try XCTUnwrap(try parse([
            "--dev", "--dev-state-dir", "/tmp/elsewhere", "--section", "dns",
            "--vpn", "utun4", "--upstream", "127.0.0.1:3129", "--port", "0",
        ]))
        XCTAssertEqual(options.stateDirectory.path, "/tmp/elsewhere")
        XCTAssertEqual(options.section, .dns)
        XCTAssertEqual(options.vpn, .connected)
        XCTAssertEqual(options.vpnInterfaceName, "utun4")
        XCTAssertEqual(options.upstream, DevLaunchOptions.Endpoint(host: "127.0.0.1", port: 3129))
    }

    func testVPNOffReportsDisconnectedWithNoInterface() throws {
        let options = try XCTUnwrap(try parse(["--dev", "--vpn", "off"]))
        XCTAssertEqual(options.vpn, .disconnected(reason: .userInitiated))
        XCTAssertNil(options.vpnInterfaceName)
    }

    func testADevFlagWithoutDevIsRefused() {
        XCTAssertThrowsError(try parse(["--section", "dns"])) { error in
            XCTAssertEqual(error.localizedDescription, "--section needs --dev")
        }
    }

    func testBadValuesAreRefusedByName() {
        XCTAssertThrowsError(try parse(["--dev", "--section", "settings"])) { error in
            XCTAssertTrue(error.localizedDescription.hasPrefix("--section: unknown section settings"))
        }
        XCTAssertThrowsError(try parse(["--dev", "--section"])) { error in
            XCTAssertEqual(error.localizedDescription, "--section needs a value")
        }
        XCTAssertThrowsError(try parse(["--dev", "--vpn", "--section", "dns"])) { error in
            XCTAssertEqual(error.localizedDescription, "--vpn needs a value", "the next flag is not a value")
        }
        XCTAssertThrowsError(try parse(["--dev", "--upstream", "proxy.example"])) { error in
            XCTAssertEqual(error.localizedDescription, "--upstream: expected host:port, got proxy.example")
        }
        XCTAssertThrowsError(try parse(["--dev", "--upstream", "proxy.example:70000"])) { error in
            XCTAssertEqual(error.localizedDescription, "--upstream: port must be 1-65535 in proxy.example:70000")
        }
    }

    func testTheDevBundleIsTheDevInstanceWithoutAnyFlag() throws {
        let options = try XCTUnwrap(try parse([], bundle: devBundle))
        XCTAssertEqual(options, DevLaunchOptions(stateDirectory: scratch))
        let sectioned = try XCTUnwrap(try parse(["--section", "dns"], bundle: devBundle))
        XCTAssertEqual(sectioned.section, .dns, "the dev bundle takes the same flags as --dev")
    }

    func testOnlyTheExactDevIdentifierSelectsTheDevInstance() throws {
        XCTAssertTrue(DevLaunchOptions.isDevBundle("io.github.srps.Conduit.dev"))
        XCTAssertFalse(DevLaunchOptions.isDevBundle(nil))
        for identifier in [
            "io.github.srps.Conduit", "io.github.srps.Conduit.development", "io.github.srps.Conduit.Dev",
            "io.github.srps.Conduit.dev.Helper", "io.github.srps.Conduit.dev.Updater", "",
        ] {
            XCTAssertFalse(DevLaunchOptions.isDevBundle(identifier), identifier)
            XCTAssertNil(try parse([], bundle: identifier), "\(identifier) runs the production composition")
        }
    }

    func testTheRequestIsMadeByFlagOrByBundle() {
        XCTAssertTrue(DevLaunchOptions.requested(by: ["Conduit", "--dev"], bundleIdentifier: nil))
        XCTAssertTrue(DevLaunchOptions.requested(by: ["Conduit"], bundleIdentifier: devBundle))
        XCTAssertFalse(DevLaunchOptions.requested(by: ["Conduit"], bundleIdentifier: "io.github.srps.Conduit"))
    }

    /// The worker gate runs before any worker, so it is pinned by its inputs.
    /// The flag and the bundle each refuse a worker mode on their own, a
    /// production launch keeps its workers, and a dev launch with no worker
    /// argument is not refused. The gate takes no build flag, so this holds in
    /// a release build too.
    func testADevRequestRefusesTheWorkerModesByFlagOrByBundle() {
        for worker in [UpdateHelperPreflightWorker.argument, KerberosTicketRecoveryReply.argument] {
            XCTAssertNotNil(DevLaunch.workerRefusal(arguments: ["Conduit", "--dev", worker], bundleIdentifier: "io.github.srps.Conduit"),
                            "--dev with \(worker)")
            XCTAssertNotNil(DevLaunch.workerRefusal(arguments: ["Conduit", worker], bundleIdentifier: devBundle),
                            "the dev bundle with \(worker)")
            XCTAssertNil(DevLaunch.workerRefusal(arguments: ["Conduit", worker], bundleIdentifier: "io.github.srps.Conduit"),
                         "a production launch keeps \(worker)")
        }
        XCTAssertNil(DevLaunch.workerRefusal(arguments: ["Conduit", "--dev"], bundleIdentifier: devBundle),
                     "a dev launch without a worker runs the composition")
    }

    /// A release build refuses the dev instance, by flag or by bundle, rather
    /// than ignoring it and running the real machine.
    func testAReleaseBuildRefusesTheDevInstanceByFlagOrByBundle() throws {
        XCTAssertThrowsError(try parse(["--dev"], debug: false)) { error in
            XCTAssertEqual(error.localizedDescription, "--dev is available in debug builds only")
        }
        XCTAssertThrowsError(try parse([], bundle: devBundle, debug: false)) { error in
            XCTAssertEqual(error.localizedDescription, "io.github.srps.Conduit.dev is available in debug builds only")
        }
        XCTAssertNil(try parse([], bundle: "io.github.srps.Conduit", debug: false))
    }

    /// `--dev-state-dir` may not reach the installed app's files by its own
    /// spelling, a symlink, a path beneath it, or a parent that holds it, nor
    /// by a dangling link that might later point there.
    func testTheStateDirectoryCannotReachTheInstalledAppsFiles() throws {
        let link = root.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: installed)
        let dangling = root.appendingPathComponent("dangling", isDirectory: true)
        try FileManager.default.createSymbolicLink(
            at: dangling, withDestinationURL: root.appendingPathComponent("nowhere", isDirectory: true)
        )
        let refused = [
            installed.path,
            installed.appendingPathComponent("sub").path,
            installedLogs.path,
            link.path,
            link.appendingPathComponent("inside").path,
            root.path,
            dangling.appendingPathComponent("x").path,
        ]
        for path in refused {
            XCTAssertThrowsError(try parse(["--dev", "--dev-state-dir", path]), path) { error in
                let message = error.localizedDescription
                XCTAssertTrue(message.contains("overlaps") || message.contains("cannot"), "\(path): \(message)")
            }
            XCTAssertThrowsError(try parse(["--dev-state-dir", path], bundle: devBundle), path)
        }
        let allowed = root.appendingPathComponent("other", isDirectory: true)
        let options = try XCTUnwrap(try parse(["--dev", "--dev-state-dir", allowed.path]))
        XCTAssertEqual(options.stateDirectory.path, allowed.path, "a directory that overlaps nothing is kept as written")
    }

    func testTheProductionDirectoriesAreTheInstalledAppsConfigAndLog() {
        let paths = DevLaunchOptions.productionStateDirectories.map(\.path)
        XCTAssertTrue(paths.contains { $0.hasSuffix("/Library/Application Support/Conduit") }, "\(paths)")
        XCTAssertTrue(paths.contains { $0.hasSuffix("/Library/Logs/Conduit") }, "\(paths)")
    }

    /// Polls until `condition` holds, for the edges that have no handle. Bounded,
    /// so a stuck edge fails the test instead of hanging it.
    @MainActor
    private func waitUntil(_ what: String, _ condition: @MainActor () -> Bool) async {
        for _ in 0..<5_000 where !condition() {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertTrue(condition(), "timed out waiting until \(what)")
    }

    #if DEBUG
    /// The dev composition over the fakes, run to quiescence. Launch recovery is
    /// joined, a helper install is counted by the fake helper the session holds,
    /// and termination is awaited until the runtime and DNS report stopped and
    /// observer deliveries have drained. Only then is the session dropped, so
    /// the static does not outlive this test. Credential and updater paths are
    /// not exercised here: the updater's availability comes from the host
    /// bundle, which a test cannot set without a new seam.
    @MainActor
    func testTheDevCompositionRunsOverTheFakes() async {
        let scratch = root.appendingPathComponent("composition", isDirectory: true)
        let state = DevLaunch.makeAppState(DevLaunchOptions(stateDirectory: scratch))
        defer { DevLaunch.endSession() }
        XCTAssertTrue(DevLaunch.isActive)
        XCTAssertTrue(state.helperLifecycle is FakeHelperLifecycle)
        XCTAssertTrue(FileManager.default.fileExists(atPath: scratch.appendingPathComponent("config.json").path),
                      "the dev state directory holds the dev config, not the installed app's")
        let helper = DevLaunch.session?.helper
        XCTAssertNotNil(helper, "the session keeps the fake helper it was built with")

        await state.awaitLaunchRecovery()
        state.installHelper()
        await waitUntil("the helper install reaches the fake") { helper?.installs == 1 }
        XCTAssertEqual(helper?.installs, 1)
        await state.deliveries.drain()

        state.performTerminationCleanup()
        await state.deliveries.drain()
        await waitUntil("the runtime has shut down") {
            state.runtimeSnapshot.runtimeStatus.state == .stopped
                && state.runtimeSnapshot.dnsRunState == .stopped
        }
    }
    #endif
}
