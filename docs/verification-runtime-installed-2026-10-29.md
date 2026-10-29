# Installed 0.6.0 candidate verification — 2026-10-29

The owner installed the 0.6.0 candidate built from [`97a5b43`](https://github.com/srps/Conduit/commit/97a5b43a0d8d7504b760b4b05aece3a8f66f5914) and ran a normal Stop, Start, Connections, Quit and relaunch with the real helper, VPN and Kerberos. The run passed, with one attention result that existing policy expects and one route claim qualified as unproven. The candidate is serving. The latest public release is still 0.5.8. Bounded evidence and reviews are in the [archive](experiments/runtime-installed-acceptance/README.md).

## What was installed

The executable's SHA-256 is `a894b35af9ca03f9ca171b7c9e2a808fecfec70afa28dc88fcc4b2347fc4eb35`. It was signed with the local signing certificate, not the release certificate, so this is not the release package. The helper was not reinstalled or changed; helper protocol v5 is unchanged. `8a036fe` is docs-only: from `97a5b43` it changes only `ROADMAP.md` and files under `docs/`. `983ba39` adds two recovery-policy tests, and its `Sources/` diff from `97a5b43` is empty. The archived `source-provenance.json` records both facts.

## The owner-run lifecycle (R5, 12:53–12:54 UTC)

A private, non-shipping verifier (SHA-256 `e8405532…`) read the machine before and after each step. It reported 38 checks: 37 pass, 1 attention, 0 fail and 0 unproven, plus one explicit skip for product-only Quit duration.

- **Preflight:** one Conduit process at the installed path with the expected hash and version. All eight scoped system-proxy journal records matched the saved per-service settings, with no legacy record.
- **Stop:** stopped in the same process. All eight managed per-service proxy field sets were back to their captured priors, as were seven resolver files and six launchd variables. Shell markers were removed, the listener was closed, and the config, platform and preferences files were byte-identical to the start of the run.
- **Start:** running and listening in the same process, with the files unchanged. Start recaptured eight records. Each prior equalled the preflight prior; none matched the preflight applied value, and none was rebased, unknown or new. The proxy module reported `started` after 0.96 s.
- **Quit:** the process exited without being forced, 1.91 s after the owner pressed Return. That time includes the owner's reaction and is an upper bound, not a measurement. All eight per-service field sets matched the priors Start tracked. Resolver files, launchd variables, markers, files and the listener matched the Stop results. The final snapshot shows proxy, DNS and tunnels stopped, and the journal holds no proxy, DNS, launchd or resolver records.
- **Relaunch:** the app opened stopped, as the existing behavior selects, and the owner pressed Start. The 13.79 s from `open` to serving includes that wait, so it is not autostart or startup latency. After that, an HTTPS request answered 200 and its CONNECT answered 200. The run recorded two Kerberos successes, 21 successful helper requests and no failed ones. The owner confirmed that Connections showed live rows.
- **Steady state, 12:57 UTC:** running, DNS running, VPN connected, last auth Kerberos, and a direct loopback DNS public A query answered NOERROR. The relaunch check's first running snapshot comes before DNS, VPN and auth settle. This separate read is what shows the settled state.

## Qualifications

**Stop attention.** One global PAC route still pointed at Conduit's local PAC port after Stop. It was exactly a prior the journal had captured, still held by an enabled service in the active location, and every captured identity had been restored. Existing [ownership policy](design-network-location-recovery.md) keeps untracked user settings, including one that looks like Conduit's, so this is the expected outcome. The user-visible effect is that one service keeps a PAC URL pointing at a port nothing listens on while Conduit is stopped. That is existing behavior: `LocationSettingsRecovery.swift` and `PlatformStateJournal.swift` are byte-identical between v0.5.8 and `97a5b43` (`source-provenance.json`). This record claims no new PAC defect, and no user prior is cleaned.

**After-Quit global route: unproven.** The tool reported PASS with origin `none`, but its global read at 0.25 s was an empty dictionary, and a later read in the same phase showed PAC enabled without recording the endpoint. It is likely the same preserved prior as at Stop, but that cannot be confirmed. This record does not claim that no global route to Conduit remained after Quit. Per-service restoration is exact either way. The raw counts are unchanged, and no new run is needed.

**Earlier runs.** R2 had 33 pass and 2 unproven, because the verifier could not prove an empty global read. R4 had 33 pass and 2 fail, from an overbroad check that failed on any route to Conduit's own PAC port; its original origin was never attributed. Both reports stay as recorded and do not pass retroactively. The corrected verifier changes how routes are classified and nothing in the product. It passes 56 pure fixture cases and a read-only preflight, and an independent review accepted it.

## Supporting checks

- **Two policy tests** (`983ba39`) pin existing behavior: a fresh journal preserves an untracked Conduit-looking PAC, and a reapply after an external bypass edit keeps the original PAC prior instead of the applied one. Removing the recognized prior fails the first test. Skipping the old restore before rebasing fails the second. The exact restored source passes all 47 recovery tests. Optimized local build and recovery tests pass. Independent review accepted the tests.
- **Local workflow:** all 41 checks pass on unchanged production Source plus the two tests: 3,773 tests, four existing skips and 103 simulator scenarios, on local Swift 6.4.
- **Hosted on `8a036fe`:** the complete Swift workflow, Release (Swift 6.3.3, 3,771 standard tests with four skips, optimized build and PAC checks, ad-hoc ZIP/DMG verification), slow-drain and CodeQL pass. CodeQL warned that the diff exceeds its 300-file limit, so it is not a full security review. This is not the final head.

## Release CI stall on `512a6b0` and the test guards

The prepared evidence is in [`release-ci-stall-and-guards.json`](experiments/runtime-installed-acceptance/lifetime-guard-closeout-evidence/release-ci-stall-and-guards.json).

- **What happened:** on `512a6b0` the full Swift workflow passed on Swift 6.3.3: 3,773 tests, four skips, no failures. The Release job built normally in 169 s, then hit its 30-minute job limit during the standard debug `swift test`. The last line it delivered was a stop-flood test's `started`; nothing followed for 21 minutes.
- **Why the cause is unknown:** that output was block-buffered, so the last line marks a buffer boundary, not the stalled test. The named test cannot suspend. **The stalled test and its cause are unknown.** No deadline was raised, and no fix is claimed for that hang.
- **The local diagnostic did not reproduce it.** The suspect window was run with line-buffered output: 20 normal trials passed, 117 tests each. One trial under the strict cooperative-pool setting ended on a finite assertion in a different suite (`RuntimePhysicalOrderingTests`, DNS metrics). That is a diagnostic finding, not a stall, and is not part of this change.
- **A real hazard was found and closed.** Review found waits in `RuntimeServiceLifetimeTests` and one in `RuntimeServicePressureMetricsTests` that assert a bounded gate without returning, then wait without bound. Two new controls prove that `abandonAfterFailure` ends a pull before it starts and with its timer unfired. With the cleanup removed, both controls fail their assertions and still finish. The guards then use the file's existing idiom, and the focused classes pass four runs. Three gate-started waiters can still leak if a guard returns before a timer or round exists. That is not a hang, and no claim of complete cleanup quiescence is made.
- **CI change:** the Release standard step now runs under `/usr/bin/script` with stdin from `/dev/null`, so its output is line-buffered. A native probe confirmed exit statuses 0 and 23, a child SIGTERM (exit 15), a tty, and that stdin EOF does not end the child early. The job timeout stays at 30 minutes. The first new run must show a timestamp on each test line.
- **Production Source is unchanged.** The installed `97a5b43` candidate's acceptance stands, and no further owner checks are needed. Locally on Swift 6.4, the full standard suite passed: 3,775 tests, four skips, no failures. All 41 local workflow checks pass, including 103 simulator scenarios, on the stable `4890eab0` fingerprint recorded in the evidence file. The local optimized test build and all 22 affected tests also pass. Independent reviews accepted the guard change and this record.

## Does not prove

- Which test stalled the Release job on `512a6b0`, or why.
- Release-certificate packaging, the signed tag build or publication.
- Behavior under heavy load or a slow helper, Quit at its ten-second expiry, or a product-only Quit duration.
- Automatic start on relaunch. None is selected or added.
- On a real machine, the preparation-time `input_replaced` hold (decision 0037). The actual-client harness covers it, and 0037 already records that no forced race on a real machine is required.
- Cleanup of services the journal does not track, split-DNS domains, or attribution of a VPN-published global proxy view.
- Production daemon ownership.

## Remaining

Hosted CI on the final head, including Swift 6.3.3 optimized and line-timestamped Release output, then merging PR #258. Then a release-certificate tag build and draft through the release environment with its approval. Publication is the owner's decision.

The private verifier's relaunch prompt stayed silent until the owner pressed Start. That is a harness UX defect, not a product one, and it needs no change.
