// SPDX-License-Identifier: Apache-2.0
import Foundation
import ProxyKernel
import ConduitShared

package enum DNSValidationError: Error, LocalizedError {
    /// Carries the specific reason as well as the name. The old single-payload
    /// case produced "Invalid DNS domain name: foo_bar.example" in a log an
    /// operator then had to guess at; the reason is what tells them which
    /// character to change.
    case invalidDomain(String, reason: DomainNameError)
    case invalidServer(String)

    package var errorDescription: String? {
        switch self {
        case .invalidDomain(let d, let reason):
            return "Invalid DNS domain name '\(d)': \(reason.localizedDescription)"
        case .invalidServer(let s):
            return "Invalid DNS server address: \(s)"
        }
    }
}

/// Raised when resolver-file removals failed. Every removal in the batch was
/// still attempted — see `DNSManager.removeAll` for why stopping at the first
/// failure is the wrong shape here.
package struct DNSRemovalError: Error, LocalizedError {
    package struct Failure: Sendable, Equatable {
        package let domain: String
        package let message: String

        package init(domain: String, message: String) {
            self.domain = domain
            self.message = message
        }
    }

    package let failures: [Failure]

    package init(failures: [Failure]) {
        self.failures = failures
    }

    package var domains: [String] { failures.map(\.domain) }

    package var errorDescription: String? {
        let listed = failures.map { "\($0.domain) (\($0.message))" }.joined(separator: ", ")
        return "Failed to remove \(failures.count) resolver file(s): \(listed). "
             + "Those domains stay overridden until the removal succeeds."
    }
}

