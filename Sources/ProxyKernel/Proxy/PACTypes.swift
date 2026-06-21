// SPDX-License-Identifier: Apache-2.0
// Kernel-side value types for PAC (Proxy Auto-Configuration) resolution.
//
// Kept separate so concrete PAC evaluators can live in `ProxyPAC` while
// the error and route enums stay Foundation-only and Kernel-visible.
// `PACRoutingEngine` in the Kernel consumes both types; consumers outside the
// Kernel (HTTPProxyHandler, SOCKS5Server, LocalProxyServer) branch on
// `PACRoute`.

import Foundation

package enum PACResolverError: Error, LocalizedError {
    case invalidURL
    case invalidPAC
    case evaluationFailed(String)
    case fetchFailed(String)

    package var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "The PAC URL is invalid."
        case .invalidPAC:
            return "The PAC file could not be evaluated."
        case .evaluationFailed(let message):
            return "The PAC file evaluation failed: \(message)"
        case .fetchFailed(let message):
            return "The PAC file could not be fetched: \(message)"
        }
    }
}

package enum PACRoute: Equatable {
    case direct
    case proxy(host: String, port: Int)
    case socks(host: String, port: Int)
}
