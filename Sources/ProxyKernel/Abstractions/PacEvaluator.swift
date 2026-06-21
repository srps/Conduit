// SPDX-License-Identifier: Apache-2.0
// Kernel-side seams for PAC resolution. The production impl
// (`CFPACEvaluator` / `CFPacScriptEvaluator`) lives in `ProxyPAC` because it
// depends on CFNetwork; the Kernel's `PACRoutingEngine` talks to these
// protocols and never references the concrete types.
//
// Two protocols (not one) because the evaluator has a lifecycle:
//   1. fetch a PAC script string (async I/O)
//   2. construct a stateful evaluator over the script (sync, CFNetwork-backed)
//   3. reuse the evaluator across many route lookups (kernel-side caching)
//   4. parse raw `PROXY host:port; DIRECT` directives into `PACRoute`
//
// Collapsing (1)+(2)+(3) into a single `routeChain(for:)` would defeat the
// `PACRoutingEngine`'s evaluator cache and re-fetch+re-parse on every HTTP
// request.
//
// CFNetwork is the sole PAC evaluator; the kernel did not
// change because the protocol seam already carried the concrete swap.

import Foundation

/// A PAC-script evaluator bound to a specific script text. Produced by
/// `PacEvaluator.makeEvaluator(pacScript:)`; consumed by `PACRoutingEngine`
/// on each `routeChain(for:host:)` call.
///
/// Impl must be reentrant across multiple concurrent `resolveProxyChain`
/// calls (the kernel holds it behind a serial queue today, but the contract
/// does not promise that; future orchestrations may parallelize).
package protocol PacScriptEvaluating: Sendable {
    /// Evaluate `FindProxyForURL(url, host)` against the bound PAC script.
    /// Returns the raw directive strings (e.g. `["PROXY host:port", "DIRECT"]`)
    /// in the order the script produced them. Use `PacEvaluator.routeChain`
    /// to parse the list into `[PACRoute]`.
    func resolveProxyChain(for url: URL) throws -> [String]
}

/// A PAC script resolver: fetches the script (with scheme-specific fallbacks),
/// constructs evaluators over it, and parses raw directive strings.
///
/// Stateless at the protocol boundary — impls may hold URLSession / fetcher
/// state internally, but `PACRoutingEngine` never assumes the evaluator
/// returned by a later `makeEvaluator` reflects state from an earlier one.
/// The engine re-fetches + re-constructs when its internal TTL expires.
package protocol PacEvaluator: Sendable {
    /// Fetch the PAC script from a URL. Must handle `http://`, `https://`,
    /// and `file://` schemes; ATS-forbidden plaintext URLs (corporate
    /// networks) fall back to a cleartext fetcher controlled by the impl.
    func fetchPAC(from urlString: String) async throws -> String

    /// Parse a PAC script into an evaluator. Synchronous; may take tens of
    /// milliseconds on large scripts — `PACRoutingEngine` dispatches onto
    /// a dedicated serial queue and gates on a timeout semaphore.
    func makeEvaluator(pacScript: String) throws -> any PacScriptEvaluating

    /// Parse raw PAC directive strings into typed routes. Unparsable
    /// entries are silently dropped (matches today's `compactMap(parseRoute)`
    /// behaviour — PAC scripts regularly emit vendor-specific directives
    /// the kernel doesn't understand).
    func routeChain(for entries: [String]) -> [PACRoute]
}

extension PacEvaluator {
    /// Convenience: build an evaluator and resolve a single URL in one call.
    /// Used by AppState's "Test PAC URL" preview path; not on the hot
    /// `PACRoutingEngine` route — that path caches the evaluator across
    /// many lookups via `makeEvaluator` directly. Living on the protocol
    /// means the concrete evaluator inherits the shorthand without
    /// duplicating the pair-call.
    package func resolveProxyChain(for url: URL, pacScript: String) throws -> [String] {
        try makeEvaluator(pacScript: pacScript).resolveProxyChain(for: url)
    }
}
