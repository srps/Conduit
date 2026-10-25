# Runtime display contract: verification, 2026-10-25

The v2 snapshot/row/probe projection now bounds display text through one shared
redaction policy, names shortened/omitted fields with bounded typed notices, and
refuses malformed display values on encode/decode. Stored values, command inputs,
stable IDs, counts, known events, v1 and helper IPC retain their selected contracts.
The v2 service and probe adapter remain unadopted by RuntimeHost/AppState.

## Source and executed checks

All **40 local steps of `.github/workflows/swift.yml` passed**, including the full
Swift suite (**3,286 tests, two skips, zero failures**), all **100 simulator result
records**, import/event/decision checks, native entry sequencing stand-ins,
updater/signing-script regressions and existing proxy perf. The source/test
fingerprint was stable throughout that run:
`87242cde1942f4e20203f53088e19996382487cb846050856196ac22bbe4b6af`.

Two comment corrections followed: the notice checker no longer claims zero
allocations, and the row fixture correctly describes which cap its text exceeds.
The current runtime/test fingerprint is
`8367d674cfe3c42ded709dec9b22a661786605722b4a7602d833fb35e3d6d626`.
An exact file comparison against the reviewed snapshot confirms those are the
only source/test differences. No executable statement changed. The 28 display
and codec tests passed again; decision/history checks and their mutation tests
also pass after recording the newly selected [0030](decisions/0030-ordinary-runtime-reply-frame-cap.md).
The full workflow was not repeated solely for those comments.

The first focused run had 11 failures from obsolete/malformed fixtures. They were
repaired without weakening the replay-gap, resync or retained-outcome recovery
checks. Direct raw probe DTOs over the new caps are refused, rather than silently
truncated. The second focused run passed 357 tests and three simulator scenarios;
that preceded the final allocation fix and widened fixture. The full 40 result
above covers both final behavioral changes.

## Independent collaboration and findings

Official Claude Code implemented and ran focused verification through the
owner's verified `claude.ai` Max subscription (`authMethod=claude.ai`,
`apiProvider=firstParty`). A separate subscription-backed Claude process reviewed
the candidate and final lifetime correction. No API credential, Agent SDK or
API-billed fallback was used. Codex reviewed source, ran the complete workflow
and executed the release allocation probes. Neither reviewer claims installed
release or production-host validation from these checks.

The material allocation finding was an inherited Foundation temporary lifetime
inside the shared display sanitizer. Without a caller pool, 11 synthetic updates
at the input gate retained about 27.8 MB of live malloc. A synchronous inner scope
now drains sanitizer temporaries after each field. The unchanged-text result
uses ordinary Swift ownership; no speculative native-string copy or new cache
was added. All seven final cases remain flat (+16 B observed) from the first to
the 101st released update without caller pools. This is a scoped measurement,
not a universal memory guarantee or a leak claim for the installed app.

Exact before/after sources, results, the URL-dense work samples and limitations
are in [the experiment record](experiments/runtime-display-codec/README.md).
Its reproduction script was also executed successfully from a fresh module
cache for all seven final cases and both URL-dense cases. The first fresh-cache
attempt lacked generated NIO C module maps; the runner now supplies them
explicitly. No product dependency or access changed for that repair.

The independent review found no remaining semantic blocker after the lifetime
fix. Comment/measurement wording was corrected. Remaining scoped gaps: the
seeded model independently tests grapheme-prefix cutting; secret redaction is
covered by fixed grammar witnesses. JSON's known notice-array count is tested;
a count-nil custom decoder is not. Both over-frame and over-field values can
report `frameTooLarge` first because size preflight precedes typed encoding;
both are refused. Full row memory and actual-host scheduling are not measured.

## Frame decision and remaining adoption work

The actual widened baseline is **49,376 bytes including its line feed**, with
49,073 bytes of bare snapshot JSON and 303 bytes of envelope. The point uses
maximal text escaping and widened metadata; it does not prove every finite
Double's longest encoding. The owner selected 64 KiB replies/stream frames in
[0030](decisions/0030-ordinary-runtime-reply-frame-cap.md). No shipping profile,
queue/retention/event/deadline defaults or actual client/host adoption is claimed.
The separate private 8 MiB configuration channel and v1 remain unchanged.

URL-dense scalar samples took tens of milliseconds on one host. Actual-host
Stop/status latency, bounded collection CPU work, private request concurrency,
store/workflow fences, RuntimeActor isolation, duplicate-path deletion, total
shutdown and the production v2 socket remain gates. The serving Conduit was not
quit, replaced or installed by this work. Hosted PR checks are recorded after
they complete; no clean automated-review result is inferred from unavailable bots.
