// SPDX-License-Identifier: Apache-2.0

// The scalar bookkeeping shared by every configuration boundary (decisions 0021 and 0022). A lexer reports the decoded
// scalars and the list items it reads, and these counters charge them against the policy. Only the arithmetic lives
// here. The ceilings, their order and the first-violation rule stay in `DomainResourceLimits` and `DomainResourceCheck`,
// so no boundary keeps its own prefix, width or count policy.

/// The decoded size of one configuration string, counted scalar by scalar. An escape counts as the bytes it decodes to,
/// and the canonical width is the width `JSONEncoder` gives the string (`CanonicalJSONWidth`), so raw and escaped
/// spellings of one value charge the same.
package struct DomainResourceStringBudget {
    package private(set) var byteCount = 0
    package private(set) var canonicalBytes = 2
    /// True while every byte so far has matched the wildcard prefix `*.`.
    private var wildcardCandidate = true

    package init() {}

    /// One decoded scalar, raw or escaped. An ASCII scalar counts one byte and may extend the wildcard prefix. A
    /// multibyte scalar is never part of that prefix, so it rules the prefix out.
    package mutating func append(_ scalar: Unicode.Scalar) {
        if scalar.value < 0x80 {
            let byte = UInt8(scalar.value)
            switch byteCount {
            case 0: wildcardCandidate = byte == UInt8(ascii: "*")
            case 1: wildcardCandidate = wildcardCandidate && byte == UInt8(ascii: ".")
            default: break
            }
            byteCount += 1
        } else {
            if byteCount < 2 {
                wildcardCandidate = false
            }
            byteCount += Self.utf8Width(of: scalar)
        }
        canonicalBytes += CanonicalJSONWidth.scalarWidth(scalar.value)
    }

    package var hasWildcardPrefix: Bool {
        byteCount >= 2 && wildcardCandidate
    }

    /// The first ceiling this string crosses for `field`, or nil. A wildcard intercept pattern uses its larger ceiling.
    package func violation(_ field: DomainResourceField) -> DomainResourceViolation? {
        DomainResourceCheck.utf8(byteCount, wildcardPrefix: hasWildcardPrefix, field)
    }

    private static func utf8Width(of scalar: Unicode.Scalar) -> Int {
        switch scalar.value {
        case 0..<0x80: 1
        case 0x80..<0x800: 2
        case 0x800..<0x10000: 3
        default: 4
        }
    }
}

/// The count and the canonical width of one list, charged as its elements are read. A list's count is checked before
/// its element is read, and a string item is charged once it closes, so the first ceiling crossed in item order is the
/// one reported.
package struct DomainResourceListBudget {
    package private(set) var count = 0
    private var encoded = CanonicalJSONStringList()

    package init() {}

    /// Charges one element by its count, before the element is read.
    package mutating func admitElement(_ field: DomainResourceField) -> DomainResourceViolation? {
        count += 1
        return DomainResourceCheck.entries(count, field)
    }

    /// Charges one closed string item to the list's canonical width. The caller calls it only for a list that has one.
    package mutating func closeStringItem(canonicalWidth: Int, list: DomainResourceField) -> DomainResourceViolation? {
        encoded.append(quotedWidth: canonicalWidth)
        return DomainResourceCheck.encodedBytes(encoded.bytes, list)
    }
}
