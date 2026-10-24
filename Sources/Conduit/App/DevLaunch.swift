// SPDX-License-Identifier: Apache-2.0
import AppKit
import Darwin
import Foundation
import PlatformMac
import ProxyKernel
import SwiftUI

extension AppState {
    /// The production app, or the harness's composition over a fake machine,
    /// so a second Conduit runs beside the installed one for visual and
    /// VoiceOver checks without touching the system. The composition is asked
    /// for by `--dev` or by the dev bundle identity (`Conduit Dev.app`). Dev
    /// mode is compiled into debug builds only; a release build refuses both
    /// rather than ignoring them.
    @MainActor
    static func forLaunch(
        arguments: [String] = CommandLine.arguments,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) -> AppState {
        do {
            if let options = try DevLaunchOptions.parse(arguments, bundleIdentifier: bundleIdentifier) {
                #if DEBUG
                return DevLaunch.makeAppState(options)
                #else
                // `parse` throws for every dev request in a release build, so this is not reached.
                DevLaunch.fail("dev mode is available in debug builds only")
                #endif
            }
        } catch {
            DevLaunch.fail(error.localizedDescription)
        }
        return AppState(
            commandRunner: CommandRunner.host,
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser
        )
    }
}

/// The `--dev` launch flags. The parser is pure so the flags an agent types
/// have a unit test; the composition they feed is the harness's and is
/// covered by `AppStateHarnessTests`.
struct DevLaunchOptions: Equatable {
    static let flag = "--dev"

    struct Endpoint: Equatable {
        var host: String
        var port: Int
    }

    struct ParseError: Error, LocalizedError, Equatable {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    /// Config, journal, preferences, log, the fake resolver directory and
    /// the scratch home all live here. `--dev-state-dir` moves it so an
    /// agent can read the journal.
    var stateDirectory: URL
    /// Open the app window on this section at launch.
    var section: AppSection?
    /// Reported by the fake VPN observer once the app is up.
    var vpn: VPNObservedState?
    var vpnInterfaceName: String?
    /// The one upstream in the seeded config. Point it at a running
    /// `pm-proxy` for a real "Proxied via" state.
    var upstream: Endpoint?

    static var defaultStateDirectory: URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("conduit-dev", isDirectory: true)
    }

    /// The bundle identifier `bundle-app.sh --dev` gives `Conduit Dev.app`.
    /// Exact match only: the dev helper's and updater's identifiers are
    /// suffixed and do not select the composition.
    static let devBundleIdentifier = "io.github.srps.Conduit.dev"

    static func isDevBundle(_ identifier: String?) -> Bool {
        identifier == devBundleIdentifier
    }

    /// Whether this launch asks for the dev composition, by flag or by bundle.
    /// The app delegate reads it before any app state exists.
    static func requested(
        by arguments: [String] = CommandLine.arguments,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) -> Bool {
        arguments.dropFirst().contains(flag) || isDevBundle(bundleIdentifier)
    }

    /// The installed app's config and log directories: what a dev instance
    /// must never read or write (#23).
    static var productionStateDirectories: [URL] {
        let production = RuntimeEnvironment.userDefault()
        return [production.configDirectory, production.logFile.deletingLastPathComponent()]
    }

