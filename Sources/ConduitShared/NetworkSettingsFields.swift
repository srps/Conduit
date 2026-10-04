// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Pure projection/merge shared by the reader and privileged writer. No settings or credentials are logged.
package enum NetworkSettingsFields {
    package static func project(_ configuration: [String: Any], kind: NetworkSettingsKind) throws -> [String: NetworkSettingValue] {
        var result: [String: NetworkSettingValue] = [:]
        for key in kind.keys {
            guard let value = configuration[key] else { continue }
            if let list = value as? [String] { result[key] = .list(list) }
            else if let number = value as? NSNumber {
                guard number.doubleValue == Double(number.intValue) else { throw NetworkSettingsError.invalidRequest }
                result[key] = .number(number.intValue)
            }
            else if let text = value as? String { result[key] = .text(text) }
            else { throw NetworkSettingsError.invalidRequest }
        }
        return result
    }

    package static func merging(_ request: NetworkSettingsRequest, into configuration: [String: Any]) throws -> [String: Any] {
        try request.validate()
        guard try project(configuration, kind: request.kind) == request.expected else { throw NetworkSettingsError.changed }
        var result = configuration
        for key in request.kind.keys { result.removeValue(forKey: key) }
        for (key, value) in request.replacement {
            switch value {
            case .text(let text): result[key] = text
            case .number(let number): result[key] = number
            case .list(let list): result[key] = list
            }
        }
        return result
    }
}
