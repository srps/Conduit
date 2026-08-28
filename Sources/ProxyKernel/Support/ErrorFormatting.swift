// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOCore
import NIOPosix

package extension Error {
    /// Log-oriented description. Prefer this over `localizedDescription` for
    /// anything that can carry a SwiftNIO error: Foundation's bridge renders
    /// those as "The operation couldn't be completed. (NIOCore.ChannelError
    /// error 0.)", dropping the errno, the timeout, the DNS failure and the
    /// per-address connect errors — which is exactly the part a log line is
    /// there to record.
    var displayDescription: String {
        if let nioError = self as? IOError {
            return nioError.description
        }

        if let connectionError = self as? NIOConnectionError {
            return connectionError.displaySummary
        }

        if let channelError = self as? ChannelError {
            return channelError.description
        }

        if let localizedError = self as? LocalizedError,
           let errorDescription = localizedError.errorDescription,
           !errorDescription.isEmpty {
            return errorDescription
        }

        return String(describing: self)
    }
}

extension NIOConnectionError {
    /// One line naming the target and every reason the Happy Eyeballs
    /// connect gave up: the DNS lookups that failed and each address that
    /// refused. `NIOConnectionError.description` only reports the first DNS
    /// error, which hides an A-record failure behind an AAAA one.
    fileprivate var displaySummary: String {
        var reasons: [String] = []
        let aReason = dnsAError?.displayDescription
        let aaaaReason = dnsAAAAError?.displayDescription
        if let aReason, let aaaaReason, aReason == aaaaReason {
            reasons.append("DNS: \(aReason)")
        } else {
            if let aReason { reasons.append("DNS A: \(aReason)") }
            if let aaaaReason { reasons.append("DNS AAAA: \(aaaaReason)") }
        }
        for failure in connectionErrors {
            reasons.append("\(failure.target): \(failure.error.displayDescription)")
        }
        let detail = reasons.isEmpty ? "no address could be tried" : reasons.joined(separator: "; ")
        return "could not connect to \(host):\(port) — \(detail)"
    }
}
