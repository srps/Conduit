// SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import Conduit
@testable import ProxyKernel

/// The decision table behind #13: a platform integration switch flipped while
/// the app runs has to apply or clear its surface now, not at the next
/// restart. Every row of the table is one assertion here, plus the no-op rows
/// that keep a save from touching the machine when nothing about the flags
/// changed.
final class PlatformIntegrationReconcilerTests: XCTestCase {

    private typealias Action = PlatformIntegrationReconciler.Action

    private func actions(
        from old: PlatformIntegrationConfig,
        to new: PlatformIntegrationConfig,
        proxyIsUp: Bool = true,
        dnsIsUp: Bool = true
    ) -> [Action] {
        PlatformIntegrationReconciler.actions(old: old, new: new, proxyIsUp: proxyIsUp, dnsIsUp: dnsIsUp)
    }

    private func config(_ mutate: (inout PlatformIntegrationConfig) -> Void = { _ in }) -> PlatformIntegrationConfig {
        var config = PlatformIntegrationConfig()
        mutate(&config)
        return config
    }

    // MARK: - No-ops

    func testUnchangedConfigYieldsNothing() {
        let everything = config {
            $0.manageSystemProxy = true
            $0.manageEnvironmentVariables = true
            $0.manageDNSResolvers = true
            $0.manageSystemDNS = true
            $0.launchAtLogin = true
        }
        XCTAssertEqual(actions(from: everything, to: everything), [])
        XCTAssertEqual(actions(from: everything, to: everything, proxyIsUp: false, dnsIsUp: false), [])
    }

    /// The start path applies a surface whose runtime is down; applying it
    /// now would point the machine at a listener that is not there.
    func testTurningOnWhileTheRuntimeIsDownYieldsNothing() {
        let on = config {
            $0.manageSystemProxy = true
            $0.manageEnvironmentVariables = true
            $0.manageDNSResolvers = true
            $0.manageSystemDNS = true
        }
        XCTAssertEqual(actions(from: config(), to: on, proxyIsUp: false, dnsIsUp: false), [])
    }

    // MARK: - System proxy

    func testSystemProxyOnWithProxyUpApplies() {
        XCTAssertEqual(
            actions(from: config(), to: config { $0.manageSystemProxy = true }),
            [.applySystemProxy]
        )
    }

    /// A clear never waits for the runtime: the surface may have been left
    /// applied by a start that failed or a process that crashed, and the
    /// managers' `clear` is idempotent against the journal.
    func testSystemProxyOffClearsWhateverTheRuntimeState() {
        let on = config { $0.manageSystemProxy = true }
        XCTAssertEqual(actions(from: on, to: config()), [.clearSystemProxy])
        XCTAssertEqual(actions(from: on, to: config(), proxyIsUp: false), [.clearSystemProxy])
    }

    func testSystemProxyModeChangeReappliesOnlyWhileManagedAndUp() {
        let manual = config { $0.manageSystemProxy = true; $0.systemProxyMode = .manual }
        let pac = config { $0.manageSystemProxy = true; $0.systemProxyMode = .pac }
        XCTAssertEqual(actions(from: manual, to: pac), [.applySystemProxy])
        XCTAssertEqual(actions(from: pac, to: manual), [.applySystemProxy])
        XCTAssertEqual(actions(from: manual, to: pac, proxyIsUp: false), [], "nothing applied to re-shape")

        let unmanagedManual = config { $0.systemProxyMode = .manual }
        let unmanagedPAC = config { $0.systemProxyMode = .pac }
        XCTAssertEqual(actions(from: unmanagedManual, to: unmanagedPAC), [], "mode is inert while unmanaged")
    }

    // MARK: - Environment

    func testEnvironmentFollowsItsSwitch() {
        let on = config { $0.manageEnvironmentVariables = true }
        XCTAssertEqual(actions(from: config(), to: on), [.applyEnvironment])
        XCTAssertEqual(actions(from: config(), to: on, proxyIsUp: false), [])
        XCTAssertEqual(actions(from: on, to: config()), [.clearEnvironment])
        XCTAssertEqual(actions(from: on, to: config(), proxyIsUp: false), [.clearEnvironment])
    }

    // MARK: - Resolver files

    /// Entry files belong to the proxy lifecycle and intercept files to the
    /// DNS lifecycle, so turning the switch on applies each only when its own
    /// runtime is up — the same split `startProxy` and `startDNS` make.
    func testResolversOnAppliesEachFileSetWithItsOwnRuntime() {
        let on = config { $0.manageDNSResolvers = true }
        XCTAssertEqual(actions(from: config(), to: on), [.applyResolverEntries, .refreshInterceptFiles])
        XCTAssertEqual(actions(from: config(), to: on, dnsIsUp: false), [.applyResolverEntries])
        XCTAssertEqual(actions(from: config(), to: on, proxyIsUp: false), [.refreshInterceptFiles])
        XCTAssertEqual(actions(from: config(), to: on, proxyIsUp: false, dnsIsUp: false), [])
    }

    func testResolversOffClearsBothFileSetsWhateverTheRuntimeState() {
        let on = config { $0.manageDNSResolvers = true }
        XCTAssertEqual(actions(from: on, to: config()), [.clearResolvers])
        XCTAssertEqual(actions(from: on, to: config(), proxyIsUp: false, dnsIsUp: false), [.clearResolvers])
    }

    // MARK: - System DNS

    func testSystemDNSFollowsTheForwarder() {
        let on = config { $0.manageSystemDNS = true }
        XCTAssertEqual(actions(from: config(), to: on), [.applySystemDNS])
        XCTAssertEqual(actions(from: config(), to: on, dnsIsUp: false), [], "nothing to pin :53 at")
        XCTAssertEqual(actions(from: on, to: config()), [.clearSystemDNS])
        XCTAssertEqual(actions(from: on, to: config(), dnsIsUp: false), [.clearSystemDNS])
    }

    // MARK: - Launch at login

    /// Launch at login needs no runtime state and must not wait for the
    /// queued pass, which a quit right after the save would lose. It is an
    /// immediate action and never a queued one.
    func testLaunchAtLoginIsImmediateAndNeverQueued() {
        let on = config { $0.launchAtLogin = true }
        XCTAssertEqual(PlatformIntegrationReconciler.immediateActions(old: config(), new: on), [.setLaunchAtLogin(true)])
        XCTAssertEqual(PlatformIntegrationReconciler.immediateActions(old: on, new: config()), [.setLaunchAtLogin(false)])
        XCTAssertEqual(PlatformIntegrationReconciler.immediateActions(old: on, new: on), [])
        XCTAssertEqual(actions(from: config(), to: on), [], "not in the queued table")
    }

    // MARK: - Combined

    /// One save can carry several flips (the Configure sections save when the
    /// window closes). Each surface decides for itself.
    func testSeveralFlipsInOneSaveYieldOneActionPerSurface() {
        let before = config {
            $0.manageSystemProxy = true
            $0.manageDNSResolvers = true
        }
        let after = config {
            $0.manageEnvironmentVariables = true
            $0.manageSystemDNS = true
        }
        XCTAssertEqual(
            actions(from: before, to: after),
            [.clearSystemProxy, .applyEnvironment, .clearResolvers, .applySystemDNS]
        )
    }
}
