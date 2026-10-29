# Installed 0.6.0 candidate acceptance — 2026-10-29

Bounded evidence for the [installed-candidate verification](../../verification-runtime-installed-2026-10-29.md). Raw reports, logs, configuration, service identities, URLs and authentication values are not archived. Every file is a bounded copy or summary prepared from the owner's run and the parent's checks; the original owner report was never rewritten.

## Provenance

- Installed executable SHA-256 `a894b35af9ca03f9ca171b7c9e2a808fecfec70afa28dc88fcc4b2347fc4eb35`, built from [`97a5b43`](https://github.com/srps/Conduit/commit/97a5b43a0d8d7504b760b4b05aece3a8f66f5914). Locally certificate-signed, not the release-certificate package. The helper was not reinstalled or changed.
- `8a036fe` is a docs-only commit after `97a5b43`: `source-provenance.json` lists every path it changes, which are `ROADMAP.md` and files under `docs/`. `983ba39` adds the two recovery-policy tests. The same file records an empty `Sources/` diff from `97a5b43` to `983ba39` and the committed test file hash `7cdfbf05…`.
- `source-provenance.json` also records that `Sources/PlatformMac/LocationSettingsRecovery.swift` and `Sources/PlatformMac/PlatformStateJournal.swift` are byte-identical between `v0.5.8` and `97a5b43`, with their SHA-256 values.
- Two Source fingerprints appear and are not comparable. `90252b9b…` in `policy-controls.json` is the SHA-256 of the single file `LocationSettingsRecovery.swift`. `713e7e96…` in `local-gates.json` is the full-workflow driver's aggregate fingerprint of the tracked workflow tree.
- Verifier: a private, non-shipping script of about 2,000 lines, SHA-256 `e8405532…`. It is not a product path and is not committed. Only its hash, fixture results and reviews are kept.

## Files

| File | What it shows | Scope |
| --- | --- | --- |
| `installed-lifecycle-r5.json` | Owner-run R5 report (curated copy, values and identities omitted) with the independent review's `review_qualification` appended | 38 checks: 37 pass, 1 attention, 0 fail, 0 unproven, plus one explicit skip. The after-Quit global-route PASS is qualified as unproven (below). |
| `post-reopen.json` | Steady state at 12:57:33 UTC after the run | Running, DNS running, VPN connected, last auth Kerberos; a direct loopback DNS public A query answered NOERROR. No split-domain claim. |
| `installed-acceptance-evidence-independent-review.md` | Independent review of the installed evidence | ACCEPT with the after-Quit route correction. |
| `installed-scoped-proxy-verifier-author.md` | Author report for the verifier delta and the two policy tests | Verifier and tests only; no product change. |
| `installed-scoped-proxy-independent-review-r2.md` | Independent review of the verifier's route-attribution delta before R5 | ACCEPT for one owner repeat. |
| `verifier-fixtures.json` | 56 curated pure/helper-stub verifier cases, all passing | No app control or normal-mode execution. |
| `policy-controls.json` | Two counterfactual product edits and the exact-source restore | Each counterfactual fails its intended new test; restored source passes 47/47 recovery tests. |
| `optimized-recovery.json` | Local optimized build and recovery test class | Local only; hosted compiler acceptance separate. |
| `local-gates.json` | All 41 local workflow checks, exit 0, on stable fingerprint `713e7e96…` | The `swift-tests` log, read in place, reads `Executed 3773 tests, with 4 tests skipped and 0 failures`; the `pm-sim-all` log has 103 scenario records, none failed. Local Swift 6.4. |
| `hosted-8a.json` | Hosted Swift, Release (Swift 6.3.3 standard 3,771 tests/4 skips, optimized/PAC, ad-hoc ZIP/DMG), slow-drain and CodeQL on `8a036fe` | Not the final head. The ad-hoc PR package is not a release-certificate artifact. The CodeQL 300-file diff warning means it is not a full security review. |
| `lifetime-guard-closeout-evidence/release-ci-stall-and-guards.json` | The Release CI stall on `512a6b0`, the local diagnostic, the C1/C2 controls and their mutant, the test guards and the Release step's PTY wrapper | Test and CI changes only; production Source unchanged. The historic stall's cause stays unknown. The full 41-check local run was pending when this was prepared. |
| `source-provenance.json` | Empty `Sources/` diff and test hash for `97a5b43` to `983ba39`, the path list for `97a5b43` to `8a036fe`, and the recovery and journal files byte-identical from `v0.5.8` to `97a5b43` | Prepared by the parent from git; the archive keeps the result, not the commands. |

## Required qualification

`after_quit.system_proxy_route_to_conduit_ownership` reports PASS with origin `none`. Its global read at 0.25 s was an empty dictionary. A later read in the same phase showed PAC enabled, and that read recorded no endpoint. Whether a global route to Conduit's own PAC port exists after Quit is therefore **unproven**. It is likely the same preserved prior that the Stop check attributed (attention, `preexisting_prior_preserved`), but no attribution is claimed. The raw counts are unchanged. Per-service restoration is exact either way: 8/8 after both Stop and Quit.

## History kept as recorded

- R2 (report SHA-256 `6ab532179fd091f064dfefc53882dc7a4ba26cdf380c62b35629f318b41b90ee`): 33 pass, 2 unproven, because the verifier could not prove an empty global read.
- R4: 33 pass, 2 fail, from an overbroad check that failed on any route to Conduit's own PAC port. Its origin was never attributed, and it does not pass retroactively.
- The corrected verifier changes classification only; product behavior is unchanged. Existing policy ([design](../../design-network-location-recovery.md), "Untracked settings … are preserved") keeps untracked user priors, including a Conduit-looking PAC. The recovery and journal files are byte-identical to v0.5.8 (`source-provenance.json`). No new PAC defect is claimed, and no user prior is sanitized.

## Harness note

After the automatic relaunch, the private harness's prompt stayed silent until the owner pressed Start. This is a harness UX defect, not a product one. The app opens stopped, and the owner's manual Start is the existing selected behavior. No autostart was added and no repeat run is needed.

## Final closeout review

The [independent final review](final-closeout-review.md) accepts the corrected decision statuses, provenance and after-Quit qualification without blockers. The decision structure/tests, update-note extraction and whitespace checks pass after those corrections. Final-head hosted CI remains a separate gate.
