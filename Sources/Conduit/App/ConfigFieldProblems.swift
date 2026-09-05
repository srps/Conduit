// SPDX-License-Identifier: Apache-2.0
import Foundation
import ProxyKernel

/// `ProxyConfig.validate()` indexed by the field it complains about, so a
/// Configure section can put the reason next to the control that is wrong
/// instead of leaving it in the "Configuration problem: …" banner.
///
/// The validators are the boundary's own; this type introduces no grammar.
/// Field names are the dotted paths `ConfigValidation` emits
/// (`proxy.port`, `routing.noProxyHosts[2]`, …). Conflicts between two
/// fields have no single home and are listed separately for the section
/// that owns the first field involved.
struct ConfigFieldProblems {
    private var byField: [String: String] = [:]
    private(set) var conflicts: [String] = []

    init(config: ProxyConfig) {
        self.init(errors: config.validate())
    }

    init(errors: [ConfigValidationError]) {
        for error in errors {
            switch error {
            case .invalidPort(let field, _),
                 .invalidLimit(let field, _, _),
                 .invalidDuration(let field, _),
                 .invalidHost(let field, _):
                // First problem per field wins; a second one for the same
                // field would only repeat the location.
                if byField[field] == nil {
                    byField[field] = error.localizedDescription
                }
            case .conflict(let description):
                conflicts.append(description)
            case .invalidInterceptPattern, .invalidInterceptIP, .invalidTransparentProxyIP:
                // The DNS section validates these per row already, with the
                // same validators, so they are not indexed twice.
                continue
            }
        }
    }

    /// The reason a field is refused, or nil when the boundary accepts it.
    func message(for field: String) -> String? {
        byField[field]
    }

    func isInvalid(_ field: String) -> Bool {
        byField[field] != nil
    }

    /// Conflicts that mention any of the given words, for a section to show
    /// only the cross-field problems it can do something about.
    func conflicts(mentioning keywords: [String]) -> [String] {
        conflicts.filter { description in
            keywords.contains { description.localizedCaseInsensitiveContains($0) }
        }
    }

    var isEmpty: Bool { byField.isEmpty && conflicts.isEmpty }
}
