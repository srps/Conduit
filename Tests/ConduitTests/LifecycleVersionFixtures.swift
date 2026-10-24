// SPDX-License-Identifier: Apache-2.0
import RuntimeEvents

/// The version tokens the typed `version_changed` boundary is pinned on. The domain, wire and
/// producer tests share them, so each side of the boundary is checked on the same values.
enum LifecycleVersionFixtures {
    /// Grammar-valid tokens of 59 bytes or fewer, in the shapes the file carries, with dots and
    /// separators in several positions. Each is valid as `from` and as `to`, and each keeps its rendered
    /// line a fixed point of the sanitizer.
    static let boundary: [String] = [
        "a", "0.5.8", "0.5.8-rc.1+7", "unbundled", "1_0", "A_b.c-d+e",
        String(repeating: "a", count: 58),
        String(repeating: "a", count: 59),
        "a." + String(repeating: "b", count: 57),
        String(repeating: "a", count: 29) + "." + String(repeating: "b", count: 29),
        "+" + String(repeating: "a", count: 58),
        "-" + String(repeating: "a", count: 58),
        String(repeating: "a", count: 58) + ".",
        String(repeating: "a", count: 55) + "+rc1",
    ]

    /// Tokens that end in the word `Bearer` at the start or after `.`, `-` or `+`, in any case. As `from`,
    /// the rendered `from=… to=…` line is a bearer credential to the sanitizer, so the pair is refused. As
    /// `to` they are valid: nothing follows them but the end of the line.
    static let bearerFrom: [String] = [
        "Bearer", "bearer", "BEARER", "a.Bearer", "a-bearer", "a+BEARER", "0.5.Bearer", "+Bearer",
        String(repeating: "a", count: 52) + "-Bearer",
    ]

    /// Tokens near the word `Bearer` that the sanitizer leaves alone: the word is inside a larger word,
    /// or it is not the end of the value. Valid as `from` and as `to`.
    static let bearerNearMiss: [String] = [
        "aBearer", "_Bearer", "1Bearer", "xBearer", "Bearerx", "BearerBearer",
        "Bearer-", "Bearer+1", "Bearer.1", "Bearer.", "Bearer_",
    ]

    /// Every token that is valid as `from` and as `to`: the boundary and the near misses. A pair of these
    /// must render a line the sanitizer leaves unchanged.
    static let valid: [String] = boundary + bearerNearMiss

    /// Every grammar-valid token the fixtures carry, whether or not it is a valid `from`. A matrix over
    /// these pairs compares the predicate with the sanitizer on each side, and never drops a pair for being invalid.
    static let grammar: [String] = valid + bearerFrom

    /// Tokens one byte or more past the bound, dot-free and dotted. The grammar refuses every one.
    static let overBound: [String] = (60...65).map { String(repeating: "a", count: $0) } + [
        "a." + String(repeating: "b", count: 62),
        String(repeating: "a", count: 29) + "." + String(repeating: "b", count: 30),
    ]
}
