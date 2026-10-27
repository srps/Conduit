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

## Private updates and two-client authority

The next two frozen checkpoints add independent evidence; they do not change the
scope of the earlier 11-test experiment.

- [Private results before the freshness witness](private-results-before-freshness-witness.json):
  baseline and byte-restored runs passed 24 real-client tests. Five removals
  failed intended assertions: exact save baselines, recorded lifecycle results
  in receipts, admitted-input capacity, wire budgets, and the DNS Stop merge.
  Removing the apply pair-freshness check **survived** its existing test. That is
  a recorded coverage gap, assigned a direct replacement-during-apply witness;
  it is not evidence that the guard is unnecessary. Replay with
  replay-private.py OUTPUT --repo CHECKOUT.
- [Authority model results](authority-model-results.json): the independent model
  passed all 88 legal depth-three histories (264 transitions). Removing either
  exact save baselines or private request-ID reuse refusal failed the model's
  assertions; baseline and restored runs passed. Replay with
  replay-authority-model.py OUTPUT --repo CHECKOUT.

Both used fake machine effects and scratch roots, restored every mutated byte,
and rejected compiler/crash failures as evidence. The model covers two-client
save/read/reuse authority; draft rebasing is performed by its client adapter,
not claimed as production AppState behavior. It does not cover all lifecycle,
cancel/disconnect, expiry or physical schedules.

Each result records its independent checkout commit and a tree-equivalent
implementation commit. Portable drivers verify recorded source/test SHA-256
values before writing, require a new output directory, and were syntax-checked.
The executed temporary drivers used the same checks with fixed paths.
