# Private configuration transfer: candidate sizing experiment

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
for sizing, not an accepted typed config schema. A one-envelope alternative has
not yet been encoded; these are measurements of the two-envelope candidate.

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
