**Verdict: compatible.** This can ship as an app-only update: the installed v5 helper works with the new app without a reinstall or re-pin, and rolling back to 0.5.8 is safe for every persisted file. I found no blocking issue, only three small points to record.

## Helper delta

`helper.patch` is authoritative; your corrected description matches it.

**Old and new bypass checks are equivalent:**
- **Entry size:** `maximumEntryBytes` was 253 and is now `DomainNameSyntax.maxLength`, which is also 253 (`DomainNameSyntax.swift:111`).
- **List size:**
  - The old code encoded the list with `JSONEncoder` and compared its byte count `<= 8_192`.
  - The new code counts the same width without encoding: quotes plus scalar widths, with `"`, `/`, `\` and the short control escapes counted as 2 bytes, other control characters as 6, then UTF-8 widths 1–4, plus brackets and commas (`DomainResourceLimits.swift:216-256`).
  - It compares with `<=` against `noProxyList`, which equals `ProxyBypassSyntax.maximumJSONBytes`, still 8,192 (`:48`, `:207-208`).
- **Order and the removed branch:** the count, item and size diagnostics run in the same order. The old "could not be encoded" branch is gone, but encoding an array of strings can't throw, so it was unreachable.
- **Pinned by tests:** `ConfigurationResourceCanonicalWidthTests.testCanonicalWidthMatchesJSONEncoderForEveryScalarValue` compares the counter with `JSONEncoder` for every Unicode scalar. Other tests pin exact-ceiling acceptance, one byte over, and the forward slash. All of them passed in the 3,768-test run.
- **Consequence:**
  - The new app and the old 0.5.8 helper give the same answer for every bypass list on this macOS.
  - If a different system Foundation ever produced a different width, the only effect would be a clean refusal at exactly the 8 KiB edge.
  - A reinstall is not needed: the old helper honors everything the new app sends, and the change fixes no helper bug.

**Note 1, for the record:** `ProxyBypassSyntax` now also reaches `Sources/ConduitShared/DomainResourceLimits.swift`, which is on the helper's validation path. The manifest's list of helper-reachable paths should include it.

## State delta

- **File names and default folder:** unchanged. The patch only names the existing strings as constants.
- **Schema version:** `ProxyConfig.currentSchemaVersion` is not changed, so the candidate writes the same version 0.5.8 accepts.
- **Sidecar files:**
  - The candidate reads `platform.json` and `preferences.json` first, and falls back to the legacy keys in `config.json` only when a sidecar is missing.
  - The 0.5.8 code removed in the patch (`state.patch:877-900`) has exactly the same order.
  - So when the candidate rewrites `config.json` without the legacy keys, 0.5.8 still reads the sidecars after a rollback.
  - Migration writes are now staged before any physical write, and `config.json` is still rewritten last. That is stricter than 0.5.8, never looser.
- **Explicit `CodingKeys`:** they list every stored property of `PlatformIntegrationConfig` and `AppPreferences`, and the custom decoders are unchanged. No field stops being saved.
- **Encoding:** pretty canonical JSON instead of pretty, sorted `JSONEncoder` output. These types have no `Date` fields, so 0.5.8's `JSONDecoder` reads the new files.
- **Exact durations (`DurationUnits.swift:94-111`):**
  - A save now refuses `connectionCheckTimeout` values that aren't whole milliseconds and `directConnectTTL` values that aren't whole minutes. 0.5.8 truncated them.
  - Every value loaded from a 0.5.8 file is `Double(ms)/1000` or `minutes*60`, which round-trips exactly, so existing settings always save again.
  - **Note 2:** only a new edit with sub-millisecond precision is affected. I didn't check whether any Settings control can produce one. If one can, add a CHANGELOG line: "a timeout that isn't a whole number of milliseconds is refused instead of truncated."
- **Journal:** identical to v0.5.8, as you found.
- **Lock file:** `state-writer.lock` is new, and 0.5.8 never reads it.
- **Stricter reading** (filter, size limits, bounds): this can only stop the candidate from loading a file 0.5.8 accepted. It never makes 0.5.8 unable to read a file. Rolling back restores 0.5.8's reading. This is already covered by the strict-validation CHANGELOG item I proposed.

**Note 3, a comment that will mislead:** `ConfigurationResourceCanonicalWidthTests.swift:124` still says `ProxyBypassSyntax` "still measures with `JSONEncoder`". It no longer does. The test is correct; only the comment is out of date.

The plan from the earlier messages is unchanged: local acceptance with the current pin, release-signed packaging later, and never running alongside 0.5.8.
