// SPDX-License-Identifier: Apache-2.0
import Foundation
import ProxyKernel

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

package enum ProxyEndpointWitnessFault: String, Sendable {
    case oversized, undecodable, io
    case unsupportedVersion = "unsupported_version"
    case invalidEndpoint = "invalid_endpoint"
}

package enum ProxyEndpointWitnessRead: Equatable, Sendable {
    case absent
    case present(AdvertisedProxyEndpoint)
    case unreadable(ProxyEndpointWitnessFault)
}

package protocol ProxyEndpointWitnessing: Sendable {
    func read() -> ProxyEndpointWitnessRead
    func record(_ endpoint: AdvertisedProxyEndpoint) throws
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
            return .unreadable(.oversized)
        } catch {
            return .unreadable(.io)
        }
        let endpoint: AdvertisedProxyEndpoint
        do {
            endpoint = try CanonicalJSON.decoder().decode(AdvertisedProxyEndpoint.self, from: data)
        } catch {
            return .unreadable(.undecodable)
        }
        guard endpoint.version == AdvertisedProxyEndpoint.formatVersion else { return .unreadable(.unsupportedVersion) }
        guard LocationSettingsRecovery.isLoopback(endpoint.host), (1...65535).contains(endpoint.port) else {
            return .unreadable(.invalidEndpoint)
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
