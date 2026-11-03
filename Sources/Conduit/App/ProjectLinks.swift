// SPDX-License-Identifier: Apache-2.0
import Foundation

/// The project's public pages, opened in the browser from the status menu, the Help menu and General settings.
/// They are passive links: Conduit never prompts for a star or records whether one was given.
enum ProjectLinks {
    static let repository = URL(string: "https://github.com/srps/Conduit")!
    static let newIssue = repository.appending(path: "issues/new")
}
