# Resource bounds and standalone shutdown fixes

This batch follows merged PRs #26–#28 and addresses S08, S09, R03, and the standalone DNS shutdown observation. The original review remains a record of its reviewed revision.

## Shared inbound admission (S08)

HTTP and SOCKS5 now reserve from one `inboundConnectionMaxLimit` budget before installing protocol handlers. Each accepted channel releases its reservation through its close future, including malformed handshakes, pipeline failures, disconnects, and tunnel closure. Rejected channels consume no reservation. The exposed inbound count includes both protocols and idle peers. Lowering the live limit stops new admissions without evicting existing channels.

SOCKS greeting and CONNECT-request parsing share a fixed ten-second total deadline (injectable in the server composition for tests). Progress does not reset it; completing the request cancels it before routing. The deadline does not apply to established tunnels. Negotiation buffers are bounded to the protocol maximum of 519 bytes; coalesced application payload before CONNECT success is rejected consistently across routing paths. Admission warnings/rejections and handshake timeout/oversize decisions emit structured events.

`pm-sim shared-inbound-budget` exercises mixed idle clients, excess clients on both listeners, partial greeting/request expiry, malformed requests, early payload, successful post-pressure routing, a tunnel surviving the deadline, live limit reduction, and final capacity recovery. XCTest separately checks admission accounting and live cap changes with embedded channels.

## PAC fetch bounds (S09)

The app's existing 256 KiB curl ceiling is now a shared contract. HTTPS response/data delegates check status and advertised length before allowing body delivery, then enforce the actual-byte ceiling in each chunk; unfinished transfers are cancelled on rejection or cancellation. Successful HTTP status is required. HTTPS redirects remain allowed only to HTTPS URLs without embedded credentials. Explicit HTTP uses the existing bounded injected transport. Unsupported schemes are rejected.

Regular-file reads run off the caller executor in bounded chunks, enforce the limit even if the file grows after metadata inspection, and observe cancellation between reads. These limits bound application accumulation; they are not an OS/network-filesystem I/O deadline guarantee.

Candidate evaluators execute one bounded probe for `http://127.0.0.1/` before installation, catching syntax errors, HTML responses, and missing entry points. This cannot validate every script branch. Fetch and candidate-validation failures preserve the last working evaluator.

`pm-sim pac-fetch-bounds` and XCTest use temporary files and synthetic URLSession transport. They cover exact limits, oversized unknown/advertised lengths, unsuccessful status, cancellation, redirect policy, malformed candidates, and last-good routing after rejected refresh.

## Bounded observability writers (R03)

Event, audit, and console writers share a bounded queue implementation. Defaults cap pending work, including the active batch, at 4,096 records and 4 MiB. Batches hold at most 128 records and 256 KiB; individual records larger than the batch byte cap are dropped. Overflow drops incoming records and increments counters; pending bytes/records, written records, drops, failures, and flush timeouts are observable. Console writes run off producer/NIO loops. Recording sinks also have explicit capacities.

Disk writes append batches rather than reading and rewriting the retained file for every record. A full generation is truncated before the next generation begins; only the current generation is retained, so history may shrink sharply at a boundary. A torn trailing record or oversized existing file retires that generation before new JSON is appended. The event/audit file caps remain 1 MiB/10 MiB by default. This is bounded retention, not a lossless audit archive or an fsync durability guarantee.

Flush waits have a two-second default deadline. Both daemon shutdown paths allow one final bounded event drain after recording a timeout, without recursively producing more timeout events. A timed-out OS write is not forcibly cancelled; retained memory remains bounded. Hosts drain queued records at termination and expose loss through status statistics or structured observations. Periodic status output emits only when the snapshot or writer statistics change, at no more than 10 Hz. Writer-only changes do not rewrite the snapshot file, and ticks run directly on the main-queue timer without queuing another task. Existing synchronous stdout backpressure remains outside this stderr/file-writer fix. The app's existing asynchronous final connection teardown still limits which final close records have been produced before process termination.

`pm-sim bounded-writers` blocks a storage callback while a real NIO loop produces records, checks retained byte/record caps and loss counts, proves a flush deadline, and checks recovery. A real file test counts bytes passed to file writes, exercises rotation, and decodes retained NDJSON. XCTest adds failure handling, torn-tail recovery, and recording-sink limits.

## Standalone DNS shutdown

`pm-dns` owns exactly two signal sources for process lifetime and one idempotent shutdown task. Readiness is emitted after signal handling is installed and reports the actual ephemeral port. TERM/INT wait for the DNS forwarder to close, then exit normally.

`scripts/test-dns-shutdown.py` checks TERM, INT, and repeated/mixed signals with scratch state and ephemeral loopback listeners. It verifies normal exit, accepted TCP closure, and UDP/TCP rebinding. A forced kill is failure cleanup only and cannot satisfy the regression.

## Validation

Passed on the final combined source:

- All products build using the installed CLT SDK 26.5 workaround below. Each of the four fix commits and the integration commit also builds independently.
- `pm-sim all`: all 32 scenarios pass, including the three new resource-bound scenarios, forced routing, privacy, security boundaries, flood recovery, auth pressure, and VPN/stream continuity checks.
- `scripts/test-security-boundaries.py`, `scripts/test-observable-target-redaction.py`, and `scripts/test-dns-shutdown.py` pass.
- The existing performance gate passes: all 100 clients opened and received data, no early closes, 10.16 seconds wall time, 29,753,344 bytes peak RSS (limits: 20 seconds / 200 MiB).
- The full-suite writer scenario drains 10,240 events in about 62 ms, submitting 727,779 encoded bytes and writing 717,686 bytes across 22 rotations. This measures this fixture's application write volume, not filesystem/device-level durability or a general throughput guarantee.
- New XCTest sources parse; `git diff --check` passes.

The required Xcode `swift test` invocation cannot start: `/Applications/Xcode.app` is absent. The CLT workaround also cannot run XCTest (`no such module 'XCTest'`). No XCTest pass is claimed. The existing CI XCTest step and new resource-bound/shutdown regression step are the remaining Xcode verification gate; sanitizers were not run locally.

```sh
DEVELOPER_DIR="/Library/Developer/CommandLineTools" xcrun swift build \
  --build-system native \
  --sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
```

The performance script used a temporary wrapper that adds those SDK/build-system flags, preserving the existing performance thresholds. Tests use synthetic data, temporary directories, and loopback peers; they do not install or invoke the privileged helper or alter the running app, Keychain, VPN, or system network settings.

### PR #29 review follow-ups

The first Xcode run executed 1,564 tests (three skipped) and found one regression: a valid SOCKS greeting coalesced with an oversized request no longer received its method-selection response. The bounded parser now preserves that response using only a bounded greeting prefix and still rejects the request before routing; fragmented greeting cases have regressions too.

Devin and Codex identified the shutdown timeout-event ordering; both daemon paths now use the same bounded final-drain operation. Codex also identified unconditional status heartbeat flooding; changed-value suppression and a 100 ms minimum interval now preserve writer-only observability without idle output floods. `scripts/test-status-stream.py` covers tiny requested intervals, unchanged snapshots, writer-only changes after rejected reload, and the publication rate ceiling.
