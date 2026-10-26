// SPDX-License-Identifier: Apache-2.0

/// Byte-for-byte comparison of configured text (#246). Swift `==` compares Unicode canonical equivalence, so a precomposed `é` and an
/// `e` with a combining accent are equal, though their UTF-8 differs. The persisted value is the user's intent byte for byte (decisions
/// 0023, 0027): text whose bytes the runtime acts on (a fetch URL, a request line) or uses as an opaque identity key (a credential cache
/// account) is compared here, never normalized.
package enum ExactText {
    package static func same(_ a: String, _ b: String) -> Bool {
        a.utf8.elementsEqual(b.utf8)
    }

    package static func same(_ a: [String], _ b: [String]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { same($0, $1) }
    }
}
