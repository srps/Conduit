# Signed 0.6.1 release verification — 2026-10-29

Status: the signed candidate passes its scoped normal-path machine acceptance.
It is installed and serving. The GitHub draft is unpublished; 0.5.8 remains the
latest public release. Publication is the owner's remaining decision.

## Candidate and automated gates

[PR #262](https://github.com/srps/Conduit/pull/262) merged at
`f809bb965ccdad9f6879f3eab73ea5b6b1e0881b`; its tree exactly matches verified
head `f445952`. Immutable `v0.6.1` names that merge. The existing 0.6.0 tag and
unpublished draft remain unchanged. No runtime or test source changed afterwards.

The final [Swift](https://github.com/srps/Conduit/actions/runs/40943678865),
[PR Release](https://github.com/srps/Conduit/actions/runs/40943679015),
[main](https://github.com/srps/Conduit/actions/runs/40947880579) and owner-approved
[signed tag](https://github.com/srps/Conduit/actions/runs/40948074694) workflows pass.
The full suites run 3,780 tests with four skips, zero failures and zero NIO misuse.
The complete simulator suite has 104 passing cases; script, perf, optimized PAC
and package checks pass. [Concurrency verification](verification-nio-concurrency-2026-10-29.md)
keeps the local controls, scoped sanitizer passes and the separate failed full
TSan run. That independently reproduced Swift continuation finding remains open
in [#118](https://github.com/srps/Conduit/issues/118); it is not a passed full soak
or proof of an instrumentation-only defect. No suppression or dependency fork
was added.

The downloaded ZIP, DMG, checksum and feed digests match GitHub. The checksum file,
feed version/URL/length, Ed25519 archive signature and rejected altered-signature
control pass. Both containers hold matching arm64 release-certificate apps with
valid seals, identifiers and hardened runtime; library validation remains enabled
for the main app. The DMG was mounted read-only and detached. The actual signed
app's early read-only ping was admitted by the installed helper. The helper and
its policy were not reinstalled or changed. The project remains self-signed and
not notarized as documented; no quarantine or trust-policy change was made.

## Owner-run machine acceptance

The owner installed the already verified signed bundle and ran the local offline
checker with VPN connected. The agent never stopped, killed or replaced a serving
app. The [archive](experiments/release-0.6.1-acceptance/README.md) preserves the
completed report, earlier outcomes and qualifications. The completed run spans
22:06:02–22:07:23 UTC: **23 checks pass, four are observations, no errors**.

- Stop closed the listener in the same process. Configuration, platform and
  preferences bytes stayed unchanged. The journal had no non-marker surface
  records after its bounded settle.
- Start brought the listener back in the same process and emitted one explicit
  proxy-start settlement. The three settings files remained unchanged.
- After the owner's normal Quit instruction, the process and listener were gone
  within 5.92 seconds of the prompt, including the owner's reaction. The checker
  used no forced termination. The final snapshot was freshly stopped, the
  journal records were released and the settings files were unchanged.
- Reopen used a new process, followed by manual Start. HTTPS and CONNECT both
  answered 200. The isolated reopen window records five Kerberos successes,
  21 successful helper requests, no failures and no helper-problem event. The
  snapshot shows VPN connected, DNS running and fresh Kerberos authentication.
  The checker finished with Conduit serving.
- The owner attests that Connections displayed live rows. A separate read at
  22:11:26 UTC confirms the expected signed executable, valid installed signature,
  running/VPN/Kerberos state and unchanged settings bytes since before install.

The first attempt stopped at the RUN confirmation without lifecycle steps. The
next attempt was interrupted after baseline observations. Their errors and counts
remain recorded; neither becomes a completed pass. Baseline auth/helper counts
in the final run cover the original installation boundary and earlier 0.6.1
sessions. The reopen window above is independent of those aggregate counts. An additional
shutdown between attempts was outside the checker's timed phases and has no
owner-action or duration claim here. Manual Start is inferred from the ordered
phase transitions, not an instrumented click.

The [independent evidence review](experiments/release-0.6.1-acceptance/independent-review.md)
accepts normal-path native acceptance with these qualifications. No repeat run
is required. It read source/reports and corroborating events; it ran no checks.

## Limits and remaining work

The journal observations do not re-test physical per-service restoration or
establish that no global PAC route remained. Prior 0.6.0 physical recovery evidence
keeps its original source scope and qualifications. DNS-running status is not a
DNS/split-DNS query test. HTTPS, Kerberos and helper results are separate
observations, without a causal attribution to that request.

No new claim covers heavy load, power loss, slow/stuck helper expiry, every
concurrency interleaving, product-only Quit duration or autostart. Opening stopped
and manually pressing Start remains selected behavior. The production daemon and
socket, other event-family migrations and recorded follow-up hardening issues
remain later work. No material architecture decision is introduced by this
closeout; the release is ready for the owner's publication decision.
