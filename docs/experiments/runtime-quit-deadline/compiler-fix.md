I made one test-only change for the Swift 6.3.3 optimized compile failure. Nothing is compiled or verified until you build it.

**Change** (`Tests/ConduitTests/ConfigurationStoreTests.swift:1260,1263`, inside `testABoundedModelOverPreferencesMatchesTheStoreForReplayableSeeds`):
```diff
-                func loadedShows() -> Bool {
+                @RuntimeActor func loadedShows() -> Bool {
                     external == nil ? runtimeVariant != 1 : externalShows != false
                 }
-                func adoptModel() {
+                @RuntimeActor func adoptModel() {
```

**Cause:** These two local functions read and change the test's mutable locals (`external`, `runtimeVariant`, `externalShows`, and in `adoptModel` the model counters). They are only ever called synchronously from the test body, which already runs on `@RuntimeActor`. Swift 6.3.3's optimized build doesn't infer that isolation for local functions, so it treats the captured locals as crossing an isolation boundary and reports the three "risks data races" errors at `:1261`.

**Why this fix:** Marking both functions `@RuntimeActor` states the isolation they already had. Both need it, because `adoptModel` calls `loadedShows`. There's no `@unchecked`, nothing is copied out of the captured locals, and the seeds, step counts, model rules, reachability set and all assertions are unchanged.

**Not changed:**
- The other local functions in this file, `authorityRefusal` and `snapshot` at `:1007`/`:1014`, follow a similar pattern. Your log shows no error for them, so I left them alone. If the older compiler later reports them, the same one-word annotation applies.
- `RuntimeHostControlOwnerTests.swift`: no timing or other changes, as you asked.
- No Source, metadata or artifact edits.

The files are frozen again.