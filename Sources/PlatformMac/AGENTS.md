# PlatformMac

macOS glue: Keychain, `networksetup`, `SMAppService`, the SCDynamicStore VPN observer, `NWPathMonitor`, the helper XPC client, the `/etc/resolver` writer, and the lifecycle policy both hosts share (`RuntimeReconciler`, `PlatformIntegrationReconciler`, `SplitDNSVPNGate`, `PlatformStateJournal`, `LaunchRecovery`).

- Every machine side effect is called from here, behind a protocol, never from `ProxyKernel`.
- The fakes (`FakeMachine`, `RecordingPrivilegeClient`, `FakeLoginItems`, `FakeHelperLifecycle`, `InMemorySecretStore`) live in `PlatformFakes.swift` under `Sources`, not `Tests`, because the app's `--dev` mode is an executable and SwiftPM lets only a test target import a test target. A new side-effecting collaborator adds its fake here.
