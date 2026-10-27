# Shared module owner: executed guard mutations

Seven actual production-source mutations ran on 2026-10-27 against the frozen shared owner. Each failed intended assertions; no compiler error or crash was counted. Baseline and exact restored runs passed 49 focused tests, including the actual-host independent reference model. `results.json` records source hashes, test hashes after restoration, exit codes and assertion counts.

| Removed rule | Actual witness |
| --- | --- |
| Validate every requested revision before changing anything | The stale combined request starts nothing and changes no revision/file. |
| A request stages only its own pending DNS enable | The pure core and real workflow/store keep the unrelated request's file/input false. |
| Retire unfinished authorized members on every abort exit | Whole-host Starts interrupted during PAC or platform work leave no DNS/tunnel grant. |
| Check the companion's prepared pair after suspension | The fake machine records no stale DNS relay or interface apply, even if later cleanup would hide it. |
| Emit the closed busy-store Stop cause | The owed disable remains and its typed capacity event is present. |
| End an owed disable after a matching verified shared write | The current obligation ends while the Stop fence stays. |
| Stop only the addressed module | The independent actual-host model reports DNS fence/state divergence; 52 assertions failed. |

The reference model runs 241 sequential histories (590 transitions) and eight separately gated Start/Stop histories. It models observable module state, DNS durable intent/fence and fake machine effects. It does not explore every physical OS/NIO interleaving, private framing or arbitrary concurrent Starts. Other actual-host witnesses and the independent capture model complement it.

```sh
python3 docs/experiments/runtime-module-guards/replay.py "$PWD"
```

Run with no concurrent source author or test process. The actual run used a temporary driver; this portable copy changes root/output selection and was syntax checked, not separately executed. Each modified file is restored in `finally`, then the restored suite must pass. Later source changes require reviewing these exact mutation sites again. Tests are regression/guard evidence, not release or real-machine acceptance.
