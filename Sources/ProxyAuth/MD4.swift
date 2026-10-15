// SPDX-License-Identifier: Apache-2.0

/// MD4 (RFC 1320), which NTLM's NT hash requires. CommonCrypto deprecates
/// `CC_MD4` because MD4 is broken for new security uses; NTLM has no other
/// choice, so the digest lives here instead of behind a deprecated call.
enum MD4 {
    static let digestLength = 16

    static func digest(_ message: [UInt8]) -> [UInt8] {
        var state: (UInt32, UInt32, UInt32, UInt32) = (0x6745_2301, 0xEFCD_AB89, 0x98BA_DCFE, 0x1032_5476)
        var padded = message
        padded.append(0x80)
        while padded.count % 64 != 56 { padded.append(0) }
        let bitLength = UInt64(message.count) &* 8
        for shift in stride(from: 0, to: 64, by: 8) { padded.append(UInt8(truncatingIfNeeded: bitLength >> UInt64(shift))) }

        for blockStart in stride(from: 0, to: padded.count, by: 64) {
            var words = [UInt32](repeating: 0, count: 16)
            for index in 0..<16 {
                let byte = blockStart + index * 4
                words[index] = UInt32(padded[byte]) | UInt32(padded[byte + 1]) << 8
                    | UInt32(padded[byte + 2]) << 16 | UInt32(padded[byte + 3]) << 24
            }
            var (a, b, c, d) = state
            let rounds: [(order: [Int], shifts: [UInt32], constant: UInt32, mix: (UInt32, UInt32, UInt32) -> UInt32)] = [
                (Array(0..<16), [3, 7, 11, 19], 0, { x, y, z in (x & y) | (~x & z) }),
                ([0, 4, 8, 12, 1, 5, 9, 13, 2, 6, 10, 14, 3, 7, 11, 15], [3, 5, 9, 13], 0x5A82_7999,
                 { x, y, z in (x & y) | (x & z) | (y & z) }),
                ([0, 8, 4, 12, 2, 10, 6, 14, 1, 9, 5, 13, 3, 11, 7, 15], [3, 9, 11, 15], 0x6ED9_EBA1,
                 { x, y, z in x ^ y ^ z }),
            ]
            for round in rounds {
                for (step, index) in round.order.enumerated() {
                    // Each step updates a, d, c, b in turn from the other three.
                    let shift = round.shifts[step % 4]
                    switch step % 4 {
                    case 0: a = rotate(a &+ round.mix(b, c, d) &+ words[index] &+ round.constant, shift)
                    case 1: d = rotate(d &+ round.mix(a, b, c) &+ words[index] &+ round.constant, shift)
                    case 2: c = rotate(c &+ round.mix(d, a, b) &+ words[index] &+ round.constant, shift)
                    default: b = rotate(b &+ round.mix(c, d, a) &+ words[index] &+ round.constant, shift)
                    }
                }
            }
            state = (state.0 &+ a, state.1 &+ b, state.2 &+ c, state.3 &+ d)
        }
        return [state.0, state.1, state.2, state.3].flatMap { word in
            (0..<4).map { UInt8(truncatingIfNeeded: word >> UInt32($0 * 8)) }
        }
    }

    private static func rotate(_ value: UInt32, _ shift: UInt32) -> UInt32 {
        (value << shift) | (value >> (32 - shift))
    }
}
