// Conduit Updater: Sparkle 2 in its own process, nested in Conduit.app at
// `UpdaterContract.relativeBundlePath`. See `UpdaterContract` for why Sparkle
// never runs inside Conduit. Conduit starts it with one argument
// (`UpdaterContract.LaunchMode`); it checks the host's feed, lets the user
// install, and exits when the update cycle is over. Installing is Sparkle's
// own flow: it sends Conduit a normal quit event, so Conduit's termination
// cleanup restores proxy and DNS settings before the bundle is replaced, and
// relaunches it afterwards.
import AppKit
import ConduitShared

let arguments = Array(CommandLine.arguments.dropFirst())
let mode = arguments.first.flatMap(UpdaterContract.LaunchMode.init(rawValue:)) ?? .interactive

#if DEBUG
// Accepts every prompt, for scripts/test-updater-e2e.sh. Debug builds only:
// a shipped updater always asks the user before installing.
let autoInstall = arguments.contains("--test-auto-install")
#else
let autoInstall = false
#endif

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let controller = UpdaterController(mode: mode, autoInstall: autoInstall)
    app.delegate = controller
    app.setActivationPolicy(.accessory)
    // NSApplication holds its delegate weakly.
    withExtendedLifetime(controller) {
        app.run()
    }
}
