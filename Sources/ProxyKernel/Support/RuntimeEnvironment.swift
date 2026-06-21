// SPDX-License-Identifier: Apache-2.0
import Foundation

package struct RuntimeEnvironment: Sendable, Equatable {
    package var configDirectory: URL
    package var configFile: URL
    package var savedDNSFile: URL
    package var exportDefaultFile: URL
    package var platformConfigFile: URL
    package var preferencesFile: URL
    package var snapshotFile: URL
    package var eventsFile: URL

    package init(
        configDirectory: URL,
        configFile: URL? = nil,
        savedDNSFile: URL? = nil,
        exportDefaultFile: URL? = nil,
        platformConfigFile: URL? = nil,
        preferencesFile: URL? = nil,
        snapshotFile: URL? = nil,
        eventsFile: URL? = nil
    ) {
        self.configDirectory = configDirectory
        self.configFile = configFile ?? configDirectory.appendingPathComponent("config.json")
        self.savedDNSFile = savedDNSFile ?? configDirectory.appendingPathComponent("saved-dns.json")
        self.exportDefaultFile = exportDefaultFile
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Conduit-config.json")
        self.platformConfigFile = platformConfigFile ?? configDirectory.appendingPathComponent("platform.json")
        self.preferencesFile = preferencesFile ?? configDirectory.appendingPathComponent("preferences.json")
        self.snapshotFile = snapshotFile ?? configDirectory.appendingPathComponent("snapshot.json")
        self.eventsFile = eventsFile ?? configDirectory.appendingPathComponent("events.ndjson")
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
