# Actual-client owner guard checks

Executed on 2026-10-27 against the frozen observation/client checkpoint, before
private operations were implemented. The independent verification checkout's
commit and tree, source/test SHA-256 values and assertion excerpts are in
[results.json](results.json). This is source-guard evidence, not release acceptance
or proof of all client schedules.

The baseline and byte-restored run each passed all 11 `RuntimeHostControlOwnerTests`.
Each guard was removed independently; its actual host → service → in-memory
transport → framed-client witness then failed the intended assertions:

| Removed guard | Observed failure |
| --- | --- |
| Reserve a future presentation revision when settlement cannot project | Stop completion cited the prior body; recovery took a different revision |
| Check the DNS revision the client supplied | Stale companion Restart was accepted and moved intent |
| Release a superseded queued Stop admission | Pending admission remained; harness retained the unsettled host/root |

No mutation was counted on a compiler failure, crash or fatal assertion. The
source bytes were restored after every mutation, including failure exits.
The unsettled-host mutant intentionally leaves its authority retained until its
isolated test process exits; it never exercises a production state directory.

To reproduce, use a checkout containing the recorded source/test bytes and built
with Xcode, then run `python3 docs/experiments/runtime-client-owner-guards/replay.py
/private/tmp/conduit-client-guards-replay --repo /absolute/path/to/Conduit`.
The output directory must be new. The script verifies the two source identities,
runs a baseline, each isolated mutation and the restored suite, and writes logs
and JSON results. It requires write access to that isolated checkout; never run
it over another agent's active changes. The portable script was syntax-checked;
the executed temporary driver used the same mutation and assertion checks with a
fixed worktree/output path.
