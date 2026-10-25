// SPDX-License-Identifier: Apache-2.0
import ConduitShared
import Foundation
import ProxyKernel

/// The authoritative files one diagnostic sink must never write, mapped from one runtime environment.
/// Each writer excludes only its own output (`events` for the events writer, `snapshot` for the snapshot
/// writer); every other entry, including the config named by `--config`, applies to every sink.
///
/// File names that belong to the wire or the host (`control.sock`, `daemon-ready.json`) are mapped
/// here, not in `ProxyKernel`, which knows only the resource roles. The set has at most one entry
/// per `ProtectedRecordResource` code. `writerLeaseFile` is explicit: only a composer that adopts
/// the writer lease passes its URL, and the lock name is not guessed here.
package func protectedDiagnosticResources(
    for sink: RecordFileDiagnosticSink,
    in environment: RuntimeEnvironment,
    writerLeaseFile: URL? = nil
) -> [ProtectedRecordFile] {
    var all: [ProtectedRecordFile] = [
        ProtectedRecordFile(resource: .config, url: environment.configFile),
        ProtectedRecordFile(resource: .platformState, url: environment.platformStateFile),
        ProtectedRecordFile(resource: .platformConfig, url: environment.platformConfigFile),
        ProtectedRecordFile(resource: .preferences, url: environment.preferencesFile),
        ProtectedRecordFile(resource: .snapshot, url: environment.snapshotFile),
        ProtectedRecordFile(resource: .legacySavedDNS, url: environment.legacySavedDNSFile),
        ProtectedRecordFile(resource: .events, url: environment.eventsFile),
        ProtectedRecordFile(resource: .ready, url: environment.configDirectory.appendingPathComponent("ready.json")),
        ProtectedRecordFile(resource: .daemonReady,
                            url: environment.configDirectory.appendingPathComponent("daemon-ready.json")),
        ProtectedRecordFile(resource: .control,
                            url: environment.configDirectory.appendingPathComponent(ControlSocket.fileName)),
        ProtectedRecordFile(resource: .updateState, url: environment.updateStateFile),
        ProtectedRecordFile(resource: .log, url: environment.logFile),
    ]
    if let writerLeaseFile {
        all.append(ProtectedRecordFile(resource: .writerLease, url: writerLeaseFile))
    }
    switch sink {
    case .connectionAudit: return all
    case .runtimeEvents: return all.filter { $0.resource != .events }
    case .snapshot: return all.filter { $0.resource != .snapshot }
    }
}

/// The guard a diagnostic writer takes for `sink`, built from `protectedDiagnosticResources`.
/// Composers hold the protocol only; the concrete backend stays inside `ProxyKernel`.
package func diagnosticDestinationGuard(
    for sink: RecordFileDiagnosticSink,
    in environment: RuntimeEnvironment,
    writerLeaseFile: URL? = nil
) -> any RecordFileDestinationGuarding {
    systemRecordFileDestinationGuard(
        protected: protectedDiagnosticResources(for: sink, in: environment, writerLeaseFile: writerLeaseFile)
    )
}
