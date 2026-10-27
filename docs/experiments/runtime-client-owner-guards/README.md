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
  a recorded coverage gap; the final-client experiment below supplies and
  discriminates its replacement-during-apply witness. It is not evidence that
  the guard is unnecessary. Replay with
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

## Terminal and combined-apply guards

[Terminal/apply results](terminal-apply-results.json) cover the next frozen
checkpoint, before request-bound final-flush IDs and common private wait-gate
convergence. Baseline and byte-restored runs passed all 33 real-client owner
tests. Each of three removals failed intended assertions:

- An expired flush's claim left open allowed its queued write after Quit.
- Ignoring actionable apply revisions let Stop be followed by an unstarted save.
- Classifying Quit as ordinary made it compete with exhausted mutation capacity.

These were clean assertion failures, with no compiler/crash markers, and every
source byte was restored. Replay using replay-terminal-apply.py OUTPUT --repo
CHECKOUT on the recorded source/test bytes. Its portable driver was
syntax-checked; the executed driver used the same checks with fixed paths.
This does not close the separately recorded pair-replacement coverage gap,
verify the later request-bound reservation or establish release readiness.


## Replacement freshness and physical capacity wait

[Final client results](final-client-results.json) cover the tree-equivalent
implementation checkpoint `4825d24`. Baseline and exact-byte-restored runs each
passed all 48 actual-client owner tests. Two isolated removals failed cleanly:

- Removing pair freshness after the reconciler push caused two assertions: the
  receipt claimed the replaced pair was applied and its obsolete environment
  clear ran. This closes the earlier **surviving witness gap**, within this
  specific replacement schedule.
- Returning the capacity-wait permit before its cancelled timer physically ended
  caused three assertions: another waiter could enter and arm a timer. The
  bounded witness drained its clock/tasks and ended normally.

No compiler/crash failure was counted; all source bytes were restored. Replay
with `replay-final-client.py OUTPUT --repo CHECKOUT` using the recorded source/test
bytes. The portable driver was syntax-checked; the executed driver used the same
mutation/assertion checks without the portable preflight identity lookup. These
checks do not prove every cancellation or replacement schedule, production UI
draft behavior, a shipping memory bound or release readiness.


## Probe and terminal observation corrections

[Correction results](correction-results.json) cover the reviewed client corrections
and the strengthened held-probe witness. Baseline and exact-byte-restored runs
each passed all 54 actual-client owner tests. Two independent removals failed:

- Moving the DNS probe back onto the serial platform queue caused five ordering
  assertions: DNS Stop and Quit could not settle while that read was held. Two
  additional harness assertions reported unconfirmed shutdown after the mutation;
  its isolated process retained the host/root authority instead of releasing it
  unsafely. No compiler error, timeout or crash was counted.
- Returning from the lost-stream Quit path before the total deadline caused the
  intended deadline lower-bound assertion while teardown was still held.

All mutated bytes were restored. Replay with `replay-corrections.py OUTPUT --repo
CHECKOUT` using the recorded sources/tests. The portable driver was syntax-checked;
the executed driver used the same mutations/assertion checks without the portable
identity lookup. This proves discrimination of those two schedules, not all probe
ports, actor/OS schedules or release readiness.
