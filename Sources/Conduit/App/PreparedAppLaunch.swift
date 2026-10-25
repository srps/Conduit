// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation
import PlatformMac
import ProxyKernel

/// What the app needs before SwiftUI builds its scenes: the state root's writer
/// authority, and the dev composition's options if a dev request asked for one
/// (decisions 0017 and 0028).
///
/// `ConduitMain` prepares it asynchronously, before `ConduitApp.main()`, so a
/// busy or refused root exits there with its refusal on stderr. No `AppState` is
/// built half-initialized, and no load, migration, seed or recovery runs first.
/// The prepared value is pinned in one process-lifetime slot. `AppState.forLaunch`
/// reads it and composes nothing else.
@MainActor
enum PreparedAppLaunch {
    struct Launch {
        let stateSession: StateRootSession
        /// Nil for the installed app. Set only by `--dev` or the dev bundle, in a debug build.
        let devOptions: DevLaunchOptions?
    }

    private static var pinned: Launch?

    /// The prepared launch. Read it only after `prepare` has returned.
    static var current: Launch {
        guard let pinned else {
            preconditionFailure("ConduitMain prepares the launch before SwiftUI builds the app")
        }
        return pinned
    }

    /// Parses the dev flags, takes the state root off the MainActor and pins the
    /// result. A dev request that is refused, or a root that is busy or refused,
    /// exits here with its message. Runs once per process.
    static func prepare(
        arguments: [String] = CommandLine.arguments,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) async {
        precondition(pinned == nil, "the launch is prepared once per process")
        let devOptions: DevLaunchOptions?
        do {
            devOptions = try DevLaunchOptions.parse(arguments, bundleIdentifier: bundleIdentifier)
        } catch {
            DevLaunch.fail(error.localizedDescription)
        }
        let environment: RuntimeEnvironment
        if let devOptions {
            #if DEBUG
            environment = .isolated(stateDirectory: devOptions.stateDirectory)
            #else
            // `DevLaunchOptions.parse` throws for every dev request in a release build, so none reaches here.
            DevLaunch.fail("dev mode is available in debug builds only")
            #endif
        } else {
            environment = productionEnvironment()
        }
        let work = PlatformWork(label: "io.github.srps.Conduit.app.state-root")
        let outcome = await work.run {
            StateRootBootstrap.acquire(
                environment,
                createRootIfMissing: true,
                fileSystem: OSStateRootFileSystem(),
                leasing: OSStateWriterLeasing(),
                onReleaseFailure: { failure in
                    FileHandle.standardError.write(Data("Conduit: \(failure.event.event) \(failure.event.detail ?? "")\n".utf8))
                }
            )
        }
        switch outcome {
        case .success(let session):
            pinned = Launch(stateSession: session, devOptions: devOptions)
        case .failure(let failure):
            let event = failure.event
            FileHandle.standardError.write(Data("Conduit: \(event.event) \(event.detail ?? "")\n".utf8))
            exit(failure.exitStatus)
        }
    }

    /// The installed app's state directory: `PM_CONFIG_DIR` when set, the user's
    /// Application Support directory otherwise.
    private static func productionEnvironment() -> RuntimeEnvironment {
        if let override = ProcessInfo.processInfo.environment["PM_CONFIG_DIR"],
           !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .isolated(stateDirectory: URL(fileURLWithPath: override, isDirectory: true))
        }
        return .userDefault()
    }
}
