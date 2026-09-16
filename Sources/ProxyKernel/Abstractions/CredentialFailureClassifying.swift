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
}

package extension Error {
    var isCredentialUnavailable: Bool {
        (self as? any CredentialFailureClassifying)?.isCredentialUnavailable ?? false
    }
}
