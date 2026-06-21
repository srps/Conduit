// SPDX-License-Identifier: Apache-2.0
// Kernel-side logging seam. Replaces direct `AppLogStore` references in the
// 15 kernel files that historically took the SwiftUI / Combine ring buffer
// as an init parameter — making the kernel target unable to import Combine
// or @MainActor types.
//
// Two stock implementations live next door in Support/StandardLogSinks.swift:
// `ConsoleLogSink` (writes inline to stderr — used by pm-proxy / pm-sim /
// pm-tunnel headless daemons) and `DiscardingLogSink` (no-op — used by tests
// and pm-sim scenarios that don't need to assert on log output).
//
// The SwiftUI app's `AppLogStore` (in `Sources/Conduit/App/`) conforms
// via its existing nonisolated `bridge`-renamed-`logImpl` method which Tasks
// back to MainActor for the ring buffer append.
//
// The protocol shape: the
// filtering `@autoclosure` entry point is a protocol extension named
// `log(_:_:category:)`, and the conformer-implemented primitive is
// `logImpl(_:_:category:)`. This ensures every `logger.log(.debug, "…")`
// call site dispatches through the filter + autoclosure short-circuit,
// instead of bypassing it through a same-named protocol requirement with
// a plain `String` parameter (the pre-fix footgun that made the
// optimisation dead code across all 127 call sites).

import Foundation

package protocol LogSink: Sendable {
    /// Lower bound for which levels are worth constructing a message for.
    /// Implementations gate this on their loudest enabled output (e.g.
    /// `AppLogStore` returns `min(minStderrLevel, minBufferedLevel)`;
    /// `DiscardingLogSink` returns a level past `.error` so the autoclosure
    /// extension always short-circuits).
    ///
    /// Read at most a handful of times per request. The existential cost is
    /// dwarfed by the saved string-interpolation work when filtered out.
    var minLevel: LogLevel { get }

    /// Raw sink primitive. Conformers implement this to consume already-
    /// built log lines — they do **not** need to re-check `minLevel`
    /// because the filtering happens in the `log(_:_:category:)`
    /// extension below before `logImpl` is ever called.
    ///
    /// Callers should **not** invoke this method directly; use
    /// `log(_:_:category:)` instead so you pay zero cost on filtered-out
    /// levels. Direct `logImpl` calls are a code smell and bypass the
    /// autoclosure + level-filter protection. The one exception is the
    /// `log` extension itself, which is the only legitimate caller.
    ///
    /// Called from any thread / any actor. Implementations decide their
    /// own threading: `ConsoleLogSink` writes inline; `AppLogStore` hops
    /// to MainActor for its ring buffer; future `FileLogSink` may
    /// dispatch to a background queue. Implementations MUST NOT assume
    /// the calling thread.
    func logImpl(_ level: LogLevel, _ message: String, category: LogCategory)
}

extension LogSink {
    /// Filtered entry point. Every in-tree call site uses this method —
    /// the 127 occurrences of `logger.log(.level, "msg", category: .cat)`
    /// resolve to this extension (no same-named method exists on the
    /// protocol, so Swift's overload resolution unambiguously picks it).
    ///
    /// The `@autoclosure` wrapper on `message` defers the string
    /// interpolation until the filter check passes. Under `pm-sim
    /// multi-100` this skips thousands of `.debug`-level interpolations
    /// per second that the headless daemons would otherwise build and
    /// immediately discard.
    @inlinable
    package func log(
        _ level: LogLevel,
        _ message: @autoclosure () -> String,
        category: LogCategory = .general
    ) {
        guard level >= minLevel else { return }
        logImpl(level, SensitiveValueSanitizer.sanitize(message()), category: category)
    }
}
