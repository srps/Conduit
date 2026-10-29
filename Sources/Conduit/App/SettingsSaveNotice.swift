// SPDX-License-Identifier: Apache-2.0
import ConduitShared
import Foundation
import ProxyControlBridge
import ProxyKernel
import RuntimeEvents

/// What one Settings editor save writes, as its notices name it.
enum SettingsSave: Equatable {
    /// The runtime and platform files, as one private update.
    case configuration
    case preferences
    /// The login-item flag, the platform file's admin write.
    case launchAtLogin

    init(_ group: RuntimeEditorLedger.Group?) {
        switch group {
        case .configuration: self = .configuration
        case .preferences: self = .preferences
        case nil: self = .launchAtLogin
        }
    }

    init(_ kind: RuntimeEditorLedger.Submission.Kind) {
        switch kind {
        case .configuration: self = .configuration
        case .preferences: self = .preferences
        case .launchAtLogin: self = .launchAtLogin
        }
    }

    /// The files it writes.
    var files: String {
        switch self {
        case .configuration: "runtime,platform"
        case .preferences: "preferences"
        case .launchAtLogin: "platform"
        }
    }
}

/// Why the editor sent nothing for a save, or why the host recorded nothing for it. Closed: every case carries a closed code or a field's
/// name and its ceiling, never a value.
enum SettingsSaveRefusal: Equatable {
    /// A value past an approved ceiling (decision 0021).
    case resourceLimit(DomainResourceViolation)
    /// A value the schema-two runtime file cannot hold exactly (decision 0023), by field and requirement, as the store's own staging
    /// refuses it.
    case notStorable(field: String, requirement: ConfigFileRepresentabilityError.Requirement)
    case tooLarge
    /// The request could not be framed: the wire's own closed refusal.
    case notRepresentable(PrivateConfigurationWireError)
    /// The client refused it before sending, with its closed code.
    case clientRefused(ControlRuntimeErrorCode)
    /// A file lost its baseline; only an explicit reload lets the editor write it again.
    case needsReload
    /// The host recorded nothing: refused at admission, or never sent (nil).
    case notAdmitted(ControlRejectionCode?)
    /// A login-item change while a save is out: refused, never queued where a quit would drop it.
    case editorBusy

    var detail: String {
        switch self {
        case .resourceLimit(let violation): "reason=resource_limit field=\(violation.field) limit=\(violation.limit)"
        case .notStorable(let field, let requirement): "reason=not_storable field=\(field) requirement=\(Self.code(requirement))"
        case .tooLarge: "reason=too_large"
        case .notRepresentable(let error): "reason=not_representable error=\(Self.code(error))"
        case .clientRefused(let code): "reason=local_refusal code=\(code.rawValue)"
        case .needsReload: "reason=needs_reload"
        case .notAdmitted(let code): "reason=not_admitted code=\(code?.rawValue ?? "not_sent")"
        case .editorBusy: "reason=editor_busy"
        }
    }

    static func code(_ requirement: ConfigFileRepresentabilityError.Requirement) -> String {
        switch requirement {
        case .finiteNumber: "finite_number"
        case .runtimeRange: "runtime_range"
        case .wholeMilliseconds: "whole_milliseconds"
        case .wholeMinutes: "whole_minutes"
        case .unchangedDecoding: "unchanged_decoding"
        }
    }

    private static func code(_ error: PrivateConfigurationWireError) -> String {
        switch error {
        case .frameTooLarge: "frame_too_large"
        case .unsupportedVersion: "unsupported_version"
        case .unexpectedFrameKind: "unexpected_frame_kind"
        case .malformedHeader: "malformed_header"
        case .malformedBody: "malformed_body"
        case .invalidValue: "invalid_value"
        case .invalidState: "invalid_state"
        case .resourceLimitExceeded: "resource_limit"
        }
    }
}

/// Where a save the app waited for came from.
enum SettingsSaveTrigger: String {
    case save
    /// A final save the quit declared.
    case quit
    /// The update out when the quit began.
    case quitPrior = "quit_prior"
}

