# Actual observation and reply-handoff source guards

Executed at `8f5b71d676490ff60ee1c92ee5e0116cd8e88420`, after 351 focused tests
(two skips), independent subscription-backed review and the actual-host simulator.
[Results](results.json) pin the source/test trees, driver and commands.

| Deliberate production defect | Intended detection |
| --- | --- |
| Disconnect the actual host event sink from service ingress | The real framed stream misses its typed member settlement and reload observation; the diagnostic file still records them. |
| Omit the shutdown wakeup | An isolated parked service wait is not woken, despite no other event, snapshot or settlement being able to wake it. |
| Wait for cleanup on a timer-generated budget refusal | Submit/open budget refusals fail to detach while the owner hop remains deliberately stalled. |

All three variants failed their intended XCTest assertions, with no compiler
error, crash or process timeout. The baseline and exactly restored runs passed
all four selected tests. The driver restores exact bytes in a finally block and
checks product/test/script cleanliness. These are three property witnesses at
this checkpoint, not complete schedule exploration or installed-app validation.

Reproduce from a clean matching product/test checkpoint with Xcode available:

```sh
python3 docs/experiments/runtime-observation-guards/replay.py --repo "$PWD" --out /tmp/conduit-observation-guards-UNIQUE
```

The output directory must not exist. The driver temporarily edits three production
files and runs bounded tests; do not run it while another writer or build uses the
checkout. Every test uses fakes and owned scratch state. No installed Conduit or
helper is changed. Later source changes require a new identified run, not relabeling
this evidence.
