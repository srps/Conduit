# 0034: Complete private editor replies capped at eight MiB

- Date: 2026-10-26
- Decision: accepted (owner, 2026-10-26, #186: selected “8 MiB private replies (Recommended)”)
- Implementation: partial
- Validation: none
- Supersedes: none
- Superseded by: none

## Context

The editor needs a coherent memory observation containing the full bounded runtime,
platform and preference values, exact component baselines and lifecycle metadata.
A refused reload must still permit display of retained repair values without
manufacturing authority. Private URLs stay out of ordinary snapshots and events.

The owner selected this ceiling in [#186](https://github.com/srps/Conduit/issues/186)
after Claude reviewed the contract on the owner's verified claude.ai Max
subscription and Codex independently reproduced the [Release experiment](../experiments/private-editor-reply/README.md).
The actual maximum-string request measured 7,382,956 bytes. Its escaped text
content alone exceeds four MiB. The executed reply mirror's conservative estimate
is 7,523,543 bytes, leaving 865,065 bytes under eight MiB. That estimate covers
the mirror, not the finished API: per-module result metadata must still be
measured through the actual reply codec. It is no memory or latency guarantee.

## Decision

Cap one complete private editor reply at **8,388,608 encoded bytes**, including
its header, envelope and terminator. Keep this separately named from the
request ceiling, even though both are eight MiB. Ordinary v2 replies and stream
frames remain 65,536 bytes under [0030](0030-ordinary-runtime-reply-frame-cap.md);
legacy v1 and helper IPC retain their existing contracts.

Return at most one complete set of editor values per reply. Refuse an oversize
reply explicitly; never truncate configuration or silently omit required fields.
Reuse the existing private frame grammar, bounded buffer, counting/emitting
writer and schema-directed scanner. Count before allocating an encoded result,
and refuse an oversize declared length before buffering body bytes. Private
values remain non-Codable and redacted in reflection.

The actual codec must pass populated worst-case sizing and allocation-lifetime
checks before adoption. Include the host's retained values and the client's draft
in the same process, and verify Stop/status responsiveness through the actual
adapter. New bounded fields require fresh sizing evidence; the mirror's spare
bytes are not a license for unbounded metadata.

This selects no production lane/queue/outcome/replay/subscriber limits, private
custody total, deadline or total Quit budget. The single global active private
body/decode and independent Stop/status work/capacity remain selected by
[0021](0021-bounded-configuration-at-all-boundaries.md). The actual-host service
profile remains a separate measured owner choice. No AppState activation follows
from codec-only evidence.

## Alternatives

- **Four MiB or smaller with one reply:** cannot return the demonstrated loadable
  repair draft; its escaped text alone exceeds that ceiling. A smaller ceiling
  needs a split reply protocol or new configuration restrictions.
- **Split replies:** reduces each frame's reservation, but requires bounded
  partial-observation retention, ordering, incarnation/revision consistency,
  cancellation and completion handling. There is no measured need here.
- **Sixteen MiB:** no measured shape needs it. It doubles the worst-case reply
  reservation while leaving request charges unchanged; it does not double every
  term of total custody.
- **Unbounded replies or a snapshot registry:** breaks the bounded contract or
  introduces retention/expiry state contrary to the selected full-value path.

## Consequences

One reply remains a coherent observation and exercises the future daemon boundary
through the same codec in memory. The ceiling is encoded bytes, not running-app
RAM. Current request-codec process peaks are roughly 41–45 MB for the pathological
maximum fixture; they do not measure reply decoding, coexistence with a live host
or physical apply. Preserve explicit admission-unknown and dirty-draft semantics
when integrating this channel.

## Invariants and verification

Check exact-limit and one-byte-over refusal, hostile declared lengths, partial
input, strict syntax/UTF-8/Unicode/duplicate rules, full UInt64 baseline versions,
component/incarnation mismatches, redacted errors/reflection and equal round trips.
Use the shared production field/resource traversal rather than copied limits.
Measure the actual largest reply and transient copies in Release. Exercise busy,
cancel, disconnect and Stop during transfer before service adoption; the latter
requires the real host/client adapter and is not established by a mirror.

## Implementation evidence

The headless codec enforces the separate cap in
[`PrivateConfigurationFrame.swift`](../../Sources/ConduitShared/PrivateConfiguration/PrivateConfigurationFrame.swift),
[`PrivateConfigurationEncoder.swift`](../../Sources/ConduitShared/PrivateConfiguration/PrivateConfigurationEncoder.swift)
and [`PrivateConfigurationDecoder.swift`](../../Sources/ConduitShared/PrivateConfiguration/PrivateConfigurationDecoder.swift).
Read requests and correlated admission/observation/refusal replies use the same frame,
writer and scanner. Private observations hold one value set, exact baselines and
bounded module state; no live host or second writer is exposed.

[`PrivateEditorReplyCodecTests.swift`](../../Tests/ConduitTests/PrivateEditorReplyCodecTests.swift)
checks the reply cap, strict variants, correlation, resource preflight, redaction
and the widest-string fixture's measured 7,487,875-byte frame. That fixture uses
widest observed scalar spellings, not a proof of every finite Double spelling.
[`PrivateEditorCodecTests.swift`](../../Tests/ConduitTests/PrivateEditorCodecTests.swift)
checks exact UInt64 preconditions and the scanner's own overflow refusal.
[`ScenarioPrivateEditorCodec.swift`](../../Sources/pm-sim/ScenarioPrivateEditorCodec.swift)
exercises the actual codec with synthetic values and no machine effects.

Focused verification: 157 tests, event/decision checks and both private codec
scenarios passed. The initial size-calibration assertion was replaced with its
measured value; it was not a runtime defect. Full workflow, independent reply
review, Release lifetime/copy measurements and actual-host service adoption are
still due. Causal save receipts remain with the workflow that implements canonical
intent merging; admission is kept separate from settlement.

The [historical experiment](../experiments/private-editor-reply/README.md) supports
the ceiling choice and records its source hash, commands and independent rerun.
It does not establish the actual reply codec's allocation costs or a production
service profile.

Does not prove: actual reply size or allocation bounds, host/client transfer
fairness, complete sole-writer coverage, AppState convergence, installed-app
behavior or release readiness.

## Open questions

Select the production service profile, including private custody and the total
Quit budget, from actual-adapter measurements. Revisit this ceiling if a new
bounded field inventory cannot fit, encoding/redaction changes the size, measured
memory/fairness costs require another transfer shape, or a demonstrated workload
needs larger replies. Bring such a change to owner review before implementing it.
