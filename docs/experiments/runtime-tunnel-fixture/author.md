I replaced the swallowed shutdown error in `TunnelForwarderTests.tearDown`. Nothing has been compiled or run, both test files are frozen again, and I couldn't compute file hashes without Bash, so the parent needs to add those to the manifest.

**The change:** `try? group.syncShutdownGracefully()` is now `XCTAssertNoThrow(try group.syncShutdownGracefully(), "The event loop group should shut down cleanly")`. It's the same call in the same place; the only difference is that a shutdown error now fails the test instead of being thrown away. I left every other legacy fixture alone, including the `try?` in `testSessionLimitRejectsExcessConnections`.

## R2 manifest (relative to the original f59 test files)

**`Tests/ConduitTests/ProxiedTunnelTests.swift`** (unchanged since R1)
- **Removed:** the two copied integration tests, `ProxiedTunnelClientHandlerForTest`, `ProxiedRelay`, the private mocks, `NoOpAuthenticator`, the group setUp/tearDown and the NIO imports.
- **Kept:** the 10 pure definition, tracker, limits and listen-host tests, with an updated header comment.

**`Tests/ConduitTests/TunnelForwarderTests.swift`**
1. **R1 integration test:** `testProxiedTunnelCarriesMongoDBBytesExactlyAndLogsTheDetectedProtocol`. It holds the mock proxy's dial, sends a MongoDB message through the real forwarder, and asserts nothing reaches the target until the dial is released. Then it checks the bytes arrive exactly, that they're detected as MongoDB, and that the real handler logs the detection exactly once. Its cleanup runs on every path, joins the mock's dials before shutdown, and reports any failure.
2. **R1 helpers:**
   - `MockConnectProxy.start(group:dials:)`, whose new parameter defaults to nil so existing callers are unchanged.
   - `MockProxyDials`, `TunnelLogSignal`, `awaitSignal`, `closeFailure`, `TestEnded` and `MissingSignal`.
   - The moved MongoDB message builders, with their unused parameters dropped and the same bytes.
   - Comments that pointed at the deleted copy are updated.
3. **R2 fix:** `MockProxyDials` now keeps its closed flag and dial list under one lock. `join()` closes the record and takes its snapshot in a single locked step, and `dial()` returns nil once the record is closed or full (cap still 4).
4. **R2 witness:** `testJoinedMockProxyDialsAdmitNoLaterDial`. It needs no network: it checks that after `join()`, a late dial is refused whether or not the record was released, and that the connect closure is never called. It uses `UnexpectedConnect` and `lateDialOutcome`.
5. **R2 cleanup:** the `XCTAssertNoThrow` shutdown in `tearDown`, as above.

## Verification plan (yours to run)

- Run the focused tests normally. There should be 24: 14 in TunnelForwarderTests plus 10 in ProxiedTunnelTests.
- **Closed-guard control:** remove only `!record.closed`. Both `XCTAssertNil` assertions should fail with "admitted, then failed with …" and the connect count should be 1, with no network use and no leaked promise.
- **Release-only control:** remove only `dials.release()`. This should fail with the five-second missing-signal error and still clean up.
- **Combined control:** remove both `dials.release()` and the bytes wait. The bit-exact and protocol assertions should fail while cleanup still joins the gate.
- Restore the exact bytes after each control, then run all 41 checks and the hosted optimized Release.