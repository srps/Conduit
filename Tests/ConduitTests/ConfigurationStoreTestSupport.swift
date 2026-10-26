// SPDX-License-Identifier: Apache-2.0
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

    func commitRuntimeAndPlatform(
        _ runtime: ProxyConfig,
        _ platform: PlatformIntegrationConfig,
        expecting expected: ConfigurationSlots<ConfigurationBaselineToken?>,
        context: ConfigurationOperationContext
    ) async -> ConfigurationStoreAdmission<RuntimePlatformCommitResult> {
        await commitRuntimeAndPlatform(runtime, platform, expecting: expected, context: context, claim: .neverRevoked)
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
