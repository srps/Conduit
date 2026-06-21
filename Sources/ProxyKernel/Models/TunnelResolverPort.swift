// SPDX-License-Identifier: Apache-2.0
// Kernel-side constant for the tunnel-DNS-override listener port. Extracted
// from `TunnelResolverManager` so the kernel's `TunnelForwarder` and
// `ProxyOrchestrator` can reference the value without importing a PlatformMac
// type. `TunnelResolverManager` (which writes `/etc/resolver/*` files carrying
// this port) lives in `PlatformMac` and reads the constant from here.
//
// The literal 15053 is chosen to sit well above privileged ports (< 1024) and
// out of common service ranges; historically co-located with the resolver-file
// management for proximity, now lives in the kernel because the listener it
// configures is kernel-side (`TunnelDNSResponder`).

import Foundation

package enum TunnelResolverPort {
    package static let port: Int = 15053
}
