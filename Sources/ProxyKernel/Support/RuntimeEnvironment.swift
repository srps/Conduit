// SPDX-License-Identifier: Apache-2.0
import Foundation

package struct RuntimeEnvironment: Sendable, Equatable {
    package var configDirectory: URL
    package var configFile: URL
    /// Prior values of platform settings Conduit changed, so teardown can
    /// restore them instead of blanket-clearing. See `PlatformStateJournal`.
    package var platformStateFile: URL
    package var exportDefaultFile: URL
    package var platformConfigFile: URL
    package var preferencesFile: URL
    package var snapshotFile: URL
    package var eventsFile: URL

    package init(
        configDirectory: URL,
        configFile: URL? = nil,
        platformStateFile: URL? = nil,
        exportDefaultFile: URL? = nil,
        platformConfigFile: URL? = nil,
        preferencesFile: URL? = nil,
        snapshotFile: URL? = nil,
        eventsFile: URL? = nil
    ) {
        self.configDirectory = configDirectory
        self.configFile = configFile ?? configDirectory.appendingPathComponent("config.json")
        self.platformStateFile = platformStateFile
            ?? configDirectory.appendingPathComponent("platform-state.json")
        self.exportDefaultFile = exportDefaultFile
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Conduit-config.json")
        self.platformConfigFile = platformConfigFile ?? configDirectory.appendingPathComponent("platform.json")
        self.preferencesFile = preferencesFile ?? configDirectory.appendingPathComponent("preferences.json")
        self.snapshotFile = snapshotFile ?? configDirectory.appendingPathComponent("snapshot.json")
        self.eventsFile = eventsFile ?? configDirectory.appendingPathComponent("events.ndjson")
    }

    /// Where 0.1.x kept the pre-relay DNS servers before the journal existed.
    /// Read once at launch to seed the journal, then removed.
    package var legacySavedDNSFile: URL {
        configDirectory.appendingPathComponent("saved-dns.json")
    }

    package static func userDefault() -> RuntimeEnvironment {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let directory = base.appendingPathComponent("Conduit", isDirectory: true)
        return RuntimeEnvironment(configDirectory: directory)
    }

    package static func isolated(stateDirectory: URL) -> RuntimeEnvironment {
        RuntimeEnvironment(configDirectory: stateDirectory)
    }

    package static func explicit(configFile: URL) -> RuntimeEnvironment {
        RuntimeEnvironment(
            configDirectory: configFile.deletingLastPathComponent(),
            configFile: configFile
        )
    }
}
