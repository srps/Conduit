# Physical lifecycle guards: executed negative controls

Current shared-owner rerun (`a7f4366`, 2026-10-27): all six production-source mutations failed intended assertions without compiler errors or crashes; baseline and exactly restored runs passed 19 physical tests. [`results-owner-checkpoint.json`](results-owner-checkpoint.json) records code/test identity and outcomes. The current replay covers these six checks. Earlier results below retain their original scopes and source identities.


The first four actual production-source mutations were executed on 2026-10-27 in an isolated worktree. Each failed its named assertion; none was counted from a compiler failure or crash. Baseline and byte-exact restored runs passed all 12 physical-ordering tests. `results.json` records source hashes, targeted assertions and exit codes.

| Mutation | Actual witness |
| --- | --- |
| Let stale work claim the physical slot | A superseded effect must run nothing. |
| Publish a DNS bind after a newer Stop | The recorded snapshot history must contain no stale running state. |
| Rebind tunnels on a repeated Start | The same listener and live session/count must survive; no new admission. |
| Skip cleanup of the stale DNS bind | A replacement must bind the same TCP/UDP pair and final Stop must release both. |

The first baseline attempt, before any mutation, failed one TCP release assertion in an earlier ephemeral-port fixture. Its gate retained the first attempted UDP port even when the forwarder legitimately retried a different pair after TCP contention. That is a confirmed fixture ambiguity; the exact historical holder/schedule was not identified. The corrected fixture chooses a currently free configured pair, verifies both actual bindings and performs release probes without retrying them. The local ephemeral range was read as 49152–65535; the fixture chooses below it. Port selection still has a normal external bind race and fails loudly if one occurs.

A review follow-up made the restart epoch explicit and added three real-loopback histories, including config edits during a held Stop teardown. `results-review-followup.json` records all six executed mutations on that revised source: the original four, plus removing the outer DNS and tunnel `admitsRunning` checks. Every mutant failed intended assertions; the restored 15-test suite passed. The DNS mutant rebound after Stop and leaked its edited pair until fixture teardown; the tunnel mutant was stopped by its inner backstop but emitted an incorrect reconcile decision, which its event assertion detected. These scopes are deliberately distinct.

The updated portable replay contains all six. Run it from a worktree with no concurrent source author or test process:

```sh
python3 docs/experiments/runtime-physical-guards/replay.py "$PWD"
```

The executed command used a temporary driver. The archived replay changes only root/output selection and was syntax checked, not separately executed. It restores each modified file in `finally` and records each run in a fresh temporary directory. Exact hashes intentionally identify this source checkpoint; later code changes require reviewing the mutations again.

These are focused guard/regression witnesses. The helper tests are three direct histories, not an independent bounded model of the shared runtime. Host/client integration, broader resource ownership and release acceptance remain separate.
