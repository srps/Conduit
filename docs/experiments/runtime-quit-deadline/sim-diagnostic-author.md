I've applied the approved diagnostic to `Sources/pm-sim/RuntimeHostEffectsScenarios.swift`, in `exercise()` only. It's frozen, and I haven't compiled or run it.

**Sink check:** `RecordingLogSink` behaves like the `DiscardingLogSink` it replaces in every way the host can observe:
- `drain` returns `.drained` immediately in both.
- `flush` and `statistics` are the protocol defaults in both (`true` and zero). The recording sink's own `droppedRecords` is a separate property, so the host's `console` loss counter in `reportWriterLoss` stays zero.
- The only difference is `minLevel`: `.warning` instead of `.error`. Nothing in ConduitRuntime, ProxyKernel or PlatformMac reads a logger's `minLevel` outside the log filter, so the change only means warning lines get recorded. No wrapper was needed.

**The delta:**
```diff
@@ private static func exercise(
         let terminalExits = NIOLockedValueBox(0)
+        // Warnings only, bounded, and like the discarding sink it replaces: nothing pending, so its drain is `drained` at once. It keeps
+        // the writers' refusal and flush lines, which a refused events file cannot hold, for an unconfirmed flush's note.
+        let warnings = RecordingLogSink(minLevel: .warning, capacity: 256)

         let host: RuntimeHost
         do {
             host = try await RuntimeHost.open(
                 stateSession: session,
-                logger: DiscardingLogSink(),
+                logger: warnings,
@@ success path
             notes.append("joined: startRuntime and stopRuntime returned; settle=\(settled); flushEvents allConfirmed=\(flush.allConfirmed)")
+            if !flush.allConfirmed { notes.append(unconfirmedFlushFacts(flush, warnings)) }
@@ error path
             let flush = await host.flushEvents()
+            if !flush.allConfirmed { notes.append(unconfirmedFlushFacts(flush, warnings)) }
             quiesced = settled == .settled && flush.allConfirmed
@@ new static helper after exercise()
+    private static func unconfirmedFlushFacts(_ flush: DiagnosticFlushReport, _ warnings: RecordingLogSink) -> String
```

**What the helper prints:**
- The flush outcomes: `audit`, `events`, `eventsRetry`, `snapshot` and `snapshotEvent`.
- For both the events and audit writers: written, failed, dropped, timeouts and pending (records and bytes).
- `failed events writes logged=N`: only the number of "Failed to write events.ndjson" lines, never their text.
- `warnings kept=N lost=N`, so a full buffer is visible.
- `fixed warnings=[…]`: only lines that start with `config.diagnostic_destination_refused` (fixed `sink=`/`reason=`/`resource=` codes) or `observability.` (fixed outcome codes and counters).

**What didn't change:** every assertion, budget and wait in the scenario, the other exercises and all production paths. The six files frozen earlier are untouched, including the cap change.

I left out the phase-duration timings from my second proposal, since the approval covered only the warning capture and the note. Those timings would show where the 9.4 s readiness gap went, so I can add them if you want them for a later run.

When the instrumented run finishes, I'll classify the result from its note. I won't call it a cap regression or plain slowness without the reported outcomes.
