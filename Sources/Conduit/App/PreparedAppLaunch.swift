// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation
import PlatformMac
import ProxyKernel

/// What the app needs before SwiftUI builds its scenes: the state root's writer
/// authority, and the dev composition's options if a dev request asked for one
/// (decisions 0017 and 0028).
///
/// `ConduitMain` prepares it synchronously, before `ConduitApp.main()`, so a
/// busy or refused root exits there with its refusal on stderr. The bootstrap's
/// file system and lease effects run on `PlatformWork`, and the main thread waits
/// for their one result before it pins it. No `AppState` is built
/// half-initialized, and no load, migration, seed or recovery runs first.
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
    ) {
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
        let slot = BootstrapResultSlot()
        // The file system and lease effects block, so they run on `PlatformWork`, not the main thread. The main thread
        // waits here with nothing else queued to it, then pins the one result before SwiftUI is entered.
        Task.detached {
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
            slot.fill(outcome)
        }
        switch slot.take() {
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

/// The one outcome of the pre-UI bootstrap, handed from its `PlatformWork` task to the main thread that waits for it.
/// `fill` runs once and `take` once; the semaphore orders them.
private final class BootstrapResultSlot: @unchecked Sendable {
    private let filled = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var outcome: Result<StateRootSession, StateRootAcquisitionFailure>?

    func fill(_ value: Result<StateRootSession, StateRootAcquisitionFailure>) {
        lock.withLock { outcome = value }
        filled.signal()
    }

    func take() -> Result<StateRootSession, StateRootAcquisitionFailure> {
        filled.wait()
        guard let value = lock.withLock({ outcome }) else {
            preconditionFailure("the bootstrap fills the slot before it signals")
        }
        return value
    }
}
