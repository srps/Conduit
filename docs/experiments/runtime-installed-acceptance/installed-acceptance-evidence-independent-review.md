**Verdict: ACCEPT, with one required correction to the claims.** The evidence supports scoped acceptance of normal installed Stop/Start/Connections/Quit/relaunch. No new run is needed. But "global no own route after Quit" isn't proven, and the record shouldn't say it is.

## The correction: the after-Quit route PASS rests on a read the same phase contradicts

- In `13n8mj8z/report.json:479-486`, `after_quit.system_proxy_read` is `empty_dictionary` with 0 top-level keys, read at `elapsed_s: 0.25`. The route check takes that read and returns `origin: none` → PASS.
- A later `scutil --proxy` read in the same phase reports `system_proxy_enable_flags: {"ProxyAutoConfigEnable": 1}` (`:476-478`). An empty dictionary can't have PAC enabled, so the global view changed between the two reads.
- The verifier's settle loop treats `none` as converged on the very first read (`verify-installed-lifecycle.py:1585-1587`), so a brief empty dictionary while configd republishes is enough to pass. The flags come from a separate read after the settle (`:1636`).
- After Quit, identity `8f7a20be` still holds its preserved loopback-PAC prior (`current_hash 494198f4` = its prior, with `prior_pac_class loopback_local_pac_port`, enabled). At Stop that exact prior was the global route (2 keys, PAC=1, ATTENTION). So after Quit, the global route most likely points at Conduit's PAC port again, i.e. the same ATTENTION as at Stop, not "none". The endpoint wasn't recorded, so this can't be confirmed either way.

**Wording for the record:** the tool reported 37 PASS, 1 ATTENTION, 0 FAIL, 0 UNPROVEN. `after_quit.system_proxy_route_to_conduit_ownership` is qualified: its read was a brief empty dictionary, and a later read in the same phase shows PAC enabled with an unrecorded endpoint. So whether a global own-route exists after Quit is unproven, and it is likely the same preserved prior as at Stop. This is not a product failure: per-service restoration is exact either way. It changes the claim, not the outcome. A possible later verifier fix is to require two matching global reads, or to compare against the flags read, before accepting `none`.

## Claims that hold
- **Totals:** 38 checks, which is 37 PASS and 1 ATTENTION (Stop route, `preexisting_prior_preserved`), plus one explicit skip (`quit.product_only_duration`).
- **System proxy:** at preflight, 8/8 OS fields equal the applied fields and there are no legacy records. After both Stop and Quit, 8/8 are `restored`, with 0 `applied_retained`, `external_differs`, `rebased_to_applied` or `record_unknown`, and the per-identity hashes match the priors. Start recaptured 8 records, all `prior_equals_preflight_prior`, none rebased. The proxy module settled as `started` in 0.96 s, so the Quit comparison really tracked Start's records.
- **Stop ATTENTION is valid under existing policy:** the one loopback-PAC prior was captured and preserved exactly, which is the expected outcome in the r2 review.
- **Other surfaces:** 7 resolver files and 6 launchd variables restored at both points, markers 3→0 files, config, platform and preferences unchanged, listener closed (ECONNREFUSED, no lsof listeners).
- **Quit:** 1.91 s is an upper bound that includes the owner's reaction; the final snapshot was written at 1.73 s.
- **Relaunch:** HTTP 200 and CONNECT 200, Kerberos events 2, helper 21 succeeded and 0 failed. The proxy event after reopen is `module=proxy source=explicit outcome=started`, which supports "13.79 s includes the manual Start, not autostart latency". The UX note fits this: the app opens stopped.
- **Steady state:** running, DNS NOERROR (public A query only), VPN connected, Kerberos. Executable SHA `a894b35a…` matches across the report and the post-reopen read. Locally signed, not the release certificate. No helper reinstall shown or needed.
- **Policy controls:** both counterfactuals fail the intended test, and the restored source passes 47/47. The optimized build and the recovery class pass.
- **R2/R4:** unchanged, no retroactive pass.

## Limits I couldn't close (read-only, no commands)
- Hosted CI for the final head `983ba39` is still due. The hosted evidence covers `8a036fe` only.
- I can't confirm that the committed test file equals `tests_sha256 7cdfbf05…`. I also can't confirm that `97a5b43`→`8a036fe`→`983ba39` touches no Source. The parent should check both.
- Two different Source hashes appear: `90252b9b…` in policy-controls and `713e7e…` in local-gates. They probably cover different scopes (likely the one mutated file vs. the whole tree). The record should say which is which.
- `pid_matches_startup_evidence: false`, so the startup evidence comes from an earlier process. The binary SHA matches, so this isn't material.
- Connections is the owner's attestation. Untracked services, split-DNS and VPN-publisher attribution are not judged.
- Residual effect worth recording for 0037: after Stop and Quit, one service keeps a PAC URL pointing at Conduit's loopback port while nothing listens there. That's by policy, but users will see it.

I haven't read the docs and will wait for the parent's freeze announcement before reviewing them. I didn't read the two added tests either, since the controls evidence was enough.
