// SPDX-License-Identifier: Apache-2.0
import ConduitShared
import Foundation
import PlatformMac
import ProxyKernel

/// One value per component, where the component is the kernel's `ConfigurationComponent`. It is the fixed shape of the tokens, the
/// records and the results, so no array or queue is needed.
struct ConfigurationSlots<Value: Sendable>: Sendable {
    var runtime: Value
    var platform: Value
    var preferences: Value

    subscript(component: ConfigurationComponent) -> Value {
        get {
            switch component {
            case .runtime: runtime
            case .platform: platform
            case .preferences: preferences
            }
        }
        set {
            switch component {
            case .runtime: runtime = newValue
            case .platform: platform = newValue
            case .preferences: preferences = newValue
            }
        }
    }
}

extension ConfigurationSlots: Equatable where Value: Equatable {}

/// The caller's context, in the control protocol's own identifier types. The store echoes it on each persistence fact it reports. It
/// identifies a request and does not authenticate one: nothing here checks it, and no authority comes from it (decision 0018).
struct ConfigurationOperationContext: Equatable, Sendable {
    let requestID: ControlRequestID
    let hostIncarnation: ControlHostIncarnation
    let expectedOwnerGeneration: PrivateConfigExpectedGeneration
}

/// A config field path that a staging refusal names. A label is kept only when it is short and made of identifier characters, so a
/// value cannot pass as one.
struct ConfigurationFieldLabel: Equatable, Sendable {
    let rawValue: String

    init?(_ rawValue: String) {
        guard !rawValue.isEmpty, rawValue.count <= 64,
              rawValue.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == ".") })
        else { return nil }
        self.rawValue = rawValue
    }
}

/// Why staging refused a candidate, before any write. Every case is closed. No case keeps a description, a value or raw error text.
enum ConfigurationStagingRefusal: Equatable, Sendable {
    /// A runtime value crosses an approved resource ceiling.
    case resourceLimit
    /// The runtime file's encoded bytes exceed the runtime budget.
    case fileSize
    /// A sidecar value crosses its approved resource ceiling.
    case sidecarResourceLimit
    /// A sidecar's encoded bytes exceed the sidecar budget.
    case sidecarFileSize
    /// The schema-two file cannot hold a field exactly. The label is nil when it is not a valid label, and the requirement is fixed text.
    case representability(field: ConfigurationFieldLabel?, requirement: ConfigFileRepresentabilityError.Requirement)
    /// Staging failed in a way no known refusal describes. Only the error's code is kept.
    case unexpected(code: Int)
}

/// Why a configuration file was not attempted to be written. Each case is a fixed reason, and none carries a configuration value.
enum ConfigurationNotAttemptedReason: Error, Equatable, Sendable {
    /// The store holds no authoritative baseline for the component: its last read failed, its startup refused, or an earlier write
    /// was unknown. Only a reload can establish one again.
    case noAuthoritativeBaseline
    /// The caller's baseline is missing, names another store incarnation, or names an older file version.
    case baselineMismatch
    /// Staging refused the value before any write. No value or raw error text is kept.
    case stagingRefused(ConfigurationStagingRefusal)
    /// The pre-read could not read the file, so no replacement was authorized (decision 0027).
    case preReadFailed(ConfigurationFileError)
    /// The replacement refused its inputs before any I/O: a foreign role, a root it does not hold, or a staged size past its budget.
    case refused(ConfigurationFileReplacementRefusal)
    /// The platform file did not verify, or its baseline is not authorized, so the runtime write was held (decision 0025). Holding it
    /// keeps the runtime rewrite from dropping legacy platform values that the platform file does not yet hold.
    case heldBehindPlatform
    /// The runtime file's baseline is not authorized, so a platform file that is authorized was held behind it. The platform
    /// file's own reason is reported on its outcome, so the two never share one cause.
    case heldBehindRuntime
    /// The runtime rewrite was held to keep legacy preference values that the runtime file carries. The reason names the sidecar's state,
    /// and the runtime bytes are preserved. A platform write that already verified is not undone.
    case preservationHeld(ConfigurationPreservationHold)
    /// The component's file version is at its maximum, so a verified write could not name a newer version. The write is refused before
    /// any I/O. Verification and latching still work, and only a new store incarnation recovers.
    case versionExhausted
}

/// Why a runtime rewrite was held so that legacy preference values the runtime file carries are not dropped unseen (decision 0026). The
/// preferences sidecar is the only file the guard checks. Each case names a closed state, and none carries a value.
enum ConfigurationPreservationHold: Equatable, Sendable {
    /// The sidecar is absent, so the runtime file's legacy values have no saved home. Saving the preferences first, then retrying, is the path.
    case sidecarAbsent
    /// The store holds no authoritative baseline for the sidecar: its load was refused, or an earlier check or write was unknown.
    case noAuthoritativeSidecarBaseline
    /// The sidecar changed since its baseline: it was deleted, created or edited. The baseline is latched until a reload.
    case sidecarChanged
    /// The check could not read the sidecar, so its state is not established. Nothing is latched, and the same check may succeed later.
    case sidecarUnreadable(ConfigurationFileError)
    /// The check was refused before any I/O.
    case refused(ConfigurationFileReplacementRefusal)
}

