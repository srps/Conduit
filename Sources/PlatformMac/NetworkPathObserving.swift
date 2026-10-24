// SPDX-License-Identifier: Apache-2.0
import ProxyKernel

/// Producer interface for debounced network-path reports. The production
/// observer is `NetworkMonitor` (`NWPathMonitor`). `FakeNetworkPathObserver`
/// in `PlatformFakes.swift` is the injection point, so a host test never reads
/// the machine's network. Mirrors `VPNStatusObserving`.
///
/// The observer is owned by one runtime and never handed across isolation
/// domains, so it is not `Sendable`. The owner calls `setOnChange`, `start`
/// and `stop` serially. The callback is the only part that crosses: it may
/// arrive on any queue, including one already selected before `stop()`.
package protocol NetworkPathObserving: AnyObject {
    /// Set by the consumer before `start()`. Implementations may invoke this on
    /// any queue; the consumer hops to its own isolation context.
    func setOnChange(_ onChange: @Sendable @escaping (NetworkPathState) -> Void)

    /// Begin observing.
    func start()

    /// Stop observing and release the underlying monitor.
    func stop()
}
