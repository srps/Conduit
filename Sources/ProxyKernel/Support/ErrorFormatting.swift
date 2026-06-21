// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOCore

package extension Error {
    var displayDescription: String {
        if let nioError = self as? IOError {
            return nioError.description
        }

        if let localizedError = self as? LocalizedError,
           let errorDescription = localizedError.errorDescription,
           !errorDescription.isEmpty {
            return errorDescription
        }

        return String(describing: self)
    }
}