package final class DNSManager: @unchecked Sendable {
    private let privilegeClient: PrivilegeClient
    /// Where resolver files live. Injectable so tests can exercise the
    /// disk-state paths (`isApplied`, `isCleared`, `entryFilesPresent`, and the
    /// stale-file repair in `apply`) against a temporary directory instead of
    /// needing to write to the real `/etc/resolver`.
    private let resolverDirectory: String
    /// Which resolver files are ours, one `resolverFile` scope per domain we
    /// wrote. No prior contents are recorded: the files are written by the
    /// helper and are ours or nobody's, so a scope means "we added this,
    /// remove it" and is forgotten once the removal lands. Two hosts' questions
    /// hang on that list. A host whose user has turned resolver management
    /// *off* needs to tell our file from one they maintain by hand for the
    /// same domain, which disk presence alone cannot. And every teardown
    /// derives its domains from the *current* config, so a domain edited out
    /// of the config file by hand, or one whose removal failed last time,
    /// would otherwise be left overridden with nothing naming it. Optional
    /// because the daemon and the tests do not ask; without one
    /// `hasManagedState()` is `false` and teardown works from the config alone.
    private let journal: PlatformStateJournal?

    package init(
        privilegeClient: PrivilegeClient = AppleScriptPrivilegeClient(),
        resolverDirectory: String = "/etc/resolver",
        journal: PlatformStateJournal? = nil
    ) {
        self.privilegeClient = privilegeClient
        self.resolverDirectory = resolverDirectory
        self.journal = journal
    }

    /// Whether resolver files may still be ours to remove: the journal marks
    /// the surface applied and not yet released, or cannot be read. See
    /// `journal`.
    package func hasManagedState() -> Bool {
        guard let journal else { return false }
        return !journal.knowsSurfaceIsIdle(.resolverFile)
    }

    /// Records each domain about to be written as ours. Called before the
    /// first write, not after the last: a write that fails partway has
    /// already put files of ours on disk. `recordPrior` is first-write-wins,
    /// so a rewrite of a domain we already hold changes nothing.
    private func recordManaged(_ domains: [String]) {
        guard let journal else { return }
        for domain in domains {
            journal.recordPrior(surface: .resolverFile, scope: domain, value: nil)
        }
        journal.markApplied(surface: .resolverFile)
    }

    private func resolverFilePath(for domain: String) -> String {
        "\(resolverDirectory)/\(domain)"
    }

    // MARK: - Validation

    /// Delegates to `DomainNameSyntax`, the package's one domain grammar. This
    /// file used to hold a regex byte-identical to `HelperInputValidator`'s,
    /// which meant the writer and the privileged executor of the same
    /// `/etc/resolver/<domain>` file each carried their own copy of the rule.
    package static func validateDomain(_ domain: String) throws {
        do {
            try DomainNameSyntax.validate(domain)
        } catch {
            throw DNSValidationError.invalidDomain(domain, reason: error)
        }
    }

    /// Same grammar as the helper's `validateIPAddress`, for the same reason
    /// `validateDomain` shares `DomainNameSyntax` with it: this is the writer
    /// and the helper is the privileged executor of the same value, and a
    /// server the app accepts that the helper refuses is a failure with no
    /// cause the user can see. The regexes this replaced accepted
    /// `999.999.999.999` and `::::::`.
    package static func validateServer(_ server: String) throws {
        guard IPAddressSyntax.isLiteral(server) else {
            throw DNSValidationError.invalidServer(server)
        }
    }

    // MARK: - Intercept Rule Processing

    /// Domains whose `/etc/resolver/<domain>` file points the system resolver
    /// at the local DNS forwarder.
    ///
    /// These files are written *only* by `applyInterceptFiles`, which its
    /// callers invoke exclusively once the forwarder and the transparent
    /// proxy are both listening (`ProxyOrchestratorBindings.dnsInterceptReady`).
    /// `apply` must never write them, and `isApplied` must never demand them:
    /// `apply` runs at proxy start, before the forwarder binds — and in the
    /// GUI host, whether or not it ever will, since nothing there acts on
    /// `dnsForwarderEnabled` at launch.
    ///
    /// That flag used to gate this set, which was wrong twice over: it is a
    /// record of "DNS was running when we last exited", not a promise that it
    /// runs now. Quitting with DNS on left it `true` (only `stopDNS` clears
    /// it), so the next proxy start installed `/etc/resolver/cursor.sh` →
    /// `127.0.0.1:5053` with nothing bound to 5053, and every `getaddrinfo`
    /// for an intercepted domain returned ENOTFOUND until the file was
    /// removed by hand. A resolver file outlives the process that wrote it;
    /// it may only make promises the running process is already keeping.
    ///
    /// Clear/isCleared pass `forCleanup: true`: cleanup must derive the set
    /// from the rules alone (including disabled ones), because by cleanup
    /// time the enable flags have typically already flipped false (`stopDNS`
    /// persists `dnsForwarderEnabled = false` before the proxy stops) —
    /// gating cleanup on them strands exactly the stale files described above.
    private func getInterceptDomains(from config: ProxyConfig, forCleanup: Bool = false) -> [String] {
        if !forCleanup {
            guard config.transparentProxyEnabled else { return [] }
        }
        let rules = forCleanup ? config.dnsInterceptRules : config.enabledInterceptRules
        // One derivation, on the model, so `ProxyConfig.validate()` checks the
        // same string this writes. `/etc/resolver/` is a directory, so an empty
        // derived domain is skipped rather than written. Two shapes reach that:
        // a rule the user has added but not yet typed a pattern into, which the
        // boundary deliberately accepts as not-yet-configured; and a bare `*`,
        // which the boundary rejects but which configs written before that
        // validation existed may still carry.
        return rules.map(\.resolverDomain).filter { !$0.isEmpty }
    }

    // MARK: - Entry Processing

    /// Static split-DNS entries (`/etc/resolver/<domain>` → corporate DNS
    /// servers), gated on the VPN being up. The configured servers live
    /// inside the tunnel, but the resolver override applies to *everything*
    /// matching the domain — including the VPN gateway's own public hostname
    /// (e.g. `vpn-gw.corp.example` matched by a `corp.example` entry). With
    /// the VPN down the override sends those lookups to unreachable servers,
    /// so the VPN client cannot resolve its gateway to reconnect: a bootstrap
    /// deadlock only a file removal breaks. Entry files must therefore exist
    /// only while the tunnel that makes their servers reachable is up.
    private func getEntries(from config: ProxyConfig, vpnConnected: Bool) -> [DomainDNSEntry] {
        guard vpnConnected else { return [] }
        return config.dnsEntries.filter(\.enabled).filter { !$0.servers.isEmpty }
    }

    // MARK: - State Detection

    /// Whether `apply` has nothing left to do. Callers use it to skip the
    /// apply step, so it has to account for everything `apply` does — which
    /// since the stranded-file sweep includes *removing* files, not only
    /// writing them.
    ///
    /// Intercept files are deliberately absent from this check — `apply` does
    /// not write them (see `getInterceptDomains`), so requiring them here would
    /// make the caller's "already configured, skip" test permanently false
    /// whenever DNS is stopped.
    package func isApplied(config: ProxyConfig, vpnConnected: Bool) -> Bool {
        let enabledEntries = getEntries(from: config, vpnConnected: vpnConnected)

        guard !enabledEntries.isEmpty else {
            // Nothing to write. That is not the same as nothing to do: with the
            // VPN down `apply` sweeps entry files a previous run stranded, and
            // reporting "already applied" here skips exactly that repair. The
            // GUI host guards its `apply` call with this method, so answering
            // `true` unconditionally made the sweep unreachable in the one host
            // and the one state it exists for.
            return !entryFilesPresent(config: config)
        }

        return enabledEntries.allSatisfy { entry in
            let expected = entry.servers.map { "nameserver \($0)" }.joined(separator: "\n")
            let filePath = resolverFilePath(for: entry.domain)
            guard let actual = try? String(contentsOfFile: filePath, encoding: .utf8) else { return false }
            return actual.trimmingCharacters(in: .whitespacesAndNewlines)
                == expected.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    package func isCleared(config: ProxyConfig) -> Bool {
        let enabledEntries = config.dnsEntries.filter(\.enabled)
        let interceptDomains = getInterceptDomains(from: config, forCleanup: true)

        let entriesCleared = enabledEntries.allSatisfy { entry in
            !FileManager.default.fileExists(atPath: resolverFilePath(for: entry.domain))
        }

        let interceptCleared = interceptDomains.allSatisfy { domain in
            !FileManager.default.fileExists(atPath: resolverFilePath(for: domain))
        }

        // A recorded domain the config no longer names is still ours on disk;
        // without this a host guarding `clear` on `isCleared` would skip it.
        let recordedCleared = (journal?.scopes(for: .resolverFile) ?? []).allSatisfy { domain in
            !FileManager.default.fileExists(atPath: resolverFilePath(for: domain))
        }

        return entriesCleared && interceptCleared && recordedCleared
    }

    // MARK: - Apply / Clear

    /// Writes the static split-DNS entry files at proxy start. Intercept-rule
    /// files are *not* written here — they belong to the DNS start path, which
    /// runs once the forwarder they point at is actually listening. See
    /// `getInterceptDomains`.
    package func apply(config: ProxyConfig, logger: (any LogSink)?, vpnConnected: Bool) throws {
        let enabledEntries = getEntries(from: config, vpnConnected: vpnConnected)

        if !vpnConnected, !config.dnsEntries.filter(\.enabled).isEmpty {
            // Repair, not just defer. Entry files outlive the process that
            // wrote them: a `SIGKILL`, an installer swapping the app, or a run
            // that ended without a clean stop all strand them on disk with no
            // in-memory record. Left there with the VPN down, each one sends
            // its whole domain to servers only the tunnel can reach —
            // blackholing those lookups for every process on the machine, the
            // VPN gateway's own hostname included when it falls under a
            // managed domain. Nothing else sweeps them: the VPN transition
            // handler only fires on a state *flip*, so files stranded while
            // the VPN is already down stay stranded. A start is the one moment
            // that can be relied on to fix it.
            if entryFilesPresent(config: config) {
                try clearEntryFiles(config: config, logger: logger)
            }
            logger?.log(.notice, "Split-DNS entry files deferred until the VPN connects (their servers are tunnel-internal).", category: .system)
        }

        guard !enabledEntries.isEmpty else {
            if vpnConnected || config.dnsEntries.filter(\.enabled).filter({ !$0.servers.isEmpty }).isEmpty {
                if config.enabledInterceptRules.isEmpty {
                    logger?.log(.warning, "DNS resolver management skipped because no internal DNS servers or intercept rules are configured.", category: .system)
                } else {
                    // Not a misconfiguration: intercept-only setups are normal.
                    // Their resolver files are written by the DNS start path.
                    logger?.log(.debug, "No split-DNS entry files to write; intercept resolver files are owned by the DNS start path.", category: .system)
                }
            }
            return
        }

        for entry in enabledEntries {
            try Self.validateDomain(entry.domain)
            for server in entry.servers {
                try Self.validateServer(server)
            }
        }

        recordManaged(enabledEntries.map(\.domain))
        for entry in enabledEntries {
            try privilegeClient.execute(.applyDNS, values: [entry.domain, entry.servers.joined(separator: ",")])
        }

        logger?.log(.notice, "Applied split-DNS resolver files for \(enabledEntries.count) domain(s).", category: .system)
    }

    package func clear(config: ProxyConfig, logger: (any LogSink)?) throws {
        let enabledEntries = config.dnsEntries.filter(\.enabled)
        let interceptDomains = getInterceptDomains(from: config, forCleanup: true)
        // The config names what we *would* write today; the journal names
        // what we *did* write. A domain edited out of the config by hand, or
        // one whose removal failed last time, is only in the second list.
        let recorded = journal?.scopes(for: .resolverFile) ?? []
        let domains = enabledEntries.map(\.domain) + interceptDomains + recorded

        guard !domains.isEmpty else { return }

        try removeAll(domains, logger: logger)

        logger?.log(.notice, "Removed managed split-DNS resolver files and intercept rules.", category: .system)
    }

    // MARK: - Reconcile (config edits while running)

    /// Applies the delta between two configs: removes resolver files that were
    /// (or may have been) managed under `old` but are no longer wanted under
    /// `new`, then applies `new`'s entry files. Domains present in both configs
    /// are rewritten in place — never removed first — so a running system
    /// keeps resolving them throughout. This is what makes DNS config edits
    /// take effect without a Conduit restart.
    /// Removes resolver files the new config no longer wants, then writes the
    /// entry files it does.
    ///
    /// Intercept files are represented in `newDomains` so a surviving rule is
    /// not mistaken for stale, but this never *writes* them — `apply` doesn't,
    /// by design. A DNS-affecting config change (a new `dnsForwarderPort`, in
    /// particular) therefore leaves their contents untouched here, and the
    /// caller must refresh them against the restarted listeners: see the
    /// `dnsInterceptReady` branch in `AppState.applyConfigChange` /
    /// `DaemonRuntimeHost`.
    package func reconcile(old: ProxyConfig, new: ProxyConfig, logger: (any LogSink)?, vpnConnected: Bool) throws {
        let oldDomains = Set(
            old.dnsEntries.filter(\.enabled).map(\.domain)
                + getInterceptDomains(from: old, forCleanup: true)
        )
        let newDomains = Set(
            getEntries(from: new, vpnConnected: vpnConnected).map(\.domain)
                + getInterceptDomains(from: new)
        )

        let stale = oldDomains.subtracting(newDomains).sorted()
        var removalError: Error?
        do {
            try removeAll(stale, logger: logger)
        } catch {
            removalError = error
        }
        if !stale.isEmpty {
            let failed = (removalError as? DNSRemovalError)?.failures.count ?? 0
            logger?.log(
                .notice,
                "Removed \(stale.count - failed) of \(stale.count) stale resolver file(s) after config change.",
                category: .system
            )
        }

        guard !newDomains.isEmpty else {
            if let removalError { throw removalError }
            return
        }

        // The migration is attempted even when part of the sweep failed. The
        // two sets are disjoint by construction — `stale` is `old - new` — so a
        // file we could not remove is never one this is about to write, and
        // leaving the new config unapplied on top of a half-swept machine is
        // the worse of the two states. `removeAll` has already logged each
        // domain it left behind; the aggregate is rethrown afterwards so the
        // caller still sees the failure, just not instead of the migration.
        do {
            try apply(config: new, logger: logger, vpnConnected: vpnConnected)
        } catch {
            // Only one error can be thrown, and the caller asked for the
            // migration, so that failure is the one that travels. The sweep's
            // aggregate would otherwise vanish here — and naming the stranded
            // files is the whole point of having it — so it is logged before the
            // apply error goes up.
            if let removalError {
                logger?.log(
                    .warning,
                    "The stale-file sweep also failed: \(removalError.localizedDescription)",
                    category: .system
                )
            }
            throw error
        }
        if let removalError { throw removalError }
    }

    // MARK: - VPN-lifecycle entry files

    /// Whether any static split-DNS entry file is on disk right now.
    ///
    /// Disk truth, not bookkeeping: these files outlive the process that wrote
    /// them. A `SIGKILL`, an installer swapping the app, or a start that failed
    /// after they were applied all leave them behind with no in-memory record,
    /// and each one blackholes its domain for every process on the machine
    /// until someone removes it. Callers deciding whether there is anything to
    /// clean up have to ask the filesystem.
    package func entryFilesPresent(config: ProxyConfig) -> Bool {
        config.dnsEntries
            .filter(\.enabled)
            .contains { FileManager.default.fileExists(atPath: resolverFilePath(for: $0.domain)) }
    }

    /// Writes only the static split-DNS entry files. Called when the VPN
    /// transitions to connected while the proxy is running: `apply` deferred
    /// them while the tunnel (and thus their servers) was unreachable.
    package func applyEntryFiles(config: ProxyConfig, logger: (any LogSink)?) throws {
        let entries = getEntries(from: config, vpnConnected: true)
        guard !entries.isEmpty else { return }
        for entry in entries {
            try Self.validateDomain(entry.domain)
            for server in entry.servers {
                try Self.validateServer(server)
            }
        }
        recordManaged(entries.map(\.domain))
        for entry in entries {
            try privilegeClient.execute(.applyDNS, values: [entry.domain, entry.servers.joined(separator: ",")])
        }
        logger?.log(.notice, "Applied \(entries.count) split-DNS entry file(s) now that the VPN is connected.", category: .system)
    }

    /// Removes only the static split-DNS entry files. Called when the VPN
    /// disconnects: their servers are tunnel-internal, and leaving the
    /// override in place blackholes every lookup under those domains —
    /// including the VPN gateway's own public hostname when it falls under a
    /// managed domain, which deadlocks reconnection (see `getEntries`).
    package func clearEntryFiles(config: ProxyConfig, logger: (any LogSink)?) throws {
        let entries = config.dnsEntries.filter(\.enabled)
        guard !entries.isEmpty else { return }
        try removeAll(entries.map(\.domain), logger: logger)
        logger?.log(.notice, "Removed \(entries.count) split-DNS entry file(s) while the VPN is disconnected.", category: .system)
    }

    /// Writes only the intercept-rule resolver files. The sole writer of
    /// these files.
    ///
    /// Contract for callers: invoke this only when
    /// `ProxyOrchestratorBindings.dnsInterceptReady` is true — the forwarder
    /// bound *and* the transparent proxy accepting. The file tells the system
    /// resolver that `<domain>` is answered at `127.0.0.1:<port>`, and the
    /// forwarder answers with the intercept IP; a file written while either
    /// listener is down blackholes the domain for every client on the machine
    /// and survives the process that wrote it. `stopDNS` pairs this with
    /// `clearInterceptFiles`.
    package func applyInterceptFiles(config: ProxyConfig, logger: (any LogSink)?) throws {
        let interceptDomains = getInterceptDomains(from: config)
        guard !interceptDomains.isEmpty else { return }
        for domain in interceptDomains {
            try Self.validateDomain(domain)
        }
        recordManaged(interceptDomains)
        for domain in interceptDomains {
            try privilegeClient.execute(.applyDNS, values: [domain, "127.0.0.1", String(config.dnsForwarderPort)])
        }
        logger?.log(.notice, "Applied \(interceptDomains.count) intercept resolver file(s) for the DNS forwarder.", category: .system)
    }

    /// Removes only the intercept-rule resolver files (all rules, enabled or
    /// not). Called from the DNS stop path so `*.cursor.sh`-style domains
    /// never keep pointing at a forwarder that is no longer listening, while
    /// the static split-DNS entry files (which do not depend on the
    /// forwarder) stay in place for the still-running proxy.
    ///
    /// Also runs at proxy start, to sweep files a killed instance stranded.
    /// Removal is idempotent (the helper unlinks with `try?`), so this makes
    /// no claim that a file was there — hence "cleared", not "removed".
    package func clearInterceptFiles(config: ProxyConfig, logger: (any LogSink)?) throws {
        let interceptDomains = getInterceptDomains(from: config, forCleanup: true)
        guard !interceptDomains.isEmpty else { return }
        try removeAll(interceptDomains, logger: logger)
        logger?.log(.notice, "Cleared intercept resolver files for \(interceptDomains.count) rule(s).", category: .system)
    }

    // MARK: - Removal

    /// Removes every domain in the list, then reports what failed.
    ///
    /// Fail-fast is wrong for removals specifically. Each `rm -f` is
    /// independent and idempotent, so there is no ordering reason for one
    /// failure to cancel the rest — and a `/etc/resolver/<domain>` left behind
    /// is not inert. It points the system resolver at a forwarder that is no
    /// longer listening, which blackholes that domain for every process on the
    /// machine (see `getEntries`). `clearEntryFiles` is the sharp case: it runs
    /// on VPN-down, nothing re-runs it, and one early failure would strand
    /// every domain after it — including, when the gateway's own hostname falls
    /// under a managed domain, the name the VPN needs in order to reconnect.
    ///
    /// The *apply* loops keep their fail-fast behaviour deliberately:
    /// `isApplied` reports a partial apply as not-applied and the start path
    /// guards on it, so those repair themselves at the next start. Removals
    /// have no equivalent retry.
    ///
    /// This is also what `TunnelResolverManager.removeAll` and
    /// `SystemDNSManager.clear` already do; `DNSManager` was the outlier.
    ///
    /// Validation belongs *inside* the loop for the same reason. Checked in a
    /// pass ahead of it, one unusable name aborted the whole batch — the exact
    /// failure this function exists to prevent, and worse than the interleaved
    /// loop it replaced. An unusable name is reachable without anyone mistyping
    /// a domain: an intercept pattern like `*.exa mple.com` yields
    /// `exa mple.com`, deleting the rule makes it stale, and the sweep for
    /// every *other* stale domain used to die with it. (`*.foo_bar.example`
    /// used to be the example here. It no longer is — `DomainNameSyntax`
    /// accepts underscores — but the shape survives, which is why the
    /// interleaving stays.)
    private func removeAll(_ domains: [String], logger: (any LogSink)?) throws {
        // Deduplicated, order preserved. `clear` concatenates the entry domains
        // and the intercept domains, and a domain configured as both would
        // otherwise be counted twice in the aggregate — "failed to remove 2
        // resolver file(s)" for one file. Removing twice is harmless because
        // removal is idempotent; miscounting it to the operator is not.
        var seen = Set<String>()
        let unique = domains.filter { seen.insert($0).inserted }

        var failures: [DNSRemovalError.Failure] = []
        for domain in unique {
            // An unusable name is warned about but is *not* a removal failure.
            // No file of ours can exist under it — every writer validates first —
            // so nothing is stranded and the teardown did in fact achieve what it
            // set out to. Counting it as a failure made a clean teardown report as
            // failed, and made the aggregate's "those domains stay overridden"
            // false for that entry. The broken thing is the config, which is #68's
            // subject; not silent, because this names it at `.warning`.
            do {
                try Self.validateDomain(domain)
            } catch {
                logger?.log(
                    .warning,
                    "Skipped removing \(domain): \(error.localizedDescription). No resolver file can have been "
                        + "written under that name, so nothing is left overridden — but the config entry that "
                        + "produced it is unusable and will never take effect.",
                    category: .system
                )
                continue
            }

            do {
                try privilegeClient.execute(.removeDNS, values: [domain])
                // Only after the file is gone. A record dropped over a failed
                // removal is a file we wrote with nothing left saying so.
                journal?.forget(surface: .resolverFile, scope: domain)
            } catch {
                failures.append(.init(domain: domain, message: error.localizedDescription))
                logger?.log(
                    .warning,
                    "Failed to remove \(resolverFilePath(for: domain)): \(error.localizedDescription). "
                        + "Lookups under \(domain) stay overridden for every process on this machine until it is removed.",
                    category: .system
                )
            }
        }
        // Every record gone means nothing of ours is left on this surface,
        // whether this call removed the last file or an earlier one did. A
        // failed removal keeps its record, so this never releases over one.
        if let journal, !journal.hasRecords(for: .resolverFile) {
            journal.markReleased(surface: .resolverFile)
        }
        guard failures.isEmpty else { throw DNSRemovalError(failures: failures) }
    }
}
