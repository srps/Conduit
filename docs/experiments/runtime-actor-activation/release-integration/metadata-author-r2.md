I've made all four corrections. Only `CHANGELOG.md` and `docs/decisions/0037-saved-command-preparation-capture.md` changed this round, and I ran no checks.

**`CHANGELOG.md` (Unreleased only)**
- **(1) Strict-files bullet:** "Unknown fields are still kept" now reads "Valid unknown fields are still accepted, and the first of a repeated key still wins." It no longer claims they are kept across saves.
- **(4) Shared-host bullet:** "keep only unsaved edits and display state" now says the app keeps edit drafts, presentation and UI policy for the runtime. Composition, helper administration and updates stay with the app.
- **(3) New Compatibility bullet:** a save that doesn't come from the Settings controls, such as a typed submission from a tool, refuses a probe timeout that isn't a whole number of milliseconds and a direct-connect cache TTL that isn't a whole number of minutes, instead of truncating. The Settings fields already take whole units and are unchanged. No API or mode is mentioned.

**`docs/decisions/0037-saved-command-preparation-capture.md`**
- **(2)** I replaced the sentence that made a forced machine check of the interruption a requirement. It now says the actual-client harness covers the race, no second forced race on the installed app or real helper is required, and ordinary real-helper and app acceptance of the release is still due. Statuses stay `implemented | pending`, and the README row is unchanged.

Everything else is as I left it at the last freeze, including the corrected 0.5.7 sentence. These files are frozen again.