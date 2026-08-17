// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Why a string is not usable as a domain name here. One case per reason,
/// because every caller either shows it to a user (Settings) or writes it to a
/// log an operator reads — and "invalid domain" tells neither of them which
/// character to change.
public enum DomainNameError: Error, LocalizedError, Equatable, Sendable {
    case empty
    /// More than 253 characters. RFC 1035 §2.3.4 bounds a name at 255 wire
    /// octets, which is 253 in presentation form (the root label and one
    /// length byte are not written).
    case tooLong(count: Int)
    /// A label longer than the 63 octets RFC 1035 §2.3.4 allows.
    case labelTooLong(label: String, count: Int)
    /// An empty label: `foo..bar`, a leading dot, or a bare `.`. Distinct from
    /// `trailingDot`, which is the one empty label people write on purpose.
    case emptyLabel
    case trailingDot
    case labelStartsWithHyphen(label: String)
    case labelEndsWithHyphen(label: String)
    case invalidCharacter(Character, label: String)
    case nonASCII(Character)

    public var errorDescription: String? {
        switch self {
        case .empty:
            return "A domain name cannot be empty."
        case .tooLong(let count):
            return "A domain name may be at most 253 characters; this one is \(count)."
        case .labelTooLong(let label, let count):
            return "The label '\(label)' is \(count) characters; a label may be at most 63."
        case .emptyLabel:
            return "A domain name cannot contain an empty label (no leading dot, and no '..')."
        case .trailingDot:
            return "Remove the trailing dot. 'example.com.' and 'example.com' name the same "
                 + "domain but would become two different files under /etc/resolver, and only "
                 + "one of them would ever match."
        case .labelStartsWithHyphen(let label):
            return "The label '\(label)' starts with a hyphen, which is not allowed."
        case .labelEndsWithHyphen(let label):
            return "The label '\(label)' ends with a hyphen, which is not allowed."
        case .invalidCharacter(let character, let label):
            return "'\(Self.describe(character))' in the label '\(label)' is not allowed. "
                 + "Domain labels may contain letters, digits, '-' and '_'."
        case .nonASCII(let character):
            return "'\(character)' is not ASCII. Supply the A-label form (the 'xn--' encoding, "
                 + "RFC 5890) instead of the Unicode spelling."
        }
    }

    /// Control characters have no printable form, so name them by code point
    /// rather than emitting them into a log line or a Settings label.
    private static func describe(_ character: Character) -> String {
        guard let scalar = character.unicodeScalars.first,
              character.unicodeScalars.count == 1,
              scalar.value < 0x20 || scalar.value == 0x7f else {
            return String(character)
        }
        return String(format: "U+%04X", scalar.value)
    }
}

/// The one domain-name grammar in this package.
///
/// **What this is a grammar for.** `/etc/resolver/<domain>` names a resolution
/// *domain* and a DNS intercept pattern names a *suffix*. Neither is a
/// hostname, so RFC 952 / RFC 1123 §2.1 LDH — which is hostname syntax — is the
/// wrong rule for both, and RFC 1035 §2.3.1 says so itself: its LDH is the
/// "preferred name syntax", a preference, not a protocol restriction. RFC 2181
/// §11 is the one that governs domain names, and it restricts only length:
/// "any binary string whatever can be used as the label of any resource
/// record." RFC 8552 / RFC 8553 then formalise underscore-prefixed labels, and
/// RFC 2782 mandates them — `_http._tcp`, `_dmarc`, `_acme-challenge`,
/// `selector._domainkey` are ordinary names that LDH rejects.
///
/// Verified live on macOS 26: `/etc/resolver/foo_bar.example` is honoured, and
/// `scutil --dns` reports it as a resolver for `domain : foo_bar.example`. An
/// underscore in a resolver filename is not a theoretical allowance.
///
/// **Why it is not RFC 2181's "any binary string".** These strings are
/// simultaneously a path component under `/etc/resolver/` and argv to a
/// root-privileged `networksetup`. `/`, NUL, a leading `-`, and a leading `.`
/// change what the filesystem or the command does, so the grammar is RFC 1035
/// presentation format narrowed to what is safe in those two positions:
///
/// - at most 253 characters, non-empty
/// - split on `.`, with no empty label
/// - each label 1…63 octets
/// - ASCII letters, digits, `-` and `_`
/// - no leading or trailing `-` in a label (RFC 1123's hyphen rule, and a
///   leading `-` is also the argv hazard)
/// - ASCII only; non-ASCII must arrive already converted to A-label (`xn--`)
///   form per RFC 5890, because that is what goes on the wire and what the
///   filename has to be
///
/// Single-label names stay valid: `localhost` is a real resolver domain.
///
/// **Trailing dot: rejected, not normalised.** `example.com.` and
/// `example.com` are the same domain in DNS, but this validator's answer is
/// consumed as a *filename* and as an argv token, and it hands the caller back
/// nothing — only a yes or a no. Stripping the dot here would therefore be a
/// lie: the caller would still write `/etc/resolver/example.com.`, still store
/// the dotted spelling in the config, and `DNSInterceptRule.matches` would
/// still compare it literally against undotted query names and never match. One
/// domain configured twice under two filenames, one of which silently does
/// nothing, is worse than a refusal the user fixes by deleting one character.
/// If a caller ever wants normalisation it belongs at that caller, before it
/// stores the value — not hidden inside a predicate.
public enum DomainNameSyntax {
    public static let maxLength = 253
    public static let maxLabelLength = 63

    public static func validate(_ domain: String) throws(DomainNameError) {
        guard !domain.isEmpty else { throw .empty }

        // Ahead of the length check so a Unicode spelling is told what to do
        // rather than told it is too long, which it usually also is once
        // UTF-8 encoded.
        for character in domain where !character.isASCII {
            throw .nonASCII(character)
        }

        guard domain.count <= maxLength else { throw .tooLong(count: domain.count) }
        guard !domain.hasSuffix(".") else { throw .trailingDot }

        for label in domain.split(separator: ".", omittingEmptySubsequences: false) {
            guard !label.isEmpty else { throw .emptyLabel }
            guard label.count <= maxLabelLength else {
                throw .labelTooLong(label: String(label), count: label.count)
            }
            guard !label.hasPrefix("-") else { throw .labelStartsWithHyphen(label: String(label)) }
            guard !label.hasSuffix("-") else { throw .labelEndsWithHyphen(label: String(label)) }
            for character in label where !isAllowedInLabel(character) {
                throw .invalidCharacter(character, label: String(label))
            }
        }
    }

    public static func isValid(_ domain: String) -> Bool {
        do {
            try validate(domain)
            return true
        } catch {
            return false
        }
    }

    /// Compared as ASCII code points rather than via `Character.isLetter` /
    /// `.isNumber`, which are Unicode properties — `Ⅻ` is a number and `ｅ` is
    /// a letter — and rather than via `Character` range patterns, whose
    /// ordering is Unicode collation rather than code-point order. The caller
    /// has already rejected non-ASCII, but the only copy of a grammar should
    /// not depend on that ordering to stay correct.
    private static func isAllowedInLabel(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first,
              character.unicodeScalars.count == 1 else { return false }
        switch scalar.value {
        case 0x61...0x7A, 0x41...0x5A, 0x30...0x39: return true  // a-z, A-Z, 0-9
        case 0x2D, 0x5F: return true                             // '-', '_'
        default: return false
        }
    }
}
