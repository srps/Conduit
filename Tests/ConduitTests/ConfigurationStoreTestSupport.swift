// SPDX-License-Identifier: Apache-2.0
import ConduitShared
import Foundation
import PlatformMac
@testable import ConduitRuntime
@testable import ProxyKernel

/// Test-only call shapes over the store's explicit API. Production passes `allowMissing` and a workflow claim on every call. A store
/// test that is not about either names its fixed choice here: the startup's usual `allowMissing: true`, and a claim that never revokes.
/// Tests that exercise a revoked claim call the explicit methods directly.
extension ConfigurationStore {
    func load(context: ConfigurationOperationContext) async -> ConfigurationStoreAdmission<ConfigurationLoadReport> {
        await load(context: context, allowMissing: true)
    }

    /// An explicit candidate through the one coupled commit, at the named tokens. The capture ignores the store's values, as a frozen
    /// editor candidate does, so the store's authority alone decides each file.
    func commitRuntimeAndPlatform(
        _ runtime: ProxyConfig,
        _ platform: PlatformIntegrationConfig,
        expecting expected: ConfigurationSlots<ConfigurationBaselineToken?>,
        context: ConfigurationOperationContext,
        claim: ConfigurationWriteClaim = .neverRevoked
    ) async -> ConfigurationStoreAdmission<RuntimePlatformCommitResult> {
        switch await commitCapturedRuntimeAndPlatform(expecting: expected, context: context, claim: claim, capture: { _ in (runtime, platform) }) {
        case .busy:
            return .busy
        case .admitted(let result?):
            return .admitted(result)
        case .admitted(nil):
            preconditionFailure("an explicit candidate is always committed")
        }
    }

    func commitPreferences(
        _ preferences: AppPreferences,
        expecting expected: ConfigurationBaselineToken?,
        context: ConfigurationOperationContext
    ) async -> ConfigurationStoreAdmission<PreferencesCommitResult> {
        await commitPreferences(preferences, expecting: expected, context: context, claim: .neverRevoked)
    }
}

extension ConfigurationWriteClaim {
    /// A claim that never revokes, for store tests whose subject is not the workflow's admission.
    static let neverRevoked = ConfigurationWriteClaim { true }
}
