# Shared module owner: executed guard mutations

Twenty production-source mutations ran on 2026-10-27 against the shared owner at `a7f4366`. Each failed intended assertions without a compiler error or crash. Baseline and exactly restored runs passed all 80 focused module/model/physical tests. [`results-settlement.json`](results-settlement.json) records source/test identities, exit codes and assertion counts. The current replay implements those twenty removals.

The guards cover whole-request revisions, request-owned pending enables, unfinished-grant retirement, companion pair freshness, busy/verified/carried Stop saves, displaced-disable restoration and late own-enable completion; reverse DNS/tunnel Stop takeovers; joins after a failed member; whole proxy/DNS/tunnel start completion and old-handle clearing; inherited unconfigured cleanup and preservation of a user's loopback resolver. Each removal names its exact real workflow/host or physical witness in the replay. The tunnel-isolation removal also makes the independent actual-host model fail.

The first busy-event mutation correctly failed its equality assertion, then the test indexed the missing event and crashed. That attempt was excluded. The witness now compares through `first.map`, keeps the exact assertions and releases its parked reload. The strict runner rejects compiler/crash markers; all twenty checks were rerun cleanly. The earlier seven-check checkpoint remains historical in [`results.json`](results.json).

The actual-host model covers 241 sequential histories/590 transitions and eight gated Start/Stop histories. New deterministic witnesses cover additional reverse/mixed-scope interleavings; these do not establish all physical OS/NIO schedules or private framing. The capture model and separate physical-ordering experiment retain their own scopes.

```sh
python3 docs/experiments/runtime-module-guards/replay.py "$PWD"
```

Run without another source author or test process in that checkout. Every file restores in `finally`, then the restored suite must pass. The executed temporary driver differs only in root/output selection; this portable copy was syntax checked, not separately executed. Review exact sites after later changes. This is regression/guard evidence, not release or real-machine acceptance.
