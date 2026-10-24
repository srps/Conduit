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

    /// The state directory itself is checked, but a runtime file or fake home
    /// beneath it is written through whatever it links to. Each known component
    /// is aliased in turn to a protected stand-in, and the launch must refuse it.
    func testAChildAliasOutsideTheStateRootIsRefused() throws {
        let resolverStandIn = root.appendingPathComponent("etc-resolver", isDirectory: true)
        let components: [(name: String, target: URL, isDirectory: Bool)] = [
            ("config.json", installed.appendingPathComponent("config.json"), false),
            ("platform-state.json", installed.appendingPathComponent("platform-state.json"), false),
            ("platform.json", installed.appendingPathComponent("platform.json"), false),
            ("preferences.json", installed.appendingPathComponent("preferences.json"), false),
            ("snapshot.json", installed.appendingPathComponent("snapshot.json"), false),
            ("events.ndjson", installed.appendingPathComponent("events.ndjson"), false),
            ("proxy.log", installedLogs.appendingPathComponent("proxy.log"), false),
            ("update-state.json", installed.appendingPathComponent("update-state.json"), false),
            ("saved-dns.json", installed.appendingPathComponent("saved-dns.json"), false),
            ("home", installed.appendingPathComponent("home", isDirectory: true), true),
            ("resolver", resolverStandIn, true),
        ]
        for component in components {
            let state = root.appendingPathComponent("alias-\(component.name)", isDirectory: true)
            try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
            if component.isDirectory {
                try FileManager.default.createDirectory(at: component.target, withIntermediateDirectories: true)
            } else {
                try Data("protected".utf8).write(to: component.target)
            }
            try FileManager.default.createSymbolicLink(
                at: state.appendingPathComponent(component.name, isDirectory: component.isDirectory),
                withDestinationURL: component.target
            )
            XCTAssertThrowsError(try parse(["--dev", "--dev-state-dir", state.path]), component.name) { error in
                XCTAssertTrue(error.localizedDescription.contains("outside the state directory"),
                              "\(component.name): \(error.localizedDescription)")
            }
        }
    }

    /// A component that links to nothing cannot be checked, so it is refused the
    /// way a dangling state directory is.
    func testADanglingChildAliasIsRefused() throws {
        let state = root.appendingPathComponent("alias-dangling", isDirectory: true)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: state.appendingPathComponent("config.json"),
            withDestinationURL: root.appendingPathComponent("nowhere.json")
        )
        XCTAssertThrowsError(try parse(["--dev", "--dev-state-dir", state.path])) { error in
            XCTAssertTrue(error.localizedDescription.contains("cannot resolve"), error.localizedDescription)
        }
    }

    /// An alias that stays inside the state directory is what a persisted dev
    /// state can hold, and a link to the state directory names the same place.
    /// Both are kept as written.
    func testAliasesThatStayInsideTheStateRootAreKept() throws {
        let state = root.appendingPathComponent("inside", isDirectory: true)
        let kept = state.appendingPathComponent("kept", isDirectory: true)
        try FileManager.default.createDirectory(at: kept, withIntermediateDirectories: true)
        try Data("kept".utf8).write(to: kept.appendingPathComponent("config.json"))
        try FileManager.default.createSymbolicLink(
            at: state.appendingPathComponent("config.json"),
            withDestinationURL: kept.appendingPathComponent("config.json")
        )
        try FileManager.default.createSymbolicLink(at: state.appendingPathComponent("home"), withDestinationURL: kept)
        let options = try XCTUnwrap(try parse(["--dev", "--dev-state-dir", state.path]))
        XCTAssertEqual(options.stateDirectory.path, state.path)

        let link = root.appendingPathComponent("inside-link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: state)
        let viaLink = try XCTUnwrap(try parse(["--dev", "--dev-state-dir", link.path]))
        XCTAssertEqual(viaLink.stateDirectory.path, link.path, "a link to the state directory is kept as written")
    }

    /// A case variant is a different directory on a case-sensitive volume and
    /// the same installed directory on a case-insensitive one. The test asks the
    /// volume which it is, so a case-sensitive run is not refused.
    func testACaseVariantIsRefusedOnlyWhenTheVolumeResolvesItToTheInstalledDirectory() throws {
        let variant = root.appendingPathComponent("Application Support/conduit", isDirectory: true)
        if FileManager.default.fileExists(atPath: variant.path) {
            XCTAssertThrowsError(try parse(["--dev", "--dev-state-dir", variant.path]),
                                 "the volume resolves the variant to the installed directory")
        } else {
            XCTAssertNoThrow(try parse(["--dev", "--dev-state-dir", variant.path]),
                             "a distinct directory on a case-sensitive volume is kept")
        }
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

    /// The composed launch refuses a config alias into the installed app before
    /// it creates the fake home or seeds anything, and the stand-in is untouched.
    /// The composition is called directly, so no AppKit launch and no real
    /// directory is involved.
    @MainActor
    func testTheComposedLaunchRefusesAnAliasBeforeAnyWrite() throws {
        let state = root.appendingPathComponent("composed-alias", isDirectory: true)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        let standIn = installed.appendingPathComponent("config.json")
        try Data("protected".utf8).write(to: standIn)
        try FileManager.default.createSymbolicLink(at: state.appendingPathComponent("config.json"), withDestinationURL: standIn)

        XCTAssertThrowsError(try DevLaunch.composeAppState(
            DevLaunchOptions(stateDirectory: state), protectedDirectories: [installed, installedLogs]
        ))
        XCTAssertEqual(try String(contentsOf: standIn, encoding: .utf8), "protected")
        XCTAssertFalse(FileManager.default.fileExists(atPath: DevLaunchOptions.fakeHome(in: state).path),
                       "no fake home is created by a refused launch")
        XCTAssertFalse(FileManager.default.fileExists(atPath: DevLaunchOptions.fakeResolver(in: state).path),
                       "no fake resolver is created by a refused launch")
        XCTAssertFalse(FileManager.default.fileExists(atPath: state.appendingPathComponent("proxy.log").path),
                       "nothing is logged before the check passes")
        XCTAssertFalse(DevLaunch.isActive)
    }
    #endif
}
