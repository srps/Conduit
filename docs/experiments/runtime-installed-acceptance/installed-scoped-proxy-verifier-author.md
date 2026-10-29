# Scoped system-proxy proof: author report

Owned files: `verify-installed-lifecycle.py` (private, non-shipping) and `Tests/ConduitTests/NetworkLocationRecoveryTests.swift`
(two tests). No product code, docs, policy or other files touched. Nothing was run. The tool made no machine changes and
no owner report (R2, R4 `installed-lifecycle-uvvatdrr/report.json`) was opened for writing. Both files are frozen.

## Verifier delta (schema 1 → 2; CLI unchanged)

- **One OS read path.** `read_location_store` → `parse_location_store` reads `preferences.plist` read-only (bounded at
  8 MiB, `plistlib`). It reads the file twice around each journal read, and a change between the two reads gives
  `unstable`. Membership is `Sets/<set>/Network/Service/<svc>.__LINK__ == /NetworkServices/<svc>`, the active set is
  `CurrentSet`, and enabled means no `__INACTIVE__`. Caps are 64 sets, 256 memberships and 512 records.
  `project_managed_fields` reads only the 9 managed keys and ignores the rest, credentials included. It maps bool and
  integral numbers to int. A non-string list, another type, PAC user info or a validation failure makes the service
  unknown.
- **Journal.** `load_journal_items` is one bounded read shared by `read_journal` (same 4-tuples) and
  `scoped_proxy_records`. `decode_setting_value` accepts only exact `{"text"|"number"|"list": {"_0": …}}`.
  `decode_packed_settings` decodes `networkSettings` and `previousNetworkSettings`.
- **Preflight gate.** `capture_scoped_proxy` runs in inspect-only too. It keeps the prior, applied and previous fields
  of each scoped record in memory. Check `preflight.system_proxy_reader_matches_journal_applied` passes only if:
  - the journal is loaded and the store is `ok`;
  - there are no legacy records and more than 0 records;
  - every record's saved fields equal its APPLIED fields.

  Otherwise the check is `unproven` and the cycle does not begin. Each identity is reported with an HMAC token, the
  prior PAC class and enable flag, keyed prior/applied hashes, active/enabled, and in-flight state.
- **Start.** `wait_for(proxy_settlement)` waits up to the 20 s settle bound for
  `lifecycle.module_settled module=proxy source=explicit`. That detail is parsed from the existing shape in
  `event_counts`, which also adds per-module counts. Then `trace_start_records` counts how each Start prior compares
  with preflight: same as the preflight prior, same as the preflight **applied** (the self-recapture signature),
  other, or a new identity, plus `rebased_to_applied`. Since R5 review r1, every Start record goes into
  `ctx.quit_reference`, undecodable ones included; those become `record_unknown`. A record is marked
  `rebased_to_applied` by `rebased_onto_applied` when any restore group of its Start prior equals the preflight
  applied value while the preflight prior differs in that group. `ctx.proxy_capture` stays preflight-only.
- **Stop/Quit.** `settle_surfaces(ctx, phase)` now converges the existing checks, `scoped_restoration` and the global
  route inside the same 20 s bound.
  - Reference: after Stop it is the preflight capture. After Quit it is `{**proxy_capture, **quit_reference}`, the
    prior Start tracked, with preflight as the fallback for identities Start did not re-record. The same reference
    feeds both `scoped_restoration` and `route_origin`.
  - A reference marked `rebased_to_applied` gets that outcome. The outcome is in `SCOPED_UNKNOWN`, so it is
    unproven and the route can never be attention. `route_origin` also never treats such a record as a preserved
    prior.
  - R5 review r2 fix: an endpoint that a rebased reference's prior holds gets the origin `rebased_prior_held`. It
    must be in the active location, on an enabled member with readable fields, and held by both the prior and the
    current fields. Before this fix the endpoint fell through to `introduced_by_applied`, which made the route
    check fail.
    - Order, worst first: `introduced_by_applied`, `unattributed`, `rebased_prior_held`,
      `preexisting_prior_preserved`.
    - `route_verdict` passes through a `fail` or `pending` scoped verdict. Otherwise the result is `unproven`.
    - `settle_surfaces` treats `rebased_prior_held` as converged.
  - Same-session drift onto the applied value still fails: the restored group equals Start's applied value, so the
    outcome is `applied_retained`.
  - Check `system_proxy_fields_restored_to_captured_priors` (`scoped_verdict`):
    - `fail`: an applied or previous group is still present after release (`group_outcome`, restore's groups).
    - `pending`: a record is retained.
    - `unproven`: anything is unknown, membership changed or the protocol is absent. At Quit it is also `unproven`
      if the Start settlement was not observed as `started`.
    - `attention`: an external difference.
    - `pass`: every identity is exactly restored.
  - Check `system_proxy_route_to_conduit_ownership` replaces `no_active_system_proxy_route_to_conduit` and the
    physical-equivalence skip. `route_origin` matches the exact endpoint: the full PAC URL with enable, or
    host + port + enable.
    - `attention` (`preexisting_prior_preserved`): the endpoint equals a captured prior that an enabled service of
      the current active location still holds, and the scoped verdict passed.
    - `fail`: `introduced_by_applied` or `unattributed`, once settled.
    - `unproven`: unknown.

    The report gets route counts and the origin enum only.
- Privacy: tokens and hashes use `os.urandom` HMAC keys that stay in memory. No URL, host, ID or value is written or
  printed.

Pure helpers for fixtures: `project_managed_fields`, `managed_fields_valid`, `pac_url_acceptable`,
`decode_setting_value`, `decode_packed_settings`, `scoped_proxy_records`, `parse_location_store`, `pac_class`,
`rebased_onto_applied`, `trace_start_records` (with a stub `ctx` holding `proxy_capture` and `quit_reference`),
`group_outcome`, `scoped_restoration`, `scoped_settled`, `scoped_verdict`, `endpoint_held`, `route_origin`,
`route_verdict`, and `residue_from_scutil_text(…, endpoints)`. The new argument is optional, so old calls still work.

## Tests (product policy contract; no new harness, sleeps or API)

- `testFreshJournalPreservesUserConduitLookingPACAndRemovesOnlyIntroducedFields`: the analogue of the DNS loopback test.
  An untracked PAC that matches `LocalListenerFingerprint` survives `recover`. Applying in manual mode and in PAC mode,
  each followed by clear, leaves the snapshot exactly at the original, and the introduced HTTP/HTTPS/bypass fields are
  removed.
- `testReapplyAfterExternalBypassEditKeepsOriginalPACPriorRatherThanAppliedPAC`: reapplying with a record after an
  external bypass edit emits `location_restore`. It recaptures the prior as corporate PAC + external bypass, never the
  applied loopback PAC, and clear returns exactly that.

  Useful counterfactual: skip `restoreRecord` at `LocationSettingsRecovery.swift:230-233`, or forget and recapture
  current. Either makes the prior assertion fail.

## Limits

- The bypass-entry grammar and URLComponents strictness are approximated. A mismatch makes the result unknown or
  unproven, never a pass.
- A VPN or runtime publisher of the global view is attributed only through an exact match against a captured prior.
- Untracked services are not judged.
- Identities first recorded after the Start read are not compared. Records Start re-applied after its read keep
  the preflight reference.
- R4's origin stays unattributed. The current journal has 1 Conduit-loopback-PAC prior, so the expected next outcome
  is attention, not pass.
- Not syntax-checked here. The parent should run `python3 -I -m py_compile`, then `--inspect-only` (expect 8/8
  `os_equals_applied`), then the focused test class, before independent review.
