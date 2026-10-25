// SPDX-License-Identifier: Apache-2.0
// Stand-ins for the app-module types that the entry calls, compiled only by scripts/test-app-entry.py in module
// `Conduit` beside ConduitMain.swift. None of them touches AppKit, WindowServer, the state root, the helper or the
// Keychain.
import Darwin
import Foundation

enum DevLaunch {
    static func workerRefusal(arguments: [String], bundleIdentifier: String?) -> String? {
        let args = arguments.dropFirst()
        guard args.contains("--dev"), args.contains("--conduit-kerberos-ticket") else { return nil }
        return "worker modes are not available in the dev instance"
    }

    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("Conduit: \(message)\n".utf8))
        exit(64)
    }
}

/// Stand-in for the state-root preparation. It models only the shape the entry depends on: a background hop the main
/// thread waits for, then either a refusal (exit 75) or a return. It takes no lease and reads no file.
@MainActor
enum PreparedAppLaunch {
    static func prepare() {
        print("prepare begin")
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            print("prepare background")
            finished.signal()
        }
        finished.wait()
        if ProcessInfo.processInfo.environment["CONDUIT_APP_ENTRY_STANDIN"] == "refuse-prepare" {
            FileHandle.standardError.write(Data("Conduit: config.state_root_busy stand-in refusal\n".utf8))
            exit(75)
        }
        print("prepare end")
    }
}

/// Set only on the main thread, by the callbacks that `ConduitApp.main` schedules.
@MainActor
enum StandInCallbacks {
    static var dispatchRan = false
    static var mainActorRan = false
}

/// Stand-in for the SwiftUI entry. It schedules a main Dispatch block and a MainActor task, then pumps the main
/// Foundation RunLoop for at most three seconds, as the real `NSApplicationMain` pumps its run loop. The callbacks
/// run only if the entry was not itself started from inside a main-queue block or a MainActor job.
enum ConduitApp {
    @MainActor
    static func main() {
        print("present begin main=\(Thread.isMainThread)")
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                StandInCallbacks.dispatchRan = true
                print("dispatch callback")
            }
        }
        Task { @MainActor in
            StandInCallbacks.mainActorRan = true
            print("main actor callback")
        }
        let deadline = Date().addingTimeInterval(3)
        while !(StandInCallbacks.dispatchRan && StandInCallbacks.mainActorRan) && Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        guard StandInCallbacks.dispatchRan && StandInCallbacks.mainActorRan else {
            print("present callbacks missing dispatch=\(StandInCallbacks.dispatchRan) main_actor=\(StandInCallbacks.mainActorRan)")
            exit(3)
        }
        print("present callbacks ok")
    }
}