/// The persistence result of one component's write. It is typed, and it says only what the store verified.
enum ConfigurationWriteOutcome: Equatable, Sendable {
    /// Read-back equals the staged bytes. The receipt names the file version it made current. `reportedWriteError` is the
    /// replacement's own error, when it reported one, because a failed write may still have landed.
    case persisted(ConfigurationReceipt, reportedWriteError: ConfigurationFileWriteError?)
    /// The component was present and its verified value already was the candidate, so it was verified without a save (decision 0018).
    case unchanged(ConfigurationReceipt)
    /// The replacement reported an error and read-back shows the file it observed before, so nothing new is on disk.
    case notPersisted(ConfigurationFileWriteError)
    /// Read-back cannot say which state the file is in. The store then holds no baseline for the file (decision 0018).
    case unknown(ConfigurationFileUnknownReason, reportedWriteError: ConfigurationFileWriteError?)
    /// The file changed after its baseline was observed (decision 0027). Nothing was written, and the file and the draft are kept.
    case conflict
    /// No write was attempted.
    case notAttempted(ConfigurationNotAttemptedReason)
}

/// The result of checking one component against its baseline without writing it.
enum ConfigurationVerifyOutcome: Equatable, Sendable {
    /// The file still matches its baseline and existed, so the receipt names the version that is current. No bytes were rewritten.
    case unchanged(ConfigurationReceipt)
    /// The file is still missing, as its absent baseline says. Absence is never a receipt.
    case unchangedAbsent
    /// The file changed since its baseline (decision 0027). The store does not adopt the new bytes.
    case changed
    /// The check could not read the file, so it establishes nothing.
    case notVerified(ConfigurationFileError)
    /// The check was not made.
    case notAttempted(ConfigurationNotAttemptedReason)
}

/// The outcomes of one coupled runtime and platform commit. Each write is independent; the platform write is first.
struct RuntimePlatformCommitResult: Equatable, Sendable {
    let context: ConfigurationOperationContext
    let runtime: ConfigurationWriteOutcome
    let platform: ConfigurationWriteOutcome
}

/// The outcome of one preferences commit, which is independent of the runtime and platform commit.
struct PreferencesCommitResult: Equatable, Sendable {
    let context: ConfigurationOperationContext
    let preferences: ConfigurationWriteOutcome
}

/// The outcomes of one verification. A component that was not requested has no outcome.
struct ConfigurationVerifyResult: Equatable, Sendable {
    let context: ConfigurationOperationContext
    let outcomes: ConfigurationSlots<ConfigurationVerifyOutcome?>
}

/// Whether an operation ran. `busy` means another operation holds the store's one slot. Nothing is queued, and the caller's
/// body is not retained.
enum ConfigurationStoreAdmission<Value: Sendable>: Sendable {
    case admitted(Value)
    case busy
}

extension ConfigurationStoreAdmission: Equatable where Value: Equatable {}

/// What one loaded component was when it was read. The load itself never writes, so a pending migration stays pending.
struct ConfigurationComponentLoad: Equatable, Sendable {
    let present: Bool
    let migrationPending: Bool
    /// The fallback the shared loader took for this component, or nil. The kernel's loader owns its classification and text, and the
    /// store carries the typed case, so a fallback is reported, not dropped.
    let fallback: ConfigurationLegacyFallback?

    init(present: Bool, migrationPending: Bool, fallback: ConfigurationLegacyFallback? = nil) {
        self.present = present
        self.migrationPending = migrationPending
        self.fallback = fallback
    }
}

/// The loader's fixed reason for a refused decode, kept only when it is short printable ASCII. A reason the shared loader writes is a
/// literal, and every one is far below the bound. A longer or non-ASCII text is not kept, and the refusal falls back to its code.
struct ConfigurationLoadReason: Equatable, Sendable {
    static let maximumLength = 160

    let rawValue: String

    init?(_ rawValue: String) {
        guard !rawValue.isEmpty, rawValue.count <= Self.maximumLength,
              rawValue.allSatisfy({ $0.isASCII && $0 >= " " && $0 <= "~" })
        else { return nil }
        self.rawValue = rawValue
    }
}

/// Why a load could not adopt its observation. The store then keeps its last values for display and holds no baseline.
enum ConfigurationLoadRefusal: Error, Equatable, Sendable {
    case unreadable(ConfigurationComponent, ConfigurationFileError)
    /// The journal's presence could not be checked. The loader's defaults decision depends on it, so holding is the only safe result.
    case journalPresenceUnknown(ConfigurationPresenceError)
    /// The shared decode refused one of the files. `reason` is the loader's fixed text, which names no value. Only
    /// `ConfigurationFrozenLoader.decode` produces it, and each reason it throws is a literal of the kernel's loader (the runtime envelope,
    /// the sidecar gate and the typed decoders). A caller that adds raw input to a loader reason must change this contract and its test.
    case invalidContent(reason: ConfigurationLoadReason)
    /// The decode failed in a way no known refusal describes. Only the error's code is kept.
    case unexpected(code: Int)
    /// A changed baseline needs a newer version for a component that is already at its maximum. Nothing is adopted, and only a new
    /// store incarnation recovers.
    case versionExhausted(ConfigurationComponent)
}

enum ConfigurationLoadOutcome: Equatable, Sendable {
    case adopted(ConfigurationSlots<ConfigurationComponentLoad>)
    case refused(ConfigurationLoadRefusal)
}

struct ConfigurationLoadReport: Equatable, Sendable {
    let context: ConfigurationOperationContext
    let outcome: ConfigurationLoadOutcome
}

/// The current parsed values. Each one came out of the shared decode of the bytes the store observed or verified.
struct ConfigurationValues: Sendable {
    var runtime: ProxyConfig
    var platform: PlatformIntegrationConfig
    var preferences: AppPreferences
}
