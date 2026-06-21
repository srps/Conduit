// SPDX-License-Identifier: Apache-2.0
// CFNetwork-backed PAC evaluation: the Safari-parity replacement for the
// former JavaScriptCore backend. `CFPACEvaluator` is now the sole production
// `PacEvaluator` implementation in `ProxyPAC`; `PACRoutingEngine` stores the
// protocol and remains unaware of the concrete backend.
//
// Why CFNetwork:
//   - Keeps `ProxyPAC` off JavaScriptCore. CFNetwork is part of
//     CoreFoundation / CFNetwork.framework on macOS — no new dependency.
//   - PAC evaluation runs in OS code-paths shared with Safari. OS security
//     updates patch our PAC handling automatically. The JSC engine is also
//     OS-shipped but PAC isn't its primary use-case; CFNetwork's
//     `CFNetworkExecuteProxyAutoConfigurationScript` is the canonical
//     path for PAC.
//
// Why a CFRunLoop dance:
//   - `CFNetworkExecuteProxyAutoConfigurationScript` is callback-on-runloop
//     async — there is no synchronous variant. The kernel's
//     `PacScriptEvaluating.resolveProxyChain(for:)` is sync-throws, so we
//     spin a private CFRunLoop in a custom mode (so other runloop sources
//     don't interleave), wait for the callback or a 2s timeout (matching
//     `PACRoutingEngine`'s existing per-eval cap), then return.
//   - This is the same pattern Chromium and Safari use; running a private
//     mode keeps unrelated CFRunLoop sources from firing on the dispatch
//     queue PACRoutingEngine routes us through.
//
// `insecureFetcher` keeps the app-target curl fallback out of ProxyPAC so the
// evaluator target never shells out or links PlatformMac.

import CoreFoundation
import Foundation
import ProxyKernel

// MARK: - CFPacScriptEvaluator: PacScriptEvaluating

