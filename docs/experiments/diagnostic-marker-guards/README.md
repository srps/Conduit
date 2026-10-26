# Diagnostic marker reservation guards

Executed source mutations for the diagnostic marker correction. Apply one patch to
the recorded production source, then run its `xcrun swift test --filter` selection
with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`. Each selected
mutation compiled and failed XCTest assertions; original source bytes were restored,
and all 28 waiter/phase tests passed. `results.json` records source, mutant and patch
hashes, exact selections and assertions. These are negative controls, not shipping changes.

- `events-one-timer`: reintroduces the original single-slot events policy; both
  actual DiagnosticFlush compositions fail seven assertions.
- `release-all-timers`: releases every physical timer reservation when one ends;
  the improved saturation test observes an admitted fourth wait and an extra timer.
- `ignore-notify-custody`: admits another wait after timeout while the original
  notify is held; the hand-written history table rejects those outcomes.

The first `release-all-timers` run survived a different cleanup-count test. Callback
delivery order did not prove that an additional cleanup was absent. The revised
witness tests capacity while two identified bodies remain held, so admission itself
provides the evidence. Keep that initial survivor visible; do not count it as a
successful negative control. The source hashes for the two mutated files match the
current corrected source; the later cleanup-comment change affects a different file.

A temporary traced replay resolved the notify-table question: both the single
`timedOut` history and `drainedHeld → timedOut` history returned `timedOut` where
`busy` was required. XCTest reported one diagnostic at the shared assertion line.
`notify-trace.json` records the observed outcomes; no framework-internal cause is
claimed. The instrumentation was removed byte-for-byte and all 28 tests passed.
The complete workflow source fingerprint still matches the verified checkpoint.
