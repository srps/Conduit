// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation

package enum DNSWireFormat {

    package static func extractDomainName(from bytes: [UInt8]) -> String {
        var labels: [String] = []
        var offset = 12
        while offset < bytes.count {
            let length = Int(bytes[offset])
            if length == 0 { break }
            offset += 1
            guard offset + length <= bytes.count else { break }
            labels.append(String(bytes: Array(bytes[offset..<offset + length]), encoding: .utf8) ?? "")
            offset += length
        }
        return labels.joined(separator: ".")
    }

    package static func extractQueryType(from bytes: [UInt8]) -> UInt16 {
        var offset = 12
        while offset < bytes.count {
            let length = Int(bytes[offset])
            if length == 0 { offset += 1; break }
            offset += 1 + length
        }
        guard offset + 2 <= bytes.count else { return 1 }
        return UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
    }

    package static func isNXDOMAIN(_ response: [UInt8]) -> Bool {
        guard response.count >= 4 else { return true }
        let rcode = response[3] & 0x0F
        return rcode == 3
    }

    package static func extractRCode(from response: [UInt8]) -> UInt8 {
        guard response.count >= 4 else { return 2 }
        return response[3] & 0x0F
    }

    package static func hasNoAnswers(in response: [UInt8]) -> Bool {
        guard response.count >= 8 else { return true }
        let answerCount = UInt16(response[6]) << 8 | UInt16(response[7])
        return answerCount == 0
    }

    /// Whether a corporate-DNS response should trigger the public DoH path for
    /// external names. VPN split-DNS often returns NXDOMAIN, SERVFAIL, REFUSED,
    /// or NODATA for internet hostnames instead of routing them to a resolver
    /// that can answer.
    package static func shouldFallbackToPublicDoH(internalResponse: [UInt8]?) -> Bool {
        guard let response = internalResponse else { return true }
        switch extractRCode(from: response) {
        case 3, 2, 5: // NXDOMAIN, SERVFAIL, REFUSED
            return true
        case 0 where hasNoAnswers(in: response): // NOERROR / NODATA
            return true
        default:
            return false
        }
    }

    package static func responseByUpdatingTransactionID(_ response: [UInt8], from query: [UInt8]) -> [UInt8] {
        guard response.count >= 2, query.count >= 2 else { return response }
        var updated = response
        updated[0] = query[0]
        updated[1] = query[1]
        return updated
    }

    package static func responseQuestionMatches(query: [UInt8], response: [UInt8]) -> Bool {
        guard query.count >= 12, response.count >= 12 else { return false }
        guard readUInt16(from: query, at: 4) == 1,
              readUInt16(from: response, at: 4) == 1 else {
            return false
        }
        guard let queryQ = readQuestion(in: query),
              let responseQ = readQuestion(in: response) else {
            return false
        }
        return queryQ == responseQ
    }

    package static func minimumTTL(in response: [UInt8]) -> UInt32? {
        guard response.count >= 12 else { return nil }

        var offset = 4
        let questionCount = readUInt16(from: response, at: &offset)
        let answerCount = readUInt16(from: response, at: &offset)
        let authorityCount = readUInt16(from: response, at: &offset)
        let additionalCount = readUInt16(from: response, at: &offset)

        guard let questionCount, let answerCount, let authorityCount, let additionalCount else {
            return nil
        }

        offset = 12

        for _ in 0..<questionCount {
            guard skipName(in: response, offset: &offset), offset + 4 <= response.count else { return nil }
            offset += 4
        }

        let totalRecords = Int(answerCount) + Int(authorityCount) + Int(additionalCount)
        var minimum: UInt32?

        for _ in 0..<totalRecords {
            guard skipName(in: response, offset: &offset), offset + 10 <= response.count else { return minimum }
            offset += 4 // TYPE + CLASS
            guard let ttl = readUInt32(from: response, at: &offset),
                  let rdLength = readUInt16(from: response, at: &offset) else {
                return minimum
            }
            minimum = min(minimum ?? ttl, ttl)
            guard offset + Int(rdLength) <= response.count else { return minimum }
            offset += Int(rdLength)
        }

        return minimum
    }

    /// First `A` record in the answer section, with its TTL.
    ///
    /// CNAMEs share the answer section with the addresses they resolve to and
    /// come first in practice, so "first answer" is not "first address" — their
    /// RDATA is a name, not four octets. Filter on TYPE, not position.
    package static func firstIPv4Answer(in response: [UInt8]) -> (ip: String, ttl: UInt32)? {
        guard response.count >= 12 else { return nil }

        var offset = 4
        guard let questionCount = readUInt16(from: response, at: &offset),
              let answerCount = readUInt16(from: response, at: &offset) else {
            return nil
        }

        offset = 12
        for _ in 0..<questionCount {
            guard skipName(in: response, offset: &offset), offset + 4 <= response.count else { return nil }
            offset += 4
        }

        for _ in 0..<answerCount {
            guard skipName(in: response, offset: &offset), offset + 10 <= response.count else { return nil }
            guard let type = readUInt16(from: response, at: &offset),
                  readUInt16(from: response, at: &offset) != nil, // CLASS
                  let ttl = readUInt32(from: response, at: &offset),
                  let rdLength = readUInt16(from: response, at: &offset),
                  offset + Int(rdLength) <= response.count else {
                return nil
            }

            if type == 1, rdLength == 4 {
                let octets = response[offset..<offset + 4].map(String.init).joined(separator: ".")
                return (octets, ttl)
            }
            offset += Int(rdLength)
        }

        return nil
    }

    package static func isInternalDomain(_ domain: String, config: ProxyConfig) -> Bool {
        let lower = domain.lowercased()
        let internalPatterns = config.dnsEntries.filter(\.enabled).map { $0.domain.lowercased() }
        for pattern in internalPatterns {
            if lower == pattern || lower.hasSuffix(".\(pattern)") {
                return true
            }
        }
        let builtins = ["local"]
        for suffix in builtins {
            if lower == suffix || lower.hasSuffix(".\(suffix)") {
                return true
            }
        }
        return false
    }

    package static func synthesizeDNSResponse(originalQuery: [UInt8], jsonResponse: String, queryType: UInt16 = 1) -> [UInt8]? {
        guard originalQuery.count >= 12,
              hasExactlyOneQuestion(originalQuery),
              let data = jsonResponse.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let status = (json["Status"] as? Int) ?? 0
        let answers = json["Answer"] as? [[String: Any]] ?? []

        let ips = answers.compactMap { answer -> [UInt8]? in
            guard let typeNum = answer["type"] as? Int, typeNum == Int(queryType),
                  let addr = answer["data"] as? String else { return nil }
            if queryType == 1 {
                let octets = addr.split(separator: ".").compactMap { UInt8($0) }
                return octets.count == 4 ? octets : nil
            }
            if queryType == 28 {
                return ipv6Bytes(from: addr)
            }
            return nil
        }

        guard !ips.isEmpty else {
            return emptyDNSResponse(originalQuery: originalQuery, rcode: UInt8(status & 0x0F))
        }

        let txID = Array(originalQuery[0..<2])
        var response: [UInt8] = []
        response.append(contentsOf: txID)
        response.append(contentsOf: [0x81, 0x80])
        response.append(contentsOf: [0x00, 0x01])
        let answerCount = UInt16(ips.count)
        response.append(UInt8(answerCount >> 8))
        response.append(UInt8(answerCount & 0xFF))
        response.append(contentsOf: [0x00, 0x00])
        response.append(contentsOf: [0x00, 0x00])

        if originalQuery.count > 12 {
            var offset = 12
            while offset < originalQuery.count {
                let length = Int(originalQuery[offset])
                if length == 0 {
                    response.append(0)
                    offset += 1
                    break
                }
                response.append(originalQuery[offset])
                offset += 1
                let end = min(offset + length, originalQuery.count)
                response.append(contentsOf: originalQuery[offset..<end])
                offset = end
            }
            if offset + 4 <= originalQuery.count {
                response.append(contentsOf: originalQuery[offset..<offset + 4])
            }
        }

        for ip in ips {
            response.append(contentsOf: [0xC0, 0x0C])
            response.append(UInt8(queryType >> 8))
            response.append(UInt8(queryType & 0xFF))
            response.append(contentsOf: [0x00, 0x01])
            response.append(contentsOf: [0x00, 0x00, 0x00, 0x3C])
            let rdLength = UInt16(ip.count)
            response.append(UInt8(rdLength >> 8))
            response.append(UInt8(rdLength & 0xFF))
            response.append(contentsOf: ip)
        }

        return response
    }

    private static func ipv6Bytes(from address: String) -> [UInt8]? {
        var storage = in6_addr()
        let result = address.withCString { inet_pton(AF_INET6, $0, &storage) }
        guard result == 1 else { return nil }

        return withUnsafeBytes(of: storage) { Array($0) }
    }

    package static func emptyRefusedResponse(originalQuery: [UInt8]) -> [UInt8]? {
        emptyDNSResponse(originalQuery: originalQuery, rcode: 5)
    }

    static func emptyDNSResponse(originalQuery: [UInt8], rcode: UInt8) -> [UInt8]? {
        guard originalQuery.count >= 12, hasExactlyOneQuestion(originalQuery) else { return nil }

        let txID = Array(originalQuery[0..<2])
        var response: [UInt8] = []
        response.append(contentsOf: txID)
        response.append(0x81)
        response.append(0x80 | (rcode & 0x0F))
        response.append(contentsOf: [0x00, 0x01])
        response.append(contentsOf: [0x00, 0x00])
        response.append(contentsOf: [0x00, 0x00])
        response.append(contentsOf: [0x00, 0x00])

        if originalQuery.count > 12 {
            var offset = 12
            while offset < originalQuery.count {
                let length = Int(originalQuery[offset])
                if length == 0 {
                    response.append(0)
                    offset += 1
                    break
                }
                response.append(originalQuery[offset])
                offset += 1
                let end = min(offset + length, originalQuery.count)
                response.append(contentsOf: originalQuery[offset..<end])
                offset = end
            }
            if offset + 4 <= originalQuery.count {
                response.append(contentsOf: originalQuery[offset..<offset + 4])
            }
        }

        return response
    }

    package static func synthesizeDirectResponse(originalQuery: [UInt8], ip: String) -> [UInt8]? {
        guard originalQuery.count >= 12, hasExactlyOneQuestion(originalQuery) else { return nil }

        let qtype = extractQueryType(from: originalQuery)
        if qtype == 28 {
            return emptyDNSResponse(originalQuery: originalQuery, rcode: 0)
        }
        guard qtype == 1 else {
            return emptyDNSResponse(originalQuery: originalQuery, rcode: 5)
        }

        let octets = ip.split(separator: ".").compactMap { UInt8($0) }
        guard octets.count == 4 else { return nil }

        let txID = Array(originalQuery[0..<2])
        var response: [UInt8] = []
        response.append(contentsOf: txID)
        response.append(contentsOf: [0x81, 0x80]) // flags: response, no error
        response.append(contentsOf: [0x00, 0x01]) // 1 question
        response.append(contentsOf: [0x00, 0x01]) // 1 answer
        response.append(contentsOf: [0x00, 0x00]) // 0 authority
        response.append(contentsOf: [0x00, 0x00]) // 0 additional

        var offset = 12
        while offset < originalQuery.count {
            let length = Int(originalQuery[offset])
            if length == 0 {
                response.append(0)
                offset += 1
                break
            }
            response.append(originalQuery[offset])
            offset += 1
            let end = min(offset + length, originalQuery.count)
            response.append(contentsOf: originalQuery[offset..<end])
            offset = end
        }
        if offset + 4 <= originalQuery.count {
            response.append(contentsOf: originalQuery[offset..<offset + 4])
        }

        response.append(contentsOf: [0xC0, 0x0C]) // pointer to domain in question
        response.append(contentsOf: [0x00, 0x01]) // type A
        response.append(contentsOf: [0x00, 0x01]) // class IN
        response.append(contentsOf: [0x00, 0x00, 0x00, 0x05]) // TTL 5s
        response.append(contentsOf: [0x00, 0x04]) // rdlength 4
        response.append(contentsOf: octets)

        return response
    }

    package static func buildQuery(domain: String, txID: UInt16 = 0xABCD, qtype: UInt16 = 1) -> [UInt8] {
        var packet: [UInt8] = []
        packet.append(UInt8(txID >> 8))
        packet.append(UInt8(txID & 0xFF))
        packet.append(contentsOf: [0x01, 0x00]) // flags: standard query, recursion desired
        packet.append(contentsOf: [0x00, 0x01]) // 1 question
        packet.append(contentsOf: [0x00, 0x00]) // 0 answers
        packet.append(contentsOf: [0x00, 0x00]) // 0 authority
        packet.append(contentsOf: [0x00, 0x00]) // 0 additional

        for label in domain.split(separator: ".") {
            let bytes = Array(label.utf8)
            packet.append(UInt8(bytes.count))
            packet.append(contentsOf: bytes)
        }
        packet.append(0) // root label

        packet.append(UInt8(qtype >> 8))
        packet.append(UInt8(qtype & 0xFF))
        packet.append(contentsOf: [0x00, 0x01]) // class IN

        return packet
    }

    private static func readQuestion(in bytes: [UInt8]) -> DNSQuestion? {
        var offset = 12
        guard let labels = readName(in: bytes, offset: &offset),
              let type = readUInt16(from: bytes, at: &offset),
              let klass = readUInt16(from: bytes, at: &offset) else {
            return nil
        }
        return DNSQuestion(labels: labels, type: type, klass: klass)
    }

    private static func hasExactlyOneQuestion(_ bytes: [UInt8]) -> Bool {
        guard bytes.count >= 12, readUInt16(from: bytes, at: 4) == 1 else { return false }
        return readQuestion(in: bytes) != nil
    }

    private static func readName(in bytes: [UInt8], offset: inout Int, depth: Int = 0) -> [String]? {
        guard depth < 8 else { return nil }

        var labels: [String] = []
        var cursor = offset
        var steps = 0

        while cursor < bytes.count, steps < bytes.count {
            let length = bytes[cursor]
            if length == 0 {
                cursor += 1
                offset = cursor
                return labels
            }

            if length & 0xC0 == 0xC0 {
                guard cursor + 1 < bytes.count else { return nil }
                let pointer = (Int(length & 0x3F) << 8) | Int(bytes[cursor + 1])
                guard pointer < bytes.count else { return nil }
                offset = cursor + 2
                var pointedOffset = pointer
                guard let pointedLabels = readName(in: bytes, offset: &pointedOffset, depth: depth + 1) else {
                    return nil
                }
                return labels + pointedLabels
            }

            guard length & 0xC0 == 0 else { return nil }
            cursor += 1
            let labelLength = Int(length)
            guard cursor + labelLength <= bytes.count else { return nil }
            guard let label = String(bytes: bytes[cursor..<cursor + labelLength], encoding: .utf8) else {
                return nil
            }
            labels.append(label.lowercased())
            cursor += labelLength
            offset = cursor
            steps += labelLength + 1
        }

        return nil
    }

    private static func readUInt16(from bytes: [UInt8], at offset: Int) -> UInt16? {
        guard offset + 2 <= bytes.count else { return nil }
        return (UInt16(bytes[offset]) << 8) | UInt16(bytes[offset + 1])
    }

    private static func readUInt16(from bytes: [UInt8], at offset: inout Int) -> UInt16? {
        guard offset + 2 <= bytes.count else { return nil }
        let value = (UInt16(bytes[offset]) << 8) | UInt16(bytes[offset + 1])
        offset += 2
        return value
    }

    private static func readUInt32(from bytes: [UInt8], at offset: inout Int) -> UInt32? {
        guard offset + 4 <= bytes.count else { return nil }
        let value = (UInt32(bytes[offset]) << 24)
            | (UInt32(bytes[offset + 1]) << 16)
            | (UInt32(bytes[offset + 2]) << 8)
            | UInt32(bytes[offset + 3])
        offset += 4
        return value
    }

    private static func skipName(in bytes: [UInt8], offset: inout Int) -> Bool {
        var cursor = offset
        var steps = 0

        while cursor < bytes.count, steps < bytes.count {
            let length = bytes[cursor]
            if length == 0 {
                cursor += 1
                offset = cursor
                return true
            }

            if length & 0xC0 == 0xC0 {
                guard cursor + 1 < bytes.count else { return false }
                cursor += 2
                offset = cursor
                return true
            }

            cursor += 1
            let labelLength = Int(length)
            guard cursor + labelLength <= bytes.count else { return false }
            cursor += labelLength
            offset = cursor
            steps += labelLength + 1
        }

        return false
    }
}

private struct DNSQuestion: Equatable {
    let labels: [String]
    let type: UInt16
    let klass: UInt16
}