    static var compiledAsDebugBuild: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    /// `nil` when neither `--dev` nor the dev bundle asks for the composition.
    /// The production flags (`--port`, `--no-system-proxy`, `--no-env`) are
    /// `AppState`'s and pass through; a dev flag without `--dev` is refused
    /// rather than ignored. A release build refuses a request outright, and a
    /// state directory that overlaps the installed app's is refused whatever
    /// its spelling.
    static func parse(
        _ arguments: [String],
        bundleIdentifier: String? = nil,
        isDebugBuild: Bool = compiledAsDebugBuild,
        defaultStateDirectory: URL = defaultStateDirectory,
        protectedDirectories: [URL] = productionStateDirectories
    ) throws -> DevLaunchOptions? {
        let args = Array(arguments.dropFirst())
        let devFlags: Set<String> = ["--dev-state-dir", "--section", "--vpn", "--upstream"]
        let flagged = args.contains(flag)
        guard flagged || isDevBundle(bundleIdentifier) else {
            if let stray = args.first(where: { devFlags.contains($0) }) {
                throw ParseError("\(stray) needs \(flag)")
            }
            return nil
        }
        guard isDebugBuild else {
            throw ParseError(flagged
                ? "\(flag) is available in debug builds only"
                : "\(devBundleIdentifier) is available in debug builds only")
        }
        var options = DevLaunchOptions(stateDirectory: defaultStateDirectory)
        var index = 0
        while index < args.count {
            let arg = args[index]
            func value() throws -> String {
                guard index + 1 < args.count, !args[index + 1].hasPrefix("--") else {
                    throw ParseError("\(arg) needs a value")
                }
                index += 1
                return args[index]
            }
            switch arg {
            case flag:
                break
            case "--dev-state-dir":
                options.stateDirectory = URL(fileURLWithPath: try value(), isDirectory: true)
            case "--section":
                let raw = try value()
                guard let section = AppSection(rawValue: raw) else {
                    let known = AppSection.allCases.map(\.rawValue).joined(separator: ", ")
                    throw ParseError("--section: unknown section \(raw); one of \(known)")
                }
                options.section = section
            case "--vpn":
                let raw = try value()
                if raw == "off" {
                    options.vpn = .disconnected(reason: .userInitiated)
                    options.vpnInterfaceName = nil
                } else {
                    options.vpn = .connected
                    options.vpnInterfaceName = raw
                }
            case "--upstream":
                options.upstream = try endpoint(from: try value())
            default:
                break
            }
            index += 1
        }
        try refuseProductionState(options.stateDirectory, protectedDirectories: protectedDirectories)
        return options
    }

    /// Refuses a state directory that is, sits inside, or contains a protected
    /// directory, compared after symlinks resolve. A link or a parent path
    /// reaches the installed app's files no more than the path itself would.
    /// Then refuses any known runtime file or fake root beneath it that
    /// resolves outside it, since the state directory alone says nothing about
    /// what its children link to.
    static func refuseProductionState(_ directory: URL, protectedDirectories: [URL]) throws {
        let devPath = try canonicalPath(directory)
        let devParts = devPath.split(separator: "/")
        for protected in protectedDirectories {
            let productionPath = try canonicalPath(protected)
            let productionParts = productionPath.split(separator: "/")
            let shared = min(devParts.count, productionParts.count)
            if devParts.prefix(shared).elementsEqual(productionParts.prefix(shared)) {
                throw ParseError("--dev-state-dir \(directory.path) overlaps the installed Conduit's \(productionPath); choose another directory")
            }
        }
        for component in ownedComponents(in: directory) {
            let resolved = try canonicalPath(component)
            guard resolved == devPath || resolved.hasPrefix(devPath + "/") else {
                throw ParseError("--dev-state-dir \(directory.path): \(component.lastPathComponent) resolves to \(resolved), outside the state directory; choose another directory")
            }
        }
    }

    /// The runtime files and fake roots a dev run reads or writes beneath its
    /// state directory, named by the same `RuntimeEnvironment` the app uses.
    /// The export default is left out: it sits in the real home by design and
    /// is written only by an explicit export. Only these are checked, so a
    /// directory the app creates beneath them is not scanned.
    static func ownedComponents(in stateDirectory: URL) -> [URL] {
        let environment = RuntimeEnvironment.isolated(stateDirectory: stateDirectory)
        return [
            environment.configFile, environment.platformStateFile, environment.platformConfigFile,
            environment.preferencesFile, environment.snapshotFile, environment.eventsFile,
            environment.logFile, environment.updateStateFile, environment.legacySavedDNSFile,
            fakeHome(in: stateDirectory), fakeResolver(in: stateDirectory),
        ]
    }

    static func fakeHome(in stateDirectory: URL) -> URL {
        stateDirectory.appendingPathComponent("home", isDirectory: true)
    }

    static func fakeResolver(in stateDirectory: URL) -> URL {
        stateDirectory.appendingPathComponent("resolver", isDirectory: true)
    }

