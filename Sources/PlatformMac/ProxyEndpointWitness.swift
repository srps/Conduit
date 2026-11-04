// SPDX-License-Identifier: Apache-2.0
import Foundation
import ProxyKernel

/// The loopback HTTP/HTTPS endpoint a port-0 session advertised from its ephemeral bind (#269). The journal records the
/// same value per service; this copy exists for the launch where the journal is unreadable, so recovery can tell its own
/// residue from another tool's loopback proxy by exact host and port.
package struct AdvertisedProxyEndpoint: Codable, Equatable, Sendable {
    package static let formatVersion = 1
    package var version: Int = Self.formatVersion
    package var host: String
    package var port: Int

    package init(host: String, port: Int) {
        self.host = host
        self.port = port
    }
}

package enum ProxyEndpointWitnessRead: Equatable, Sendable {
    case absent
    case present(AdvertisedProxyEndpoint)
    /// A record that exists and is refused. The reason is a closed token: `oversized`, `undecodable`,
    /// `unsupported_version`, `invalid_endpoint` or `io`.
    case unreadable(reason: String)
}

/// Holds the advertised endpoint while a port-0 manual apply is outstanding (decision 0040).
package protocol ProxyEndpointWitnessing: Sendable {
    func read() -> ProxyEndpointWitnessRead
    func record(_ endpoint: AdvertisedProxyEndpoint) throws
    /// A missing record is success.
    func retire() throws
}

package struct FileProxyEndpointWitness: ProxyEndpointWitnessing {
    package static let maximumBytes = 1024
    package let fileURL: URL

    package init(fileURL: URL) {
        self.fileURL = fileURL
    }

    package static func beside(journalFile: URL) -> FileProxyEndpointWitness {
        FileProxyEndpointWitness(fileURL: RuntimeEnvironment.proxyEndpointWitnessFile(besideJournal: journalFile))
    }

    package func read() -> ProxyEndpointWitnessRead {
        let data: Data
        do throws(ConfigurationFileError) {
            data = try ConfigurationFileReader.read(at: fileURL, limit: Self.maximumBytes)
        } catch .missing {
            return .absent
        } catch .unreadable(.tooLarge(_), _) {
            return .unreadable(reason: "oversized")
        } catch {
            return .unreadable(reason: "io")
        }
        let endpoint: AdvertisedProxyEndpoint
        do {
            endpoint = try CanonicalJSON.decoder().decode(AdvertisedProxyEndpoint.self, from: data)
        } catch {
            return .unreadable(reason: "undecodable")
        }
        guard endpoint.version == AdvertisedProxyEndpoint.formatVersion else { return .unreadable(reason: "unsupported_version") }
        guard LocationSettingsRecovery.isLoopback(endpoint.host), (1...65535).contains(endpoint.port) else {
            return .unreadable(reason: "invalid_endpoint")
        }
        return .present(endpoint)
    }

    package func record(_ endpoint: AdvertisedProxyEndpoint) throws {
        let data = try CanonicalJSON.encoder().encode(endpoint)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }

    package func retire() throws {
        do {
            try FileManager.default.removeItem(at: fileURL)
        } catch CocoaError.fileNoSuchFile {
            return
        }
    }
}