/// CFNetwork-backed `PacScriptEvaluating`. Holds the PAC script text and
/// dispatches each `resolveProxyChain(for:)` call through
/// `CFNetworkExecuteProxyAutoConfigurationScript` on a private CFRunLoop.
///
/// The CFNetwork callback signature on macOS 26 / Swift 6.3 returns
/// values directly (CFArrayRef, CFRunLoopSourceRef) rather than as
/// `Unmanaged<>`s — the Swift overlay no longer requires manual
/// `takeRetainedValue()` / `takeUnretainedValue()` on these arguments.
package final class CFPacScriptEvaluator: PacScriptEvaluating, @unchecked Sendable {
    private let script: String

    /// Per-evaluation timeout. Matches `PACRoutingEngine`'s existing
    /// 2s outer semaphore — keeps the inner CFRunLoop bounded so a
    /// pathological PAC script can't pin the kernel's PAC dispatch queue.
    private static let evaluationTimeout: CFTimeInterval = 2.0

    /// Custom CFRunLoop mode name. Constructed per-call to avoid storing
    /// a non-Sendable `CFString` constant at file scope (Swift 6 strict
    /// concurrency rejects it). The `CFString` allocation is trivial.
    private static let runLoopModeName = "Conduit.CFPACEvaluator"

    package init(pacScript: String) throws {
        // CFNetwork doesn't validate scripts at construction; it parses on
        // each invocation. We could parse-test by running FindProxyForURL
        // against a dummy URL once here, but that's wasted work — most
        // scripts are valid; parse errors surface on the first real call
        // via the callback's `CFError` path and become
        // `PACResolverError.evaluationFailed`. Invalid scripts surface on
        // first `resolveProxyChain`, not at init.
        self.script = pacScript
    }

    package func resolveProxyChain(for url: URL) throws -> [String] {
        // Wrap in `autoreleasepool` so any Objective-C temporaries CFNetwork
        // allocates internally (NSURLRequest, NSURL, etc.) drain at the end
        // of this call rather than at the end of the caller's runloop
        // iteration. Under `pm-proxy --status-interval` or burst routing
        // (hundreds of evaluations per second), these accumulate unboundedly
        // without a pool (PACClient retain cycle, wrapped in autoreleasepool).
        return try autoreleasepool {
            let resultBox = ResultBox()

            // Bridge ARC ↔ CFNetwork refcounting via CFStreamClientContext's
            // `retain`/`release` callbacks: when CFNetwork copies the
            // context it calls our retain (bumps the box's refcount),
            // and when the source is invalidated CFNetwork releases its
            // copy (decrements). The box therefore stays alive across the
            // ENTIRE CFNetwork-internal lifetime — including the pathological
            // case where the timeout path returns from this function before
            // CFNetwork has fully torn down. Without this, `passUnretained`
            // would mean the box dies when this function returns, and any
            // delayed callback (CFNetwork machinery still in flight) would
            // dereference a freed pointer (use-after-free).
            //
            // STYLE rule 7 ("Explicit resource lifetime"); AGENTS.md
            // ("Leaks are assertion failures").
            let retainCallback: @convention(c) (UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer? = { ptr in
                guard let ptr else { return nil }
                _ = Unmanaged<ResultBox>.fromOpaque(ptr).retain()
                return ptr
            }
            let releaseCallback: @convention(c) (UnsafeMutableRawPointer?) -> Void = { ptr in
                guard let ptr else { return }
                Unmanaged<ResultBox>.fromOpaque(ptr).release()
            }

            var ctx = CFStreamClientContext(
                version: 0,
                info: Unmanaged.passUnretained(resultBox).toOpaque(),
                retain: retainCallback,
                release: releaseCallback,
                copyDescription: nil
            )

            let scriptCF = script as CFString
            let urlCF = url as CFURL
            let mode = CFRunLoopMode(Self.runLoopModeName as CFString)

            // Modern CFNetwork callback shape (Swift 6.3 / macOS 26):
            //   (UnsafeMutableRawPointer, CFArray, CFError?) -> Void
            // The overlay no longer wraps the array / runloop-source returns
            // in `Unmanaged<>`, and the info-ptr arg is non-optional.
            let callback: @convention(c) (UnsafeMutableRawPointer, CFArray, CFError?) -> Void = { rawCtx, proxyList, error in
                let box = Unmanaged<ResultBox>.fromOpaque(rawCtx).takeUnretainedValue()
                if let error {
                    box.setError(error)
                } else {
                    box.setProxies(proxyList)
                }
            }

            let runLoopSource = CFNetworkExecuteProxyAutoConfigurationScript(
                scriptCF, urlCF, callback, &ctx
            )

            // Attach to the current thread's runloop in our private mode and
            // tear down on exit. PACRoutingEngine routes us through `jsQueue`
            // (a serial DispatchQueue) so `CFRunLoopGetCurrent()` returns the
            // queue's underlying thread runloop — exactly what we want to
            // service the PAC callback.
            let runLoop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(runLoop, runLoopSource, mode)

            // Cleanup order matters:
            //   1. Invalidate the source — per Apple's `CFRunLoopSource`
            //      docs, after invalidation the source's perform routine
            //      will not be invoked. This is the canonical way to cancel
            //      a CFNetwork PAC evaluation: the source represents the
            //      in-flight evaluation, and invalidating it releases
            //      CFNetwork's hold on our context (which calls
            //      `releaseCallback`, dropping the box's CFNetwork-side
            //      retain).
            //   2. Remove the source from the runloop — pure runloop
            //      bookkeeping; no-op if invalidate already cleaned it.
            //
            // Without invalidate the source's internal state never releases
            // and the callback could fire AFTER this function returns —
            // accessing `resultBox` through a pointer freed when the
            // function's stack frame went away. With both invalidate and
            // the retain/release context callbacks above, both the timeout
            // path (CFNetwork retains box → invalidate → release → box dies
            // cleanly) and the success path (callback fires → invalidate
            // is a no-op → context release → box dies cleanly) are leak-
            // and UAF-free.
            defer {
                CFRunLoopSourceInvalidate(runLoopSource)
                CFRunLoopRemoveSource(runLoop, runLoopSource, mode)
            }

            // returnAfterSourceHandled: true → exits on first callback fire.
            let runResult = CFRunLoopRunInMode(mode, Self.evaluationTimeout, true)

            switch runResult {
            case .handledSource:
                // Callback fired — `resultBox` is populated.
                return try resultBox.value()
            case .timedOut:
                throw PACResolverError.evaluationFailed(
                    "CFNetwork PAC evaluation timed out after \(Int(Self.evaluationTimeout))s"
                )
            case .stopped, .finished:
                // Unusual — runloop returned without the callback firing and
                // without a timeout. Treat as evaluation failure rather than
                // hanging the caller forever.
                throw PACResolverError.evaluationFailed(
                    "CFNetwork PAC runloop exited unexpectedly (mode=\(runResult.rawValue))"
                )
            @unknown default:
                throw PACResolverError.evaluationFailed(
                    "CFNetwork PAC runloop returned unknown status \(runResult.rawValue)"
                )
            }
        }
    }
}

// MARK: - ResultBox

/// Reference-typed slot for the C callback to populate. Held on the
/// caller's stack frame for the duration of the synchronous `CFRunLoop`
/// call (see `passUnretained` rationale at the call site).
///
/// Property is named `outcome` (not `result`) to avoid collision with the
/// `value()` accessor that returns the unwrapped `[String]` — Swift 6's
/// typed-throws inference picked up the wrong `result` symbol when the
/// names overlapped.
private final class CFPACResultBox {
    private var outcome: Result<[String], any Error>?

    func setProxies(_ proxyList: CFArray) {
        outcome = .success(parseProxyList(proxyList))
    }

    func setError(_ error: CFError) {
        let nsError = error as Error
        outcome = .failure(PACResolverError.evaluationFailed(nsError.localizedDescription))
    }

    func value() throws -> [String] {
        guard let outcome else {
            throw PACResolverError.evaluationFailed(
                "CFNetwork PAC callback never populated the result"
            )
        }
        return try outcome.get()
    }
}

private typealias ResultBox = CFPACResultBox

// MARK: - CFArray<CFDictionary> → ["PROXY host:port", ...] parsing

/// CFNetwork returns proxy decisions as a `CFArray` of `CFDictionary`
/// entries keyed by `kCFProxyTypeKey` / `kCFProxyHostNameKey` /
/// `kCFProxyPortNumberKey`. Convert to the `["PROXY host:port", "DIRECT"]`
/// directive form that `PACRoutingEngine` already knows how to parse via
/// `PacEvaluator.routeChain(for:)`.
private func parseProxyList(_ list: CFArray) -> [String] {
    let count = CFArrayGetCount(list)

    // Materialise the kCFProxyType* constants as plain String once outside
    // the loop. Inline `case kCFProxyTypeFoo as String:` patterns confuse
    // Swift's overload resolution on macOS 26 (`expression pattern of type
    // 'CFString' cannot match values of type 'String'`) — explicit String
    // constants sidestep the issue and read cleaner besides.
    let noneType = kCFProxyTypeNone as String
    let httpType = kCFProxyTypeHTTP as String
    let httpsType = kCFProxyTypeHTTPS as String
    let socksType = kCFProxyTypeSOCKS as String

    var entries: [String] = []
    entries.reserveCapacity(count)

    for i in 0..<count {
        guard let dictPtr = CFArrayGetValueAtIndex(list, i) else { continue }
        let dict = unsafeBitCast(dictPtr, to: CFDictionary.self)

        guard let typePtr = CFDictionaryGetValue(
            dict,
            Unmanaged.passUnretained(kCFProxyTypeKey).toOpaque()
        ) else {
            continue
        }
        let type = unsafeBitCast(typePtr, to: CFString.self) as String

        switch type {
        case noneType:
            entries.append("DIRECT")
        case httpType, httpsType:
            if let hostPort = extractHostPort(from: dict) {
                entries.append("PROXY \(hostPort)")
            }
        case socksType:
            if let hostPort = extractHostPort(from: dict) {
                entries.append("SOCKS \(hostPort)")
            }
        default:
            // Unknown proxy type — skip. PACRoutingEngine's `routeChain`
            // already silently drops unparsable directives, so vendor-
            // specific tokens are ignored rather than failing evaluation.
            //
            // The `kCFProxyTypeAutoConfiguration*` and `kCFProxyTypeFTP`
            // constants exist but are returned by `CFNetworkCopySystem
            // ProxySettings`, not by PAC-script `FindProxyForURL` results
            // — so they're not worth special-casing here.
            continue
        }
    }

    // Two paths land here with `entries.isEmpty == true`: (a) the CFArray
    // was already empty (no proxy decision at all), and (b) the CFArray
    // had entries but every one was filtered out — unknown proxy type, or
    // an HTTP/HTTPS/SOCKS dictionary whose host/port failed `extractHost
    // Port` (out-of-range port, missing keys). Both must default to
    // "DIRECT" so the kernel sees a usable chain instead of `[]`. An empty
    // chain in `PACRoutingEngine.routeChain(for:host:)` becomes an empty
    // `[PACRoute]`, `HTTPProxyHandler.route` is `nil`, and the request is
    // routed through the configured upstream — the OPPOSITE of what an
    // unparsable PAC decision should do. Defaulting to DIRECT keeps the
    // failure mode safe-by-default.
    if entries.isEmpty {
        return ["DIRECT"]
    }
    return entries
}

private func extractHostPort(from dict: CFDictionary) -> String? {
    guard
        let hostPtr = CFDictionaryGetValue(
            dict,
            Unmanaged.passUnretained(kCFProxyHostNameKey).toOpaque()
        ),
        let portPtr = CFDictionaryGetValue(
            dict,
            Unmanaged.passUnretained(kCFProxyPortNumberKey).toOpaque()
        )
    else {
        return nil
    }
    let host = unsafeBitCast(hostPtr, to: CFString.self) as String
    let portNumber = unsafeBitCast(portPtr, to: CFNumber.self)
    var port: Int = 0
    CFNumberGetValue(portNumber, .intType, &port)
    guard port > 0, port <= 65535 else { return nil }
    return "\(host):\(port)"
}

// MARK: - CFPACEvaluator: PacEvaluator

/// CFNetwork-backed `PacEvaluator`.
package final class CFPACEvaluator: PacEvaluator, @unchecked Sendable {
    private let session: URLSession
    private let insecureFetcher: @Sendable (URL) async throws -> String

    /// The SwiftUI app injects a curl-backed fetcher for legacy plaintext PAC
    /// URLs. Headless daemons get the throwing default (the PAC target
    /// cannot shell out to curl).
    package init(
        session: URLSession = .shared,
        insecureFetcher: (@Sendable (URL) async throws -> String)? = nil
    ) {
        self.session = session
        self.insecureFetcher = insecureFetcher ?? Self.defaultInsecureFetcher
    }

    @Sendable
    private static func defaultInsecureFetcher(_ url: URL) async throws -> String {
        throw PACResolverError.fetchFailed(
            "Plaintext PAC URL \(redactedURL(url)) requires an explicit " +
            "`insecureFetcher` — the app target injects one backed by curl; " +
            "headless daemons should use an ATS exception or an https PAC URL."
        )
    }

    package func fetchPAC(from urlString: String) async throws -> String {
        guard let url = URL(string: urlString) else {
            throw PACResolverError.invalidURL
        }

        if url.isFileURL {
            return try String(contentsOf: url, encoding: .utf8)
        }
        guard url.user == nil, url.password == nil else {
            throw PACResolverError.fetchFailed("PAC URLs must not contain embedded credentials.")
        }

        if url.scheme?.lowercased() == "http" {
            return try await insecureFetcher(url)
        }

        do {
            let (data, _) = try await session.data(from: url)
            return String(decoding: data, as: UTF8.self)
        } catch {
            if Self.isATSError(error) {
                return try await insecureFetcher(url)
            }
            throw error
        }
    }

    package func makeEvaluator(pacScript: String) throws -> any PacScriptEvaluating {
        try CFPacScriptEvaluator(pacScript: pacScript)
    }

    package func routeChain(for entries: [String]) -> [PACRoute] {
        entries.compactMap(parseRoute)
    }

    package func parseRoute(_ entry: String) -> PACRoute? {
        let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let parts = trimmed.split(whereSeparator: \.isWhitespace)
        guard let kind = parts.first?.uppercased() else { return nil }

        if kind == "DIRECT" {
            return .direct
        }

        guard parts.count >= 2 else { return nil }
        let endpoint = String(parts[1])
        let hostPort = endpoint.split(separator: ":", maxSplits: 1).map(String.init)
        guard hostPort.count == 2, let port = Int(hostPort[1]), !hostPort[0].isEmpty else {
            return nil
        }

        switch kind {
        case "PROXY", "HTTP", "HTTPS":
            return .proxy(host: hostPort[0], port: port)
        case "SOCKS", "SOCKS4", "SOCKS5":
            return .socks(host: hostPort[0], port: port)
        default:
            return nil
        }
    }

    private static func isATSError(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain
            && nsError.code == NSURLErrorAppTransportSecurityRequiresSecureConnection
    }

    private static func redactedURL(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return "<invalid-url>"
        }
        components.user = nil
        components.password = nil
        return components.string ?? "<redacted-url>"
    }
}
