# Schema2 precision regression witness, 2026-10-24

Codex executed `OldMillisecondsRegressionWitness.swift` as a temporary XCTest file
against the unchanged pre-fix primary checkout at d86aae2518306e3d27fafea3f62fb0429a46b0e6.
The Xcode-prefixed `swift test --filter ExactMillisecondsRegressionWitnessTests`
command exited1 after running one test with exactly three assertion failures:
loaded seconds1.0 instead of1.001, legacy getter1000 instead of1001, and saved
integer milliseconds1000 instead of1001. The selected output is preserved in
`old-milliseconds-witness-result.txt`; only the checkout path was normalized.
The temporary test was removed after execution. No tracked primary source changed;
its two unrelated untracked owner documents were left untouched.

The witness saved and loaded synthetic configuration through actual
`ProxyConfigPersistence` in an owned scratch directory, then removed that
scratch directory. It did not read user configuration, open listeners, or touch
the serving app/helper/machine settings. This is an executed negative witness,
not a claim that every new test was run against old code.

On the separate precision implementation, Codex subsequently ran the focused
wrapper with the three independent NTLM protocol-length review tests included:
410 tests, zero failures; kernel import fence, event catalogue, decisions with
history and all eight `config-exact-persistence` assertions passed. This checkpoint
predates later review corrections and is superseded for final verification by
checks attached to the final committed source. It proves the old witness's case
is repaired in that source, not store admission, physical read-back receipts,
writer ordering, startup resource bounds or real-machine behavior.

The earlier direct scratch probe separately established90.5 seconds saving as60
seconds through integer-minute storage. Accepted decision0023 keeps schema2 and
explicitly refuses such an inexact ordinary save; no schema3 migration is selected.
