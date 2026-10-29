I've made the metadata/docs slice in the seven files below. Nothing else was edited, and I ran no checks, so nothing about the new VERSION head is verified until you check it.

## Files changed
1. `VERSION`: `0.5.8` → `0.6.0`.
2. `CHANGELOG.md`:
   - **Unreleased section rewritten.** The intro says it's prepared as 0.6.0 and not released, and 0.5.8 is still the released version. It says this is an app-only update: helper v5 is unchanged and no reinstall is needed. Schema two, the journal format and v1 control are unchanged, so 0.5.8 can still read what this version writes. It says the production daemon/socket, the remaining event families and Stage 5 are not in this release.
   - **"Changed":** the shared host on RuntimeActor with responsiveness; the typed families and models (named as a subset); save-before-apply with the Stop/Quit exceptions; external edits refused until reload; the existing Start input-replacement note (now says the app reports the interruption); the 10 s Quit.
   - **New "Compatibility" heading:** the exclusive writer, and that 0.5.8 must be fully quit first and never run alongside; fixed filenames and the custom `ConduitDaemon --config` refusal; strict 8 MiB / 128 KiB startup files, kept unchanged when refused; the 10,000-row / 4 MiB list cap.
   - **One line in the released 0.5.7 notes:** "0.6 starts writing the new one" → "a later release starts writing the new one".
3. `ROADMAP.md`:
   - **"AppState, isolation and release" row:** now says the activation, isolation, profile, resource/fairness, native Dev and hosted checks pass. What's left: CI on #258's final head and the merge to main, real-machine acceptance, then signed packaging and publication.
   - **New current-evidence paragraph:** separates `f3abd5f` (product), `7d85213` (test maintenance) and `b637ec1` (merged into draft #258, not main). The older checkpoints are labelled historical.
   - **Stale statements fixed:** Stage 1 (AppState adoption, native app acceptance), Stage 3 (fairness as an open merge gate), Stage 4 (hosted and native checks pending, older compiler) and the #183 status.
   - **Stage 5:** the journal envelope is now a separate follow-up; the 0.6.0 candidate still writes the format 0.5.8 reads. The save-before-apply item now points to the core release notes.
4. `docs/verification-runtime-actor-activation-2026-10-28.md`:
   - The status lines are updated.
   - **New "Hosted result and integration" section:** the three-head distinction; Swift `40702811562` (including Swift 6.3.3), slow-drain `40702811595` and CodeQL all pass; every annotation was read and none is a finding; Devin skipped. Checks on the metadata head are left for you to record.
   - **New "Decision 0037 app witness" section:** the `~:782` test, with what it asserts and that it passed in the 3,768-test run. It is labelled harness evidence, not an installed-app check.
5. `docs/decisions/0037-saved-command-preparation-capture.md`: Implementation `partial` → `implemented`, Validation `none` → `pending`. The stale "remain under verification" text now points to the evidence. I added a dated activation/isolation evidence paragraph with a "Does not prove" line. The decision text itself is unchanged.
6. `docs/decisions/README.md`: the 0037 row now reads `implemented | pending`.
7. `ConfigurationResourceCanonicalWidthTests.swift:123-125`: only the doc comment changed. It now says `ProxyBypassSyntax` counts the width without encoding, and the equivalence tests above compare that count with `JSONEncoder`.

## Judgment calls and uncertainty
- **Exact-duration refusal is left out of the notes.** The Settings fields are whole milliseconds and minutes, and schema two stores whole units, so the app's UI can't produce a refused value. Add it if you count non-UI typed submissions as user-visible.
- **Merge gate or release gate.** Earlier docs disagreed on whether real-machine acceptance gates the merge. I wrote "remain open" without choosing; that's still an owner call.
- **I edited released 0.5.7 notes.** It's the only change to shipped notes, and it's one forward-looking sentence. Revert it if shipped notes must stay as they were.
- **"0.5.8 can still read what this version writes"** rests on the source-level compatibility review, not an actual rollback.
- **Hosted IDs are plain text, not links**, because I couldn't confirm whether they are run IDs or job IDs. The `7d85213` commit link uses the short prefix `7d852139`.
- **Before tagging, rename `## Unreleased` to `## 0.6.0`.** Otherwise the appcast notes fall back to just "Conduit 0.6.0." `test-appcast-notes.py` only checks a matching heading, so it passes as things are.
- **The VERSION change trips `release.yml`'s path filter**, so pull-request CI will run an ad-hoc packaging build. It has no secrets and publishes nothing.

These files are frozen; I'm making no further edits.