    /// The path with every symlink in its existing part resolved. The missing
    /// tail is kept as written, since a directory that does not exist yet
    /// cannot hold a link. A dangling link cannot be resolved, so it is
    /// refused rather than guessed at. A missing `.` or `..` is refused too:
    /// it cannot be placed without resolving a parent that does not exist.
    /// The tail is joined as plain strings, not through `URL`: standardizing
    /// drops `/private` only from paths that exist, so a missing directory
    /// and its existing parent would disagree about the same location.
    static func canonicalPath(_ url: URL) throws -> String {
        var existing = url.path
        var missing: [String] = []
        var info = stat()
        while lstat(existing, &info) != 0 {
            let code = errno
            let name = (existing as NSString).lastPathComponent
            guard code == ENOENT, existing != "/", name != ".", name != ".." else {
                throw ParseError("--dev-state-dir: cannot inspect \(url.path)")
            }
            missing.insert(name, at: 0)
            existing = (existing as NSString).deletingLastPathComponent
        }
        guard let resolved = realpath(existing, nil) else {
            throw ParseError("--dev-state-dir: cannot resolve \(url.path); a link may be dangling")
        }
        defer { free(resolved) }
        var canonical = String(cString: resolved)
        for name in missing {
            canonical = (canonical as NSString).appendingPathComponent(name)
        }
        return canonical
    }

    private static func endpoint(from raw: String) throws -> Endpoint {
        guard let colon = raw.lastIndex(of: ":"), colon != raw.startIndex else {
            throw ParseError("--upstream: expected host:port, got \(raw)")
        }
        let host = String(raw[..<colon])
        guard let port = Int(raw[raw.index(after: colon)...]), (1...65535).contains(port) else {
            throw ParseError("--upstream: port must be 1-65535 in \(raw)")
        }
        return Endpoint(host: host, port: port)
    }
}

/// The dev instance's collaborators, kept for the scenes and for anything
/// that later wants to drive the fakes while the app runs.
enum DevLaunch {
    struct Session {
        let options: DevLaunchOptions
        let machine: FakeMachine
        let vpn: FakeVPNStatusObserver
        let loginItems: FakeLoginItems
        let helper: FakeHelperLifecycle
        let secrets: InMemorySecretStore
    }

    @MainActor private(set) static var session: Session?

    @MainActor static var isActive: Bool { session != nil }

    @MainActor private static var previewPanel: NSPanel?

