// SPDX-License-Identifier: Apache-2.0
import AppKit
import Darwin
import Foundation
import PlatformMac
import ProxyKernel
import SwiftUI

extension AppState {
    /// The production app, or with `--dev` the harness's composition over a
    /// fake machine, so a second Conduit runs beside the installed one for
    /// visual and VoiceOver checks without touching the system. Dev mode is
    /// compiled into debug builds only; a release build refuses the flag
    /// rather than ignoring it.
    @MainActor
    static func forLaunch(arguments: [String] = CommandLine.arguments) -> AppState {
        #if DEBUG
        do {
            if let options = try DevLaunchOptions.parse(arguments) {
                return DevLaunch.makeAppState(options)
            }
        } catch {
            DevLaunch.fail(error.localizedDescription)
        }
        #else
        if arguments.contains(DevLaunchOptions.flag) {
            DevLaunch.fail("\(DevLaunchOptions.flag) is available in debug builds only")
        }
        #endif
        return AppState()
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

    /// `nil` when `--dev` is absent. The production flags (`--port`,
    /// `--no-system-proxy`, `--no-env`) are `AppState`'s and pass through;
    /// a dev flag without `--dev` is refused rather than ignored.
    static func parse(
        _ arguments: [String],
        defaultStateDirectory: URL = defaultStateDirectory
    ) throws -> DevLaunchOptions? {
        let args = Array(arguments.dropFirst())
        let devFlags: Set<String> = ["--dev-state-dir", "--section", "--vpn", "--upstream"]
        guard args.contains(flag) else {
            if let stray = args.first(where: { devFlags.contains($0) }) {
                throw ParseError("\(stray) needs \(flag)")
            }
            return nil
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
        return options
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

    #if DEBUG
    /// The harness's `launch()`, with a state directory that survives
    /// relaunches so edits made in the dev instance's Settings persist.
    @MainActor
    static func makeAppState(_ options: DevLaunchOptions) -> AppState {
        let home = options.stateDirectory.appendingPathComponent("home", isDirectory: true)
        let resolverDirectory = options.stateDirectory.appendingPathComponent("resolver", isDirectory: true)
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
        let state = AppState(
            runtimeEnvironment: environment,
            privilegeClient: machine,
            helperLifecycle: helper,
            credentialStore: secrets,
            commandRunner: { launchPath, arguments in try machine.run(launchPath, arguments) },
            homeDirectory: home,
            resolverDirectory: resolverDirectory.path,
            loginItemManager: loginItems.manager,
            vpnStatusMonitor: vpn
        )
        if let section = options.section {
            state.selectedSection = section
        }
        // The app's init started the observer, so the emit is delivered.
        if let vpnState = options.vpn {
            vpn.connectedInterfaceName = options.vpnInterfaceName
            vpn.emit(vpnState)
        }
        state.logStore.log(
            .notice,
            // Not the path: the log sanitizer redacts a long hex run, and a
            // temporary directory has one. The log file sits in the directory.
            "Dev mode: fake machine and scratch state. Nothing here reaches the system.",
            category: .system
        )
        session = Session(options: options, machine: machine, vpn: vpn, loginItems: loginItems, helper: helper, secrets: secrets)
        return state
    }

    /// First launch writes a config with every port ephemeral and the four
    /// platform switches off, the way the harness does. Later launches keep
    /// what was edited; only `--upstream` rewrites the pool.
    private static func seed(_ environment: RuntimeEnvironment, options: DevLaunchOptions) {
        do {
            var config: ProxyConfig
            var dirty = false
            if FileManager.default.fileExists(atPath: environment.configFile.path) {
                config = ProxyConfigPersistence.loadAllMigrating(in: environment).config
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
