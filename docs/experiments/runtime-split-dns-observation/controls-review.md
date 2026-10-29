**ACCEPT.** The results, failure lines and patches back each control's claimed causal scope. Nothing in the logs points to the OS or priority reason behind the hosted reordering, and nothing needs fixing.

I read `results.json`, the three control patches and the failure, summary and marker lines in all five logs. I ran nothing.

## What each run shows
Line numbers in the gate-control logs sit one below the frozen R2 file, because each patch deletes one line.

| Run | Patch | Result | What it proves |
|---|---|---|---|
| Baseline | none | 1 + 16 = **17 passed**, 0 failures | The R2 files pass the focused set once, locally. |
| First gate removed | Only arm A deleted (`:3704`) | **10 failures, 0 unexpected**: `isHolding` false; a `removeDNS` reached the helper; failures `[attempt=1]` instead of `[]`; pending set. Stage 2 then fails its bounded 5 s wait, `isHolding`, `reachedOnArmedQueue`, count 2, `[1, 2]` and attempts 2. | Hold A is what keeps the drop's removal and its record behind the write's record. |
| Second gate removed | Only arm B deleted (`:3722`) | **4 failures, 0 unexpected**: `isHolding` false, count 2, `[1, 2]` instead of `[1]`, attempts 2 instead of 1. | Hold B is what keeps the correction's removal and its record behind the drop's record. |
| Supersession guard omitted | `startedAt < generation` changed to `false`, and nothing else | **4 failures, 0 unexpected**: attempts 2 instead of 1, `generation` 2 instead of 3, two `split_dns_failed` events instead of failed plus superseded, last detail `attempt=2` instead of `failed=true newer=1`. | The new model test depends on the production guard for the record order the CI assertions imply. |
| Restored | exact R2 | **17 passed**, 0 failures | The files were restored and pass again. |

The marker grep (`fatal`, `signal`, `leak`, `deadlock`, `Cannot schedule`, `crash`, `precondition`, `hang`, concurrency-pool) matches only the normal summary lines. None of the teardown checks failed, including the cooperative-pool one.

## Scope limits to keep in the record
- **The gate controls don't reproduce the CI reversal.** In both gate controls the *final* no-superseded check and the `[1, 2]` list still passed. So the owner recorded in queue order locally even without the holds. These runs show that the holds set the intermediate history. They don't show that the reordering happens locally, and they say nothing about why hosted CI reordered. That cause stays unproven.
- **Which checks actually discriminate:** with an arm removed, `waitUntilReached` and stage 1's `reachedOnArmedQueue` passed on stale values from the earlier arm, as expected. The real signals are `isHolding`, the physical `removeDNS` count, the failure list and the pending state.
- **The guard control ran only the new unit test.** The existing two-operation reversal tests and the host test weren't run with the guard removed, so the record shouldn't claim results for them.
- **Run times:** the 6–14 s figures include building. Test time was 0.15–5.17 s, and the 5.17 s run includes the bounded 5 s wait that failed.
- **No runtime changes:** all of this is local Swift 6.4, one run per check, and the final source changes no executable lines.

Optional: `results.json` stores only exit codes. Adding the failure-count lines and their line numbers above would make the archive self-contained if the logs stay outside the repo.

The all-41 run and the exact-head hosted checks (standard plus optimized, Swift 6.3.3) are still to come, as you noted.
