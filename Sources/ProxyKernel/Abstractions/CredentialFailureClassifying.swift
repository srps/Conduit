// SPDX-License-Identifier: Apache-2.0
import Foundation

/// An authentication error that can say whether it is about the credential
/// itself (no ticket, expired, withheld by the SSO extension) rather than
/// the protocol or the configuration.
///
/// `ProxyKernel` cannot see `ProxyAuth`'s error types; `KerberosAuthError`
/// adopts this so the handshake retry and the recovery ladder can branch on it.
package protocol CredentialFailureClassifying: Error {
    var isCredentialUnavailable: Bool { get }
    /// Whether waiting briefly may produce the credential (an SSO extension
    /// handing a ticket back), as opposed to a store with nothing in it.
    var isCredentialRetryable: Bool { get }
}

package extension CredentialFailureClassifying {
    var isCredentialRetryable: Bool { isCredentialUnavailable }
}

package extension Error {
    var isCredentialUnavailable: Bool {
        (self as? any CredentialFailureClassifying)?.isCredentialUnavailable ?? false
    }

    var isCredentialRetryable: Bool {
        (self as? any CredentialFailureClassifying)?.isCredentialRetryable ?? false
    }
}
