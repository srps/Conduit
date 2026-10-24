# Platform and preferences file boundary checkpoint

Status: owner selected 128 KiB per sidecar with strict shared filtering; see
[decision 0026](decisions/0026-bounded-platform-and-preferences-files.md). Codex and Claude reviewed the actual persistence/field
inventory using Claude Code on the owner's claude.ai Max subscription. The shared reader, gate and schema now serve both sidecar
reads, the preference URL check and staged saves, and the combined migration stages before it writes. The async store, physical
sidecar replacement and startup or writer adoption beyond these reads remain separate work.

## Current boundary and ownership

`PlatformIntegrationConfig` has five booleans and `systemProxyMode`. `AppPreferences`
has five booleans and `preferredBrowserTestURL`. Their sidecar readers share an
unbounded `Data(contentsOf:)` followed by typed decoding; their writers share
`writeJSON`/`writeData` in ProxyConfigPersistence. The full loader reads each once
before deciding which legacy runtime components it needs.

The selected 16 KiB raw UTF-8 URL ceiling also covers the preferences URL, including
whitespace before blank-value fallback. Its ordinary sidecar save/read checks are
missing; runtime legacy extraction already checks it. A post-decode check does
not bound input allocation. The current records scope the physical 8 MiB cap and
strict discarded-value grammar to the runtime file. Extending those to sidecars
changes startup acceptance and must be explicit. The recovery journal remains a
separate runtime-state format with no new cap or grammar selected here.

## Recommended shape

Reuse the bounded reader, strict lexical cursor, resource policy and file filter.
Add component schema roots from the existing CodingKeys, with explicit sidecar
wrong-kind refusal rather than legacy warning/default fallback. Preserve valid
unknown fields, first-known-key-wins including escaped spellings, and ignored
huge exponents. Validate syntax/UTF-8/Unicode even in discarded values. Refuse
before typed expansion or migration writes and preserve rejected originals.

Ordinary preference saves check the same browser-URL policy before writing, then
stage and size-check canonical bytes. The future sole store consumes these bytes
and verifies physical outcomes; hosts do not repeat encoding/policy. Preferences
remain independent and cannot veto a separately verified runtime commit.

## Alternatives and recommendation

| File cap, per sidecar | Benefit | Cost |
| --- | --- | --- |
| **128 KiB, recommended** | Fits every selected typed value with headroom; limits input/work for six settings. | Refuses valid files with excessive unknown content or padding. |
| **8 MiB** | Reuses the runtime cap and tolerates far more hand-edited extra content. | Permits up to 64 times as much input per sidecar. |

A 16,384-byte URL needs at most six encoded bytes per decoded byte: 98,304 bytes
plus fixed keys, booleans and pretty-printing, below 131,072 bytes. Pin this bound
against the actual canonical encoder before adoption; it is not an RSS guarantee.
Platform output is far smaller. Both caps use strict shared filtering. Preserving
malformed ignored strings would require a permissive lexical mode; neither option
recommends it. That exact sidecar tolerance has not been separately probed; the
old-runtime decoder witness motivates the compatibility concern.

Revisit for a concrete new field that cannot fit, with compatibility fixtures and
measured input/working-memory cost. The cap/schema stay behind persistence, so
future daemon/client APIs remain stable. No registry is required.

## Verification and limits

Test exact/one-over file and raw URL budgets, worst escaping, whitespace fallback,
valid unknown/escaped duplicates, malformed discarded values, wrong-kind refusal,
standalone/combined readers, migration staging, preserved rejected bytes and actual
Settings refusal presentation. Verify one reader/filter/resource policy path.
This does not establish journal bounds, complete writer adoption, global memory,
Stop/status fairness or release readiness.
