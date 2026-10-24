# Private configuration transfer: sizing experiments

## Current: single-request candidate (decision 0018)

`SingleRequestCandidate.swift` is a test-only probe, derived from `Candidate.swift`. It
measures one complete private configuration update envelope, the shape selected by
[decision 0018](../../decisions/0018-private-configuration-request.md). It is not part of
`Package.swift`, not a production protocol, not an accepted wire schema, and it chooses no
configuration cap.

Executed by Codex on 2026-10-24 against foundation source checkpoint d438d01,
relevant-source fingerprint b3c8e71c7110ff39c8f2e9d16593eb407c52b7c47ef3b7bc2bf5588c0fd3d2d8.
Xcode swiftc compilation and execution both exited 0. `single-request-results.json`
is the actual output. All eleven runtime and platform round-trip preconditions pass.

Per fixture, using the same 11 synthetic fixtures and the same validation and equality
preconditions as `Candidate.swift`:

- `rawConfigBytes`: the canonical `ProxyConfig` JSON, from `CanonicalJSON.encoder()`.
- `singleFrameBytes`: one encoded envelope, from `ControlRuntimeCodec.makeEncoder()`, plus
  its line feed. The body carries the expected-prior runtime and platform revisions,
  generation, request ID, incarnation and budget. It also carries every runtime field
  except `schemaVersion`, including the three URL values, and every platform field except
  `launchAtLogin`. It has no caller-supplied receipts.
- `roundTripEqual`: the frame decodes back to a `ProxyConfig` equal to the input.
- `containsArtificialURLTokens`: whether the frame bytes contain an artificial token. The
  probe requires this to be true only for `artificial_urls`.

**Test-only warning.** The frame uses a deliberate generic `Codable` JSON-value mirror
(`V`). That mirror is a measurement shortcut. It is not the approved private codec in 0018.
The approved value must not conform to general `Codable`, and its codec keeps URL plaintext
off events, status, admission replies and outcome lookup. A token in this frame shows only
that the bytes carry the URL values. It does not show that ordinary surfaces are
token-free, which is a production obligation.

Output: one JSON array of rows, written with `CanonicalJSON.encoder()` (Unix-epoch dates,
sorted keys), not a plain `JSONEncoder`.

Not measured here: frame segmentation or chunks, frame, total-transfer or decode budgets,
admission, reassembly, cancellation, the production typed DTO, or the `SecretBytes` move.

Reproduction: compile against the built foundation objects using the historical procedure
below and execute the candidate. The output contains synthetic sizes only, never real config values.

| Fixture | rawConfigBytes | singleFrameBytes | roundTripEqual | containsArtificialURLTokens |
| --- | ---: | ---: | --- | --- |
| default | 1843 | 2301 | true | false |
| groups_40 | 23575 | 24033 | true | false |
| groups_1000 | 553075 | 553533 | true | false |
| groups_10000 | 5584075 | 5584533 | true | false |
| profile_utf8_1024 | 2860 | 3318 | true | false |
| profile_utf8_16384 | 18220 | 18678 | true | false |
| profile_utf8_65536 | 67372 | 67830 | true | false |
| profile_utf8_1048576 | 1050412 | 1050870 | true | false |
| escaping | 37898 | 38356 | true | false |
| artificial_urls | 1896 | 2357 | true | true |
| private_url_1MiB | 1050411 | 1050869 | true | false |

## Historical: two-envelope split probe (superseded for sizing, kept as evidence)

This section describes `Candidate.swift` and `results.json`. They measured the two-envelope
split that decision 0018 did not select. They are kept unchanged as evidence. They are not
the current candidate, and their numbers do not describe the single-request envelope.

Executed 2026-10-24 by Codex against the foundation's built ProxyKernel,
ConduitShared, RuntimeEvents and SwiftNIO objects. Source checkpoint: d438d01;
relevant-source fingerprint b3c8e71c7110ff39c8f2e9d16593eb407c52b7c47ef3b7bc2bf5588c0fd3d2d8.
The executable was compiled with Xcode swiftc, package name `conduit`, the built
module search path, module maps and those library objects. It ran with exit 0.

`Candidate.swift` is an external test-only probe, not part of Package.swift or a
production protocol. `results.json` is its actual size output. Every fixture
passes the existing validator and reconstructs a ProxyConfig equal to the input.
No real user configuration was read. Only artificial URL tokens were used; the
probe checks they are absent from the safe candidate and present in the private one.

The candidate ordinary envelope includes all currently encoded runtime fields
except schemaVersion and the three URL fields, platform settings except the
app-owned launchAtLogin, two provisional receipts and request/incarnation/budget
metadata. A second provisional private envelope carries the URL fields. The real
Swift encoder used by v2 produces the bytes. This is a generic JSON-value mirror
for sizing, not an accepted typed config schema. At that historical checkpoint, a one-envelope alternative had not been encoded;
these numbers describe only the two-envelope candidate. The current section above
records the later executed single-request probe.

`groups_N` contains N upstreams, N DNS entries, N intercepts and N tunnels: the
10,000 case therefore has 40,000 entries. Profile stress uses four-byte characters,
not an ASCII run that the display sanitizer would mask. The standalone default
raw size differs by six bytes from the earlier XCTest measurement; that difference
was not diagnosed. These are separate execution contexts, not a promise of one
fixed raw size. Candidate wire encoding explicitly sets its formatting. Collection
UUIDs have fixed encoded width.

The chunk probe encodes base64 payloads with a provisional JSON header and asserts
each encoded frame fits its 4 KiB or 16 KiB limit. It reports the sum of frames
for both candidate envelopes. It does not implement reassembly, backpressure,
cancellation, an admission engine or bounded total staging. `largestChunkFrame`
is the maximum across the two probed frame sizes, not a 4 KiB result.

No shipping limit, config restriction or snapshot registry is selected. A finite
frame cap cannot cover all currently unbounded accepted strings/counts. Actual
transfer, staging/decode-memory and presentation/inspection policies need an owner
choice and production-adapter/model verification before adoption.
