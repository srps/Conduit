// SPDX-License-Identifier: Apache-2.0
import Foundation

/// The project's public pages, opened in the browser from the status menu, the Help menu and General settings.
/// They are plain links: opening one is the whole effect, and nothing is counted or remembered.
enum ProjectLinks {
    static let repository = URL(string: "https://github.com/srps/Conduit")!
    static let newIssue = repository.appending(path: "issues/new")
}
