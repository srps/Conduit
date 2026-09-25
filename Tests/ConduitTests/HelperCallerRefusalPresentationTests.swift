// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import Conduit
@testable import ConduitShared
@testable import PlatformMac

/// A build the caller pin refuses (#46) is not fixed by reinstalling the
/// helper from the app — that path never touches the pin — so Settings must
/// say what does fix it, in the helper's words, and offer no such button.
final class HelperCallerRefusalPresentationTests: XCTestCase {
    private let pinMessage = HelperCallerRefusal.notPinned(identifier: "io.github.srps.Conduit").message

    func testAPinRefusalIsNotTheConsoleUserRefusal() {
        XCTAssertEqual(
            HelperToolPrivilegeClient.status(forPing: .refused(.unauthorized, pinMessage)),
            .callerNotAccepted(message: pinMessage)
        )
        XCTAssertEqual(
            HelperToolPrivilegeClient.status(forPing: .refused(.unauthorized, "peer is not the console user")),
            .unauthorized
        )
        XCTAssertEqual(HelperToolPrivilegeClient.status(forPing: .refused(.noConsoleUser, "no console user yet")), .waitingForConsoleUser)
        XCTAssertEqual(HelperToolPrivilegeClient.status(forPing: .ok()), .installed)
    }

    func testSettingsOffersNoReinstallForAPinRefusalAndShowsTheRemedy() {
        let status = HelperToolPrivilegeClient.Status.callerNotAccepted(message: pinMessage)
        XCTAssertNil(HelperStatusPresentation.primaryActionTitle(for: status), "reinstalling from the app never updates the pin")
        let remedy = HelperStatusPresentation.remediation(for: status) ?? ""
        XCTAssertTrue(remedy.contains("sudo ./install-helper.sh"), remedy)
        XCTAssertTrue(remedy.contains("bundle-app.sh"), remedy)
        XCTAssertTrue(remedy.contains(pinMessage), "the helper's own explanation must reach the user: \(remedy)")
        XCTAssertEqual(HelperStatusPresentation.label(for: status), "Installed, but not accepting this build")
    }

    func testOtherStatusesKeepTheirButtonAndNeedNoRemedy() {
        for status: HelperToolPrivilegeClient.Status in [.installed, .outdated, .notInstalled, .notResponding, .waitingForConsoleUser, .unauthorized] {
            XCTAssertNotNil(HelperStatusPresentation.primaryActionTitle(for: status), "\(status)")
            XCTAssertNil(HelperStatusPresentation.remediation(for: status), "\(status)")
        }
    }
}
