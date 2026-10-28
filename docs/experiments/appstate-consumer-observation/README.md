# App consumer capture observations

Three fresh Debug XCTest processes on stable source `2e8d9fe` exercise the actual
framed service/client, `RuntimeObserver`, `PageCollector` and presentation adapter.
Each reads 10,000 typical rows (3,006,968 encoded bytes, 47 pages) across four revisions,
asserting complete captures and bounded host retention. All structural assertions
pass. No other build/test/probe ran alongside these measurements.

Per-capture wall times ranged 1.348–1.376s. The 1 ms main-actor heartbeat observed
maximum lateness 0.677–0.691s, with four wakes above 100 ms per trial. This includes OS
timer/scheduler delay and is a Debug test observation, not a measurement of exact
main-actor occupancy or Release UI latency. Mapping 10,000 collected rows into the
adapter took1.80–1.87ms. The current main-actor host projection remains part of
the capture path; the separately selected RuntimeActor move still needs its own
responsiveness proof.

[Raw observations](results.json) include all three trials, four passes each and
RSS/malloc stages. The first command includes rebuilding Debug tests after the
Release build; use the per-pass observations, not that wrapper's elapsed time,
for capture comparisons. The fake projection owner uses production framing and
projection; this does not measure real traffic cadence or SwiftUI rendering.

The collector enforces 4 MiB / 10,000 rows and the host's retained row ledger enforces
8 MiB across lists. The app display array is count-bounded; its objects/strings and
brief old/new/collector overlap are not included in that host accounting. These
observations establish no app memory ceiling or installed-build footprint.
