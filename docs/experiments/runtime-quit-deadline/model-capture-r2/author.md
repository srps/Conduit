I replaced the two nested helpers in the preferences model test with a plain value type, so no nested function captures a mutable local any more. It's an edit only to `Tests/ConduitTests/ConfigurationStoreTests.swift`. I haven't built or run anything, and the file is now frozen for review and your gates.

## Changed shapes

**Added `PreferencesModel`** (`ConfigurationStoreTests.swift:1221`), a private struct next to `ReplaySource`:
- **Fields:** `adopted`, `latched`, `baseline: Data?`, `version: UInt64`, `sidecarSource: Int?`, `adoptedShows`. These replace the per-segment locals `adopted`, `latched`, `modelBaseline`, `modelVersion`, `modelSource` and `adoptedShows`, with the same starting values.
- **Method:** `mutating func adoptLoad(external:externalShows:runtimeVariant:) -> Bool`. It does what `adoptModel()` did, and it absorbs `loadedShows()`, which only `adoptModel()` ever called. It returns whether the reload was one where only the missing sidecar's value moved.

**Removed** both nested `@RuntimeActor func loadedShows()` and `@RuntimeActor func adoptModel()`.

**Call sites:**
- The three places that called `adoptModel()` now call `if model.adoptLoad(external: external, externalShows: externalShows, runtimeVariant: runtimeVariant) { valueMovedReloads += 1 }`: the segment start, the value-probe loop, and the non-refused reload. In the reload case it became `else if model.adoptLoad(...)`.
- Every other read or write of the old locals in the test body now goes through `model.<field>`.
- `external`, `externalShows`, `runtimeVariant` and the counters stay test locals, because their lifetimes differ: `external` and `externalShows` carry across segments, while `model` and `runtimeVariant` reset each segment.

**Semantics are unchanged:**
- **Single computation:** `loadedShows` is now computed once per adopt instead of twice. Nothing changed its three inputs between the two original calls, so the result is the same.
- **Counter check order:** the "only the value moved" check is still evaluated before any field changes, exactly as the old `valueMovedReloads` check was.
- **Untouched:** every operation, seed, trace string, assertion, expected outcome, the required set, and the final witness assertions.

## Why the annotation didn't help (my reading, not proven)

- **What the errors show:** the three flagged names are exactly the variables `loadedShows()` captures. Adding `@RuntimeActor` changed nothing, which suggests the compiler had already inferred that isolation. So the problem isn't the declared isolation; it's how the captured variables are tracked.
- **Evidence in the same file:** the runtime/platform model test (`:1007`–`:1021`) also has nested functions that capture mutable locals, with no annotation, and it passed the same 6.3.3 optimized build. What's different in the failing test is that one nested function (`adoptModel`) calls another (`loadedShows`). That means `loadedShows`'s captured variables only reach it through `adoptModel`'s own captures. Also, `external` and `externalShows` are declared in the outer seed loop, not the segment scope.
- **Likely mechanism:** a captured `var` lives in a shared, non-Sendable box, even when its contents (`Data?`, `Int?`, `Bool?`) are Sendable. Inside `adoptModel`, those boxes arrive as its captures. It looks like 6.3.3's optimized build treats them as owned by the current task rather than by RuntimeActor, so referencing the RuntimeActor-isolated `loadedShows` counts as "sending" them. That matches the "task-isolated … later nonisolated uses" wording.
- **Limits:** this is inferred from the shapes and the error text; I haven't looked at the compiler's intermediate output. The fix doesn't depend on it being right: with no captures there are no boxes, so there's nothing to send. The new struct is a value with Sendable fields and no isolation, used the same way the file already uses `source.next(_:)`.

As you said, local 6.4 passing proves nothing about 6.3.3.

## Proposed verification (for you to run)

1. Hosted 6.3.3 optimized Release build on the new head. This is the only real proof.
2. Normal `ConfigurationStoreTests` locally (`DEVELOPER_DIR=… xcrun swift test --filter ConfigurationStoreTests`). Then the full `swift.yml` gates before pushing.
3. Review checks:
   - No nested `@RuntimeActor func` is left in the preferences test (the runtime/platform test's two nested helpers at `:1007`/`:1014` are deliberately left as they were).
   - The diff touches only this test file.
   - Every old `latched`/`modelBaseline`/`modelVersion`/`modelSource`/`adoptedShows` use maps one-to-one onto a `model.` field.