    /// The state glyph with a dot badge in its lower-right corner, as one
    /// template image the same width as the glyph, so the dev instance's
    /// status item is told from the installed app's in any state and still
    /// fits beside a notch. See `MenuBarLabel`.
    static func menuBarImage(symbol: String) -> NSImage {
        let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .regular))
            ?? NSImage(size: NSSize(width: 16, height: 16))
        let size = NSSize(width: ceil(glyph.size.width) + 2, height: ceil(glyph.size.height) + 2)
        let image = NSImage(size: size, flipped: false) { rect in
            glyph.draw(in: NSRect(x: 0, y: 2, width: glyph.size.width, height: glyph.size.height))
            // A cleared ring so the dot reads against the glyph's strokes.
            let badge = NSRect(x: rect.width - 7, y: 0, width: 7, height: 7)
            NSGraphicsContext.current?.cgContext.setBlendMode(.clear)
            NSBezierPath(ovalIn: badge.insetBy(dx: -1.5, dy: -1.5)).fill()
            NSGraphicsContext.current?.cgContext.setBlendMode(.normal)
            NSColor.black.setFill()
            NSBezierPath(ovalIn: badge).fill()
            return true
        }
        image.isTemplate = true
        return image
    }

    /// The popover in a plain panel, because a `MenuBarExtra` cannot be
    /// opened programmatically and a screenshot or the accessibility
    /// inspector needs a target that stays put. The panel is clear behind
    /// the view's own glass, so the effect sits over the desktop the way the
    /// menu bar panel's does, and the padding around it leaves the edge
    /// visible. With `--section`, the app window opens on that section too.
    @MainActor
    static func presentWindows(appState: AppState) {
        guard let session else { return }
        let hosting = NSHostingView(
            rootView: StatusBarView()
                .environmentObject(appState)
                .environmentObject(appState.runtime)
                .padding(24)
        )
        hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)
        let panel = NSPanel(
            contentRect: hosting.frame,
            styleMask: [.titled, .closable, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "Popover preview"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        // The title bar exists only to make the panel a proper window; its
        // buttons would sit as three bare dots above the glass.
        panel.isMovableByWindowBackground = true
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        panel.contentView = hosting
        panel.center()
        panel.orderFrontRegardless()
        // Counted as an app window, so closing the app window while the
        // preview is up does not return the process to accessory and take
        // the Dock icon with it.
        AppWindowPresentation.track(panel)
        previewPanel = panel
        appState.logStore.log(.notice, "Dev mode: popover preview window shown.", category: .system)

        if let section = session.options.section {
            openAppWindow(on: section, appState: appState)
        }
    }

    /// The one path from AppKit into the SwiftUI window is the command SwiftUI
    /// put in the main menu. It lands on Overview, so the section is set
    /// after it runs.
    @MainActor
    private static func openAppWindow(on section: AppSection, appState: AppState) {
        guard let mainMenu = NSApp.mainMenu, let (menu, index) = find(itemTitled: "Open Conduit", in: mainMenu) else {
            appState.logStore.log(
                .warning,
                "Dev mode: the Open Conduit command is not in the main menu, so the app window was not opened.",
                category: .system
            )
            return
        }
        menu.performActionForItem(at: index)
        appState.selectedSection = section
        appState.logStore.log(.notice, "Dev mode: app window opened on \(section.title).", category: .system)
    }

    @MainActor
    private static func find(itemTitled title: String, in menu: NSMenu) -> (NSMenu, Int)? {
        for (index, item) in menu.items.enumerated() {
            if item.title == title { return (menu, index) }
            if let submenu = item.submenu, let found = find(itemTitled: title, in: submenu) { return found }
        }
        return nil
    }

    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("Conduit: \(message)\n".utf8))
        exit(EX_USAGE)
    }

    /// The argument-triggered worker modes. They reach the installed helper or
    /// the Kerberos cache before any app state exists, so a dev request refuses
    /// them rather than running them (#23).
    static func isWorkerArgument(_ argument: String) -> Bool {
        argument == UpdateHelperPreflightWorker.argument || argument == KerberosTicketRecoveryReply.argument
    }

    /// The refusal for a worker mode asked for alongside a dev request, by
    /// `--dev` or by the dev bundle, or `nil` when the launch may run its
    /// worker. It takes no build flag: a release binary given `--dev` and a
    /// worker argument refuses here, before any worker has contacted the
    /// installed helper or the Kerberos cache. A production launch is `nil`.
    static func workerRefusal(arguments: [String], bundleIdentifier: String?) -> String? {
        guard DevLaunchOptions.requested(by: arguments, bundleIdentifier: bundleIdentifier),
              arguments.dropFirst().contains(where: isWorkerArgument) else { return nil }
        return "worker modes are not available in the dev instance"
    }

    #if DEBUG
    /// The harness's `launch()`, with a state directory that survives
    /// relaunches so edits made in the dev instance's Settings persist.
    @MainActor
    static func makeAppState(_ options: DevLaunchOptions) -> AppState {
        do {
            return try composeAppState(options)
        } catch {
            fail(error.localizedDescription)
        }
    }

    /// `makeAppState` after the state directory and its runtime files have been
    /// checked. The check comes first, so a refused launch creates nothing and
    /// reads no config from beneath the directory.
    @MainActor
    static func composeAppState(
        _ options: DevLaunchOptions,
        protectedDirectories: [URL] = DevLaunchOptions.productionStateDirectories
    ) throws -> AppState {
        try DevLaunchOptions.refuseProductionState(options.stateDirectory, protectedDirectories: protectedDirectories)
        let home = DevLaunchOptions.fakeHome(in: options.stateDirectory)
        let resolverDirectory = DevLaunchOptions.fakeResolver(in: options.stateDirectory)
        do {
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        } catch {
            fail("cannot create \(home.path): \(error.localizedDescription)")
        }
        let environment = RuntimeEnvironment.isolated(stateDirectory: options.stateDirectory)
        seed(environment, options: options)

        let machine = FakeMachine(resolverDirectory: resolverDirectory)
        let vpn = FakeVPNStatusObserver()
        let loginItems = FakeLoginItems()
        // The Settings surface's helper controls and the credential controls
        // have seams of their own; without these two, "Install Helper" and
        // "Clear Saved Credentials" in the dev instance would reach the
        // installed helper and the login Keychain.
        let helper = FakeHelperLifecycle()
        let secrets = InMemorySecretStore()
        // "Check for Updates…" would otherwise start the updater inside this
        // dev bundle, and installing would replace and relaunch it as the
        // real app.
        let updater = FakeUpdaterLauncher()
        let state = AppState(
            runtimeEnvironment: environment,
            privilegeClient: machine,
            helperLifecycle: helper,
            credentialStore: secrets,
            kerberosTicketRecovery: FakeKerberosTicketRecovery(),
            commandRunner: { launchPath, arguments in try machine.run(launchPath, arguments) },
            // The installed Conduit's relay may answer on the real port 53.
            dnsResponds: FakeDNSProbe().responds(onPort:),
            homeDirectory: home,
            resolverDirectory: resolverDirectory.path,
            loginItemManager: loginItems.manager,
            vpnStatusMonitor: vpn,
            networkLocationObserver: FakeNetworkLocationObserver(),
            networkLocationStoreFactory: { _ in
                FakeNetworkLocationStore(snapshot: NetworkLocationSnapshot(
                    activeLocationID: "11111111-1111-1111-1111-111111111111",
                    services: [LocationServiceSettings(
                        locationID: "11111111-1111-1111-1111-111111111111",
                        serviceID: "33333333-3333-3333-3333-333333333333",
                        name: "Wi-Fi", enabled: true, proxies: [:], dns: [:]
                    )]
                ))
            },
            updaterLauncher: updater
        )
        if let section = options.section {
            state.selectedSection = section
        }
        // The app's init started the observer, so the emit is delivered.
        if let vpnState = options.vpn {
            vpn.connectedInterfaceName = options.vpnInterfaceName
            vpn.emit(vpnState)
        }
        // Not the path: the log sanitizer redacts a long hex run, and a
        // temporary directory has one. The log file sits in the directory.
        // Names what is still real: notifications and network-path observation
        // have no seams yet (see AGENTS.md).
        state.logStore.log(
            .notice,
            "Dev mode: FakeMachine and scratch state. Helper, credentials, updater, login items, resolver and VPN are fakes. Notifications and network-path observation are real.",
            category: .system
        )
        session = Session(options: options, machine: machine, vpn: vpn, loginItems: loginItems, helper: helper, secrets: secrets)
        return state
    }

    /// Drops the session once its app state has been shut down, so the static
    /// does not outlive the composition it describes.
    @MainActor
    static func endSession() {
        session = nil
    }

    /// First launch writes a config with every port ephemeral and the four
    /// platform switches off, the way the harness does. Later launches keep
    /// what was edited; only `--upstream` rewrites the pool.
    private static func seed(_ environment: RuntimeEnvironment, options: DevLaunchOptions) {
        do {
            var config: ProxyConfig
            var dirty = false
            if FileManager.default.fileExists(atPath: environment.configFile.path) {
                config = try ProxyConfigPersistence.loadAllMigrating(in: environment).config
            } else {
                config = GenericDefaults.shared.makeConfig()
                config.profileName = "Dev"
                config.localPort = 0
                config.socksPort = 0
                config.dnsForwarderPort = 0
                config.transparentProxyPort = 0
                config.localPACPort = 0
                config.dnsEntries = [DomainDNSEntry(domain: "corp.example", servers: ["10.0.0.53"])]
                try PlatformConfigPersistence.save(PlatformIntegrationConfig(), in: environment)
                try AppPreferencesPersistence.save(AppPreferences(), in: environment)
                // A config file that exists before launch reads as an upgrade,
                // and launch then scans the resolver directory for files an
                // old release left. This is a fresh install; say so.
                PlatformStateJournal(fileURL: environment.platformStateFile).markReleased(surface: .resolverFile)
                dirty = true
            }
            if let upstream = options.upstream {
                config.upstreams = [
                    UpstreamProxy(name: "dev upstream", host: upstream.host, port: upstream.port, priority: 1)
                ]
                dirty = true
            }
            if dirty {
                try ProxyConfigPersistence.save(config, in: environment)
            }
        } catch {
            fail("cannot seed the dev state in \(environment.configDirectory.path): \(error.localizedDescription)")
        }
    }
    #endif
}
