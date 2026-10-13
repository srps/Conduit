// SPDX-License-Identifier: Apache-2.0

/// The kernel has no machine side effects (`Sources/ProxyKernel/AGENTS.md`).
/// This shadows `Foundation.Process` inside ProxyKernel, so naming it fails to
/// compile in every configuration; `scripts/check-kernel-imports.py` catches a
/// qualified `Foundation.Process` in the built object.
@available(*, unavailable, message: "ProxyKernel must not run processes; put it behind a PlatformMac protocol")
struct Process {}
