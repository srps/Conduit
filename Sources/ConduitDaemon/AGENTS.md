# ConduitDaemon

The daemon runtime host: `AppState`'s twin over the same managers and `RuntimeReconciler`.

- A lifecycle rule added to one host lands in the other. Add the twin scenario to `Tests/ConduitTests/DaemonRuntimeHostTests.swift` over the same `FakeMachine`. Where the daemon cannot express it yet, add a strict `XCTExpectFailure` naming what the migration still has to bring over.
