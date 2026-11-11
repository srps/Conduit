// SPDX-License-Identifier: Apache-2.0
import NIOCore
@testable import ProxyKernel

extension ConnectionPool {
    /// What a dial the upstream never accepted feeds the breaker.
    func recordConnectFailure(for proxy: UpstreamProxy) {
        recordExchangeError(ChannelError.connectTimeout(.seconds(1)), for: .forced(proxy), origin: .connect(proxy.endpoint))
    }
}
