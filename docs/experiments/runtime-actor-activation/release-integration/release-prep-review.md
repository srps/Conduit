**ACCEPT.** I found no required factual fix. I reviewed only the frozen `release-prep.patch` and its manifest, which shows an empty production-module diff against `f3abd5f`, and grepped Source only to confirm the event names. I didn't re-review Source.

What I checked, against the reviews already accepted:

- **Compatibility statements in CHANGELOG are accurate:**
  - "App-only, helper protocol v5 and helper behaviour unchanged" matches the actual-baseline review. The only helper-reachable change is the bypass width counter, which is equivalent to the old `JSONEncoder` measurement.
  - Schema two, the journal format and v1 are stated as unchanged, and "0.5.8 can still read what this version writes" matches that review too. The v1 protocol qualifier rests on decision 0037's existing statement.
- **Event names exist in Source:** `config.save_rejected`, `config.save_unverified`, `config.state_root_busy` and `config.state_root_refused` (`SettingsSaveNotice.swift:148-157`, `StateRootSession.swift:224-230`, `ProxyConfigPersistence.swift:537-636`).
- **Unknown fields:** the notes say valid unknown fields are "still accepted" and the first repeated key still wins. They don't claim unknown fields are kept when Conduit rewrites a file, which is correct.
- **Limits:** 8 MiB for `config.json`, 128 KiB for each sidecar, and 10,000 rows / 4 MiB with the total shown for an unavailable list. All match the selected profile.
- **Exact-duration item:** it is limited to saves made outside the Settings controls, and the Settings fields are unchanged. That fits the actual-baseline finding that every value loaded from a 0.5.8 file round-trips.
- **Stage 5 stays out of the release:**
  - Save-before-apply (0015) and its Stop/Quit exceptions move into the release notes. Per-surface applied state and partial durable writes stay in Stage 5.
  - The journal envelope is correctly a later release. Rewording the 0.5.7 entry's "0.6 starts writing" to "a later release" corrects a forward-looking sentence that would otherwise now be false.
- **Decision 0037:**
  - It is now implemented, with validation pending, and the README row matches.
  - The witness is `AppStateActivationParityTests` (`:782`), described as harness evidence, with no second forced race required on the real machine and installed acceptance still due.
- **Gates and history:**
  - ROADMAP and the activation checkpoint now separate the three heads: product `f3abd5f`, test-maintenance `7d85213` with its hosted pass including Swift 6.3.3, and `b637ec1` merged into draft #258, not main.
  - The remaining gates are listed consistently: CI on the final release head, merge to main, real-machine acceptance, then versioned packaging.
  - The stale merge-gate wording at ROADMAP `:181` is fixed.
- **Test comment:** it now correctly says `ProxyBypassSyntax` counts the width without encoding, and that the equivalence tests compare it with `JSONEncoder`.

**Optional, not required:** the CHANGELOG line "their ordering is checked against independent models" is slightly broad. Per #183, the models cover lifecycle, admission/replay and the verified store, not every listed event family's ordering. Something like "the owners that produce them are checked against independent models" would be exact.

Still pending, and not claimed by these docs: Root B full41 on the new head, CI on the final release head, the merge to main, owner-coordinated real-machine acceptance against the serving 0.5.8 at `/Users/SIS8LIS/projects/mac-proxy-tool/Conduit/Conduit.app`, and release-signed 0.6.0 packaging.