/// How a save that did not verify ended.
enum SettingsSaveVerdict: Equatable {
    /// One file's write, in the domain's own spelling (`config.workflow.committed`).
    case file(ConfigurationWorkflowFile, ConfigurationWorkflowWrite)
    /// The whole save, when no per-file receipt says more.
    case whole(SettingsSave, SettingsSaveEnd)
}

enum SettingsSaveEnd: Equatable {
    case failed(ControlFailureCode)
    /// Lost, superseded or partial: what was written is unknown.
    case unknown
    case notAdmitted(ControlRejectionCode)
    case notSent
    /// The host cannot name the request.
    case notRecorded(ControlUnknownOutcomeReason)
    case unsettled
    case clientFailure
    /// The quit itself was not admitted, so the save was never attempted.
    case quitNotAdmitted
    /// An admitted login-item change the quit's fence stopped before it was sent.
    case quitBegan

    var detail: String {
        switch self {
        case .failed(let code): "outcome=failed code=\(code.rawValue)"
        case .unknown: "outcome=unknown"
        case .notAdmitted(let code): "outcome=not_admitted code=\(code.rawValue)"
        case .notSent: "outcome=not_sent"
        case .notRecorded(let reason): "outcome=unknown cause=\(reason.rawValue)"
        case .unsettled: "outcome=unknown cause=unsettled"
        case .clientFailure: "outcome=unknown cause=client_failure"
        case .quitNotAdmitted: "outcome=not_attempted cause=quit_not_admitted"
        case .quitBegan: "outcome=not_attempted cause=quit_began"
        }
    }
}

/// The Settings editor's own notices, event first: the name and the detail are derived from typed values, and carry no value.
enum SettingsSaveNotice: Equatable {
    /// `config.save_rejected`: nothing was written.
    case rejected(SettingsSave, SettingsSaveRefusal)
    /// `config.save_unverified`: a save the app waited for did not verify. `reloadNeeded` says whether a file now needs an explicit
    /// reload; nil when the quit has ended the editor and no reload follows.
    case unverified(SettingsSaveTrigger, SettingsSaveVerdict, reloadNeeded: Bool?)

    var name: String {
        switch self {
        case .rejected: "config.save_rejected"
        case .unverified: "config.save_unverified"
        }
    }

    var detail: String {
        switch self {
        case .rejected(let save, let refusal):
            return "file=\(save.files) \(refusal.detail)"
        case .unverified(let trigger, let verdict, let reloadNeeded):
            let head: String
            switch verdict {
            case .file(let file, let write): head = "trigger=\(trigger.rawValue) file=\(file.rawValue) \(write.detail)"
            case .whole(let save, let end): head = "trigger=\(trigger.rawValue) file=\(save.files) \(end.detail)"
            }
            return reloadNeeded.map { "\(head) reload_needed=\($0)" } ?? head
        }
    }

    var event: RuntimeEvent {
        RuntimeEvent(kind: .config, event: name, detail: detail)
    }

    /// The notices for a settled save: one per file a receipt did not verify, the login item's platform write included, or one for the
    /// whole save when it settled with no receipt. A verified write and a completion that wrote no file give none.
    static func unverified(
        _ outcome: ControlOperationOutcome, of save: SettingsSave, trigger: SettingsSaveTrigger, reloadNeeded: Bool?
    ) -> [SettingsSaveNotice] {
        let writes: [(ConfigurationWorkflowFile, ControlConfigWorkflowWrite)]
        switch outcome {
        case .configurationSettled(let receipt):
            writes = [(.runtime, receipt.runtime.write), (.platform, receipt.platform.write)]
        case .preferencesSettled(let receipt):
            writes = [(.preferences, receipt.preferences.write)]
        case .completed(let completion):
            guard case .platformWrite(let write) = completion.result else { return [] }
            writes = [(.platform, write.write)]
        case .failed(let code):
            return [.unverified(trigger, .whole(save, .failed(code)), reloadNeeded: reloadNeeded)]
        case .superseded, .partiallyCompleted:
            return [.unverified(trigger, .whole(save, .unknown), reloadNeeded: reloadNeeded)]
        }
        return writes.filter { !$0.1.isVerified }.map { file, write in
            .unverified(trigger, .file(file, ConfigurationWorkflowWrite(write)), reloadNeeded: reloadNeeded)
        }
    }
}
