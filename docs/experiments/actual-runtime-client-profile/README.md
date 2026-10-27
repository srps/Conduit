# Actual runtime client profile probe (preliminary)

This is a resource and latency probe of the **actual** shared host and clients. It is not product code and not a selected
profile.

**Status:** the final run on the corrected product is **`actual-client-profile-85GRoD`**. Every current figure below comes
from that one run. It was the only attempt on this source: it compiled and passed on the first try, so nothing was corrected
or rerun. Its [recorded metadata](runs/ebff753-85GRoD/metadata.json) and numeric NDJSON per mode are preserved in
`runs/ebff753-85GRoD/`, copied from the run's original output directory,
`/private/tmp/conduit-runtime-stage1-20261024/actual-client-profile-85GRoD/results/`. The earlier checkpoint's run,
`vqgH3t` on `2fe9cd2`, stays unchanged in [runs/2fe9cd2-vqgH3t](runs/2fe9cd2-vqgH3t/metadata.json); see
[the comparison](#comparison-with-the-2fe9cd2-checkpoint-vqgh3t).

| Item | Value (from 85GRoD's `metadata.json` unless noted) |
| --- | --- |
| Commit | `ebff7532a763f6c8e65c30710281159250fa8c6e`, product sources clean |
| Product source | equivalent to RootA `4be23991da828f2c04a9da7db40246b631505579`: the entire tree is identical (stated by the parent from Git; not computed by the probe) |
| Product-source fingerprint | `532ca15fdfbf064b77c54cb287391d393911d7eb032b1db88688f3273ebedce7`, identical before and after the run |
| Linked objects | unchanged during the run |
| Probe sha256 | `b270f839e57b5e59ca5de67065c65b624d2bd7a797bee4c9f77a6594a5f5b429` |
| Runner sha256 | `ce845fd592a41595975637303d5dfcc8bcc8fd22e0e4bb3e4bef178088df7f73` |
| Compiler | Apple Swift 6.4 (swiftlang-6.4.0.34.1), arm64-apple-macosx26.0 |

The parent froze every other build and test during the run. This README was edited after 85GRoD, so the README hash in
that run's metadata (`55764daa…`) is of the previous text. The probe and runner hashes match the files as frozen.

These numbers are bound to `ebff753`. They are not final-release figures. The runs are local single-machine
observations: latency is not a distribution across machines, and none of these numbers is a shipping claim.

`Probe.swift` links the existing Release objects with `-package-name conduit`. It adds no package product, dependency, test
hook or CLI mode. It drives these actual package facades:

- `StateRootBootstrap.acquire` over an owned scratch root;
- `RuntimeHost.open` with an explicit `RuntimeHostEffects` (the `pm-sim` runtime-host-effects fakes);
- `RuntimeHost.makeInMemoryControlClient`, giving the actual framed `RuntimeClient` and `PrivateEditorClient`;
- `RuntimeClientQuit.quit`, the client quit routine, in `client-quit-widest` (new in this run);
- the actual private and ordinary codecs, the sole store and a live loopback proxy listener.

No Keychain, GSS, helper, VPN, network-path or machine setting is touched. Privileged operations go to `FakeMachine`. The only
socket traffic is the probe's own loopback connect to its proxy listener. Output is numeric NDJSON, and `run.py` fails the
run on any string value that is not a short label.

The actual store decode initializes `GenericDefaults.shared` (`NSUserName()` and the host name, both read-only). Every
fixture value is explicit, and nothing is printed.

**No DNS or network dispatch:**

- Every upstream and tunnel is disabled; PAC routing, the DNS forwarder and transparent proxying are off.
- With no enabled upstream, the direct-mode cause is `noUpstreamsConfigured`, and that cause runs no upstream health loop
  (`DirectModeCause.swift:64-71`, `ProxyOrchestrator.swift:2696`). Neither the health-check URL nor any host is dispatched.
  This comes from reading the source; resolver calls are not instrumented.
- DNS-name fixtures end in the reserved `.invalid` top-level domain.
- The PAC and GSS fakes count calls, and both must stay at zero.

## Reproduce

```sh
bash /private/tmp/conduit-runtime-stage1-20261024/verify-real-client-profile.sh   # builds Release, then:
python3 docs/experiments/actual-runtime-client-profile/run.py OUTPUT --repo "$PWD"
```

Each mode runs in a fresh process with its own scratch root (`OUTPUT/scratch/<mode>`). A mode has a 300 s runner deadline, a
240 s in-process deadline and a 4 MiB output cap.

**Provenance in `metadata.json`.** `run.py` records the following before compiling and again after the last mode:

- HEAD;
- a dirty flag for the product sources;
- a product-source fingerprint: one sha256 over the index blob ids, the working-tree diff against HEAD and the untracked
  files, limited to `Sources/`, `Package.swift` and `Package.resolved`. It is not a fingerprint of the whole tree, the tests,
  the workflows or the build environment;
- the sha256 of the experiment files;
- every linked object's sha256 and mtime.

The runner fails when the sources or objects changed during the run. The objects' tie to a build rests on the wrapper, which
builds immediately before running.

**Release.** Every host mode ends with the same release:

1. Settle (`settleStoppedEffects == .settled`) and confirm the diagnostic flush.
2. Drop the clients and the host, and observe the host's deallocation through a weak reference.
3. Drop the session, and prove the lease closed with a fresh acquisition.
4. Explicitly drop that probe lease, and confirm its release with a second acquisition.
5. Only then read the close-failure count and remove the scratch root.

Anything unconfirmed is pinned until process exit and reported, and the root is kept.

## Fixtures

| Mode | Valid under the current `validate()` | Private Start | Use |
| --- | --- | --- | --- |
| `small` | yes | started; listener live | current shape |
| `realistic-valid-64` | yes | started | a realistic valid wide case with **64 tunnels, decision 0021's primary performance case** |
| `realistic-valid-128` | yes | started | the same realistic case at the **128-tunnel hard ceiling** |
| `validator-widest` | yes, required | started, with all effects fake | the widest point the probe built that the current validator accepts |
| `client-quit-widest` | yes, required (fixture and both drafts) | started | `validator-widest` through the actual client quit routine |
| `escape-maximum` | **no** (format-only; 514 start-blocking problems) | held: `failed.effect_failed`, no listener | widest frame, transfer and RAM |
| `padded-8mib` | yes | started | small values in a runtime file whitespace-padded to 8,388,608 B |
| `repeat` | no | held | retention |

The selected limits and fixture rules are unchanged: 8 MiB private request and reply frames, 64 KiB ordinary replies,
64 tunnels as the primary case and 128 as the hard ceiling. The probe tightens no grammar and adopts no capacity default.

**Realistic** means the probe's own choice of realistic values: 253 B `.invalid` names, 39 B IPv6 addresses, loopback URLs and
two-byte display escapes. The byte ceilings these values sit under, such as 253 B for host text and 1 KiB for display text,
are enforced by the product. The value grammars the probe chose (IPv6 addresses, two-byte display escapes, loopback URLs) are
not the widest the validator accepts. So a realistic fixture is **not** the maximum validator-accepted bound, and the earlier
name `valid-maximum` was wrong.

`validator-widest` keeps every field that `validate()` checks valid:

- `proxy.host` is loopback;
- the bypass list is made of safe tokens on the exact 8,192 B aggregate;
- force-proxy hosts are 253 B; intercept patterns are `*.` plus a 253 B name, with 15 B IPv4 targets;
- the PAC URL has no user info.

Every field `validate()` does not check carries six-byte `\u00XX` escapes at its byte ceiling. Numbers and enums are widened
inside their validated ranges: ports 65535−n, upstream priorities near `Int.max`, and the longest auth mode and preset.
Durations stay at their defaults, so none becomes invalid. In 85GRoD it gave a 6,448,967 B read reply frame and a
6,350,146 B save request frame, and its private Start settled `started`.

**No widest point is a proven absolute bound.** Durations, other numbers, and enum and state combinations were not
exhaustively widened.

## What the probe holds (copy discipline)

Across stages, the probe holds only the fixture value, which stands in for the UI's draft source. Each step's observation and
its mapped draft (the client and UI copies) live in one scoped block. A stage taken inside a block names what it holds in
`probeHeld`, for example `fixture,observation,mapped-draft`. Every other stage is taken after its block ends, with
`probeHeld: fixture`. `client-quit-widest` also holds its prior and final drafts through every stage and says so in each
`probeHeld`.

The padded file's 8.39 MB `Data` is built at write time and dropped straight after. The codec-size re-encodings run after the
measured stage.

## Measurement method and its limits

- **Memory columns:**
  - `mallocInUseBytes` is live malloc at the stage boundary.
  - `phaseMax*` is the 1 ms sampler's maximum since the previous stage. It is a lower bound of the transient peak.
  - `footprintPeakBytes` (`ledger_phys_footprint_peak`) and `peakRSSBytes` (`ru_maxrss`) are process-wide and monotonic.
  - The baseline is the first stage.
  - All of these are whole-probe process figures.
- **Sampler interference:** the sampler calls `malloc_zone_statistics(nil)`, which takes every zone's lock, about every 1 ms.
  That can perturb sub-millisecond latencies. The `contention-encode-nosampler` and `contention-store-nosampler` modes (three
  trials each) rerun the live-A cases without it. Every mode emits `measurement-method` with these settings.
- **Polling granularity:**
  - Operation completion is observed by polling the outcome lookup about every 1 ms (the background worker polls every 2 ms).
  - Live-A status samples are about 2 ms apart; the older `contention` mode's are about 5 ms apart.
  - Every completion time is therefore quantized by about 1–2 ms.
- **One process:** client mapping and encoding run in the same process as the host, so latency during `update-exchange`
  includes in-process CPU competition from the client.

## Latency cases

- **`contention-encode` and `contention-store`:** a live small A runs while the escape-heavy B (about 7.4 MB) is saved
  save-only.
  - B is never applied: the checks require no `applied` field, no module receipts and the host view still on A.
  - One proxy Stop is admitted in B's observed `update-exchange` stage (actual mapping, encoding, transfer and decode, with no
    hold) or in its `store-save` stage.
  - The probe records the Stop's admission and completion, and its physical effect: the listener closed, the fake system
    proxy cleared and the snapshot stopped.
- **`held`:** deterministic holds, each labelled separately from actual encoding.
  - **Producer:** the caller's own request-mapping closure blocks. This is not an encoder stall.
  - **Store:** the runtime file's replacement is blocked through `StateFileAccessing`.
  - **Helper:** the privileged operation is blocked through the `PrivilegeClient` seam, over `FakeMachine`. This is a hold
    on the fake privileged-operation adapter, **not the installed helper**, which the probe never calls.
  - `stopOutcomeObservedAfterReleaseMS` stops the moment the held helper Stop's outcome is observed.
- **`cancel`:** a small live A. After each lost wait (main actor held), small reads are retried about every 1 ms. The record
  does not observe the release itself; it bounds it:
  - `lastBusyRefusalMS` is a lower bound (the transfer was still held then), or `-1` when no refusal was observed.
  - `acceptedAttemptStartMS` and `acceptedAttemptEndMS` bracket an upper bound: the accepted attempt reserves the transfer as
    its first step.
- **`contention` (older):** it records whether a private exchange was in flight at the DNS Stop's admission, and
  `storeOverlapObserved: false`. It does not claim that the DNS Stop's disable save overlapped a store save.

## The actual client quit routine (`client-quit-widest`)

Until this run, every final Quit in the probe was **composed by hand** from the clients' primitives: an ordinary
`submit(.quit(total:flush:))` naming a minted request ID, then a private `submit` under that ID, then outcome polling. That is
not the production routine. Those steps remain in the flow modes and are now labelled
`quitPath: manual-composition-not-RuntimeClientQuit`.

`client-quit-widest` calls the production `RuntimeClientQuit.quit` (ConduitShared) itself, over the same real framed and
private clients. The probe adds no quit coordinator, polling engine or product hook. Its only parts are the caller's own
producer closures and its existing observation of status and files.

1. The `validator-widest` configuration is opened and Started, so the listener and the fake system proxy are live.
2. One read gives the exact runtime, platform and preferences baselines.
3. An earlier wide save-only update **P** (`verbose: true`) is submitted and held in its runtime-file replacement through
   `StateFileAccessing`, so it keeps the one frozen input.
4. `RuntimeClientQuit.quit` starts with `priorUpdate: P`, a 30 s total, and two caller producers:
   - the configuration producer maps a distinct final draft (one upstream priority changed, at the same width) all save-only,
     at the baselines from step 2, rebased only from a settled receipt of P;
   - the preferences producer maps a final preferences draft at its exact baseline.
   Each producer records when it ran and the prior step it was handed. That is the caller's closure, not a routine hook.
5. While P is held, the probe samples status, reads one observation (its `terminal` flag shows the Quit's fence), checks the
   listener, and confirms no producer has run.
6. P is released. The routine's result, the files on disk, the listener, the fake system proxy and the host's runtime state
   are then checked, followed by the standard release proofs.

## Results of `85GRoD` (ebff753)

All 29 runs exit 0 with 0 label violations, and in every one the release is confirmed and the scratch root is removed. The
29 runs are 21 modes, with 3 trials each of the four live-A contention modes. No check failed and no mode was inconclusive.

**Frames** (actual codecs; re-encodings of the delivered values):

| Fixture | Read reply, B | Save request, B | Runtime file, B |
| --- | ---: | ---: | ---: |
| small / padded-8mib | 3,770 | 3,228 | — / 8,388,608 |
| realistic-valid-64 | 772,415 | 755,514 | — |
| realistic-valid-128 | 929,855 | 912,954 | — |
| **validator-widest** (valid, Started) | **6,448,967** | **6,350,146** | 6,409,936 |
| client-quit-widest final save | — | 6,350,147 | — |
| escape-maximum (format-only) | 7,482,072 | 7,383,251 | 7,443,041 |

The client-quit final save frame is re-encoded at the pre-quit baselines with a 60 s budget. Its one extra byte is
`verbose: false` against the flow's `true`. The frame the routine actually sent carries the rebased baselines and the
routine's remaining budget, so it can differ by a few bytes.

`codec-bounds`:

- metadata widened adds +118 B to a reply and +115 B to a request;
- the widest receipt outcome is 715 B, its lookup frame 865 B and its `operationFinished` frame 911 B;
- the widest submit request is 427 B.

Snapshot replies are 1,589 B (small and padded), 3,616 B (realistic-64), 3,617 B (realistic-128), 7,718 B (validator-widest)
and 7,570 B (escape).

**validator-widest Start:** 0 validation problems.

- The first read takes 343.0 ms, the save settles in 550.4 ms and the private Start settles `started` in 600.5 ms.
- Proxy Stop is admitted in 0.32 ms and completes in 13.7 ms (8 lookups). The listener closes and the system proxy clears.
- The hand-composed Quit completes in 551.1 ms, and its final save in 546.3 ms.
- 0 PAC fetches, 0 GSS calls and 7 fake privileged commands.

**Client quit routine (`client-quit-widest`):** every check passed. A write label `persisted.false` is the probe's spelling
of `.persisted(reportedError: false)`: the file was written and no error was reported. It does not mean "not persisted".

| Item | Result |
| --- | --- |
| Quit step | `settled.completed.quit`; no observation failure |
| Return path | settled while the stream was live (by the routine's first lookup or by the stream; the probe cannot tell which); the keep-caller-to-deadline branch was not taken. `returnedBeforeFinalReadReserve` is inferred from timing only (`routineMS` < total − 200 ms) |
| Prior update P | admission `accepted`; `settled.configurationSettled`; runtime `persisted.false`, platform `unchanged` |
| Final configuration save | `settled.configurationSettled`; runtime `persisted.false`, platform `unchanged`; `applied` absent, 0 module receipts (save-only); lookup reply frame 655 B |
| Final preferences save | `settled.preferencesSettled`; `persisted.false` |
| Producers | each called once, configuration then preferences, both after P's release; both handed `settled.configurationSettled` |
| Rebase | the configuration producer rebased its runtime and platform baselines from P's receipt |
| While P was held | Quit fenced (`terminal: true` in a read served during the hold); 0 producer calls; proxy not running and listener already closed; status p50 0.42 ms, p90 0.45 ms, max 0.70 ms (20 samples); the probe's read took 325.6 ms |
| Files on disk | the runtime file equals the final draft; preferences equal the final preferences draft |
| Physical cleanup | listener closed, fake system proxy cleared, host runtime state proxy down; 0 PAC, 0 GSS, 7 fake privileged commands |
| Release | settled, flush confirmed, host deallocated, lease closed, scratch removed |

Routine timing:

- Started to return: 1,009.9 ms (`routineMS`).
- P was held for the first 387.5 ms of that. This is `routineMS − releaseToReturnMS`, the hold up to the release. The
  emitted `heldForMS`, 387.3 ms, is taken slightly earlier, when the hold record is written just before the release.
- From P's release, the configuration producer ran at 11.2 ms and the preferences producer at 566.0 ms (so the wide final
  configuration save took about 555 ms). The routine returned at 622.3 ms.

The 622.3 ms after release is not directly comparable with the hand-composed 551.1 ms. It includes P's remaining store work,
the custody hand-off and the preferences save, which the flow's Quit does not have.

Routine memory, whole-probe malloc:

| Stage | Live | Phase max |
| --- | ---: | ---: |
| running validator-widest (before the quit) | 9.01 MB | 39.58 MB |
| P held (`probeHeld: …,observation-until-prior-admitted`; the prior task may still hold its observation) | 27.20 MB | 40.11 MB |
| routine waiting on held P | 27.31 MB | 54.67 MB |
| routine returned (release to return) | 10.92 MB | 40.66 MB |
| files verified | 10.92 MB | 27.55 MB |
| after release | 3.75 MB | 10.92 MB |

- The footprint peak is 76.1 MB and the peak RSS 89.1 MB.
- The 54.67 MB waiting-phase maximum includes the probe's own 6.4 MB read during the hold, beside P's held input.
- The 27.2 MB live while P is held is not attributed. It may include P's frozen input and staged file, the observation the
  prior task may still hold (P's admission probably returned before the store gate held, which would release it), and the
  probe's three drafts. The probe does not separate these.
- The verified phase includes the probe's own load of the 6.4 MB runtime file and the re-encoding.

**Largest whole-probe peaks in the run.** These are not the routine mode's figures, so 76.1 / 89.1 MB is not the run's
maximum.

- The largest footprint peak (96.5 MB) and peak RSS (109.9 MB) are the older `contention` mode's. That mode runs 8 escape
  reads and saves beside a running valid-128 A. Its sampled phase maximum of malloc is 45.41 MB.
- The largest sampled phase maximum of malloc in any mode is `client-quit-widest`'s 54.67 MB, in its waiting phase. That
  figure includes the probe's own read during the hold.

All of these are sampled lower bounds of transient peaks, and none bounds application memory.

**Memory, flow fixtures.** These are whole-probe process figures.

- *live* is malloc at the stage boundary, with `probeHeld: fixture` unless a stage names more.
- *phase max* is the sampler's lower bound of that phase's transient peak.
- *footprint peak* and *peak RSS* are process-wide maxima.

| Fixture | Host opened, live | Steady after first save, live | Read phase max | Save phase max | Footprint peak | Peak RSS |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| small | — | — | — | — | 8.0 MB | 24.3 MB |
| realistic-valid-64 | — | — | — | — | 27.5 MB | 44.0 MB |
| realistic-valid-128 | — | — | — | — | 27.8 MB | 44.2 MB |
| validator-widest | 6.90 MB | 8.98 MB | 36.28 MB | 38.46 MB | 65.8 MB | 80.2 MB |
| escape-maximum | 7.08 MB | 9.28 MB | 37.09 MB | 41.00 MB | 69.9 MB | 83.1 MB |
| padded-8mib | 3.45 MB | 3.67 MB | — | 13.28 MB | 43.6 MB | 59.9 MB |

- **Copies held during a step (escape-maximum):** holding one observation and mapped draft gives 9.38 MB live, against
  7.16 MB after composition. Adding the edited draft gives 11.44 MB. After each step's block ends, live is 9.28–9.39 MB at
  every later stage.
- **First-save growth:** live rises about 2.0 MB (validator-widest, 6.98 → 8.98 MB) and 2.1 MB (escape-maximum, 7.16 →
  9.28 MB) between composition and the first save's release. That growth is not attributed.
- **Padded file:**
  - Reading the 8 MiB padded file at open peaks at 10.29 MB phase-max malloc, and the save's pre-read at 13.28 MB.
  - Live stays at about 3.7 MB, so neither the store nor the probe keeps the 8 MiB.
  - The `fixture-built` live value is 0.53 MB.
- **`repeat`, retention plateau not shown:**
  - Over 6 escape-maximum cycles, live malloc after each cycle goes 9.301 → 9.530 MB, about +46 KB per cycle.
  - Phase max per cycle is 36.7–38.4 MB.
  - That growth is consistent with bounded outcome, alias and log retention (64 outcomes, 300 s), but six cycles do not
    reach a plateau, so the probe shows neither a bound nor a leak.
- **Post-release residue:** 3.39–4.18 MB of malloc remains after release in every host mode (3.39 MB lifetime-open, 3.67 MB
  small, 4.18 MB older contention). It was not attributed, and the probe infers neither a leak nor its absence from it.

**Live small A while escape-heavy B is saved save-only.** B is about 7.4 MB.

- There were 6 trials with the sampler and 6 without.
- B's `update-exchange` lasted 466–624 ms and its `store-save` 72–155 ms, from the observed phase boundaries.
- In every trial, the Stop was admitted in its target phase, and the listener closed, the system proxy cleared and B stayed
  unapplied with the host view on A.

Status p50 and max are over the samples taken during B's `update-exchange` and `store-save`. The maxima are listed per trial.

| Condition | Stop admission | Stop completion | Status p50 | Status max per trial |
| --- | ---: | ---: | ---: | ---: |
| during B `update-exchange`, sampler on | 0.32–0.40 ms | 2.7–13.2 ms | 0.28–0.56 ms | **5.37 ms**, 0.64 ms, 1.43 ms |
| during B `store-save`, sampler on | 0.34–0.61 ms | 5.9–19.7 ms | 0.31–0.48 ms | 1.02 ms, 0.58 ms, 1.83 ms |
| during B `update-exchange`, no sampler | 0.32–0.36 ms | 5.1–12.7 ms | 0.27–0.34 ms | 0.81 ms, 0.76 ms, **2.72 ms** |
| during B `store-save`, no sampler | 0.31–0.34 ms | 3.1–19.3 ms | 0.28–0.35 ms | 0.74 ms, 0.55 ms, 0.50 ms |

Stop completions of 12–20 ms appeared both with and without the sampler. This run does not separate their cause.

**Idle live Stop** (small, realistic-64, realistic-128, validator-widest, padded): admitted in 0.28–0.35 ms; completed in
2.5–4.9 ms, with one 13.7 ms (validator-widest). Status p50 is 0.27–0.49 ms.

**Format-only (`escape-maximum`, `repeat`):** status and Stop are labelled `proxy-not-running-start-held` with
`proxyRunning: false`. They are not live-Stop evidence.

**`held`** (realistic-valid-128 A), each hold separately labelled:

| Hold | Second exchange | Status p50 | Stop | After release |
| --- | --- | ---: | --- | --- |
| Producer (the caller's mapping closure) | read and update `notSent.transportBusy` | 0.38 ms | proxy, 21.3 ms (12 lookups) | update settles in 60.5 ms |
| Store (runtime-file replacement) | read still served; update `notSent.transportBusy` | 0.35 ms | tunnels, 0.86 ms | save persists in 5.5 ms |
| Fake privileged operation (`PrivilegeClient` over `FakeMachine`) | — | 0.36 ms | admitted in 0.18 ms, `pending` at 200 ms | outcome observed 4.0 ms after release, quantized by polling |

In the privileged-operation case the Restart settled `failed.stale_revision`, because the Stop superseded it.

**`cancel`** (small A; bounds only, release not observed). No busy refusal was observed in any case this run, so no case
has a lower bound:

| Case | Result | Busy refusals | Lower bound | Upper bound (accepted attempt) |
| --- | --- | ---: | --- | --- |
| Read past its deadline | `notSent.deadlineExpired` | 0 | none | 0.001 to 0.78 ms |
| Cancelled read | `notSent.cancelled` | 0 | none | 0.002 to 1.09 ms |
| Update past its deadline | `notSent.deadlineExpired` | 0 | none | 0.001 to 1.18 ms |

The expired update's lookup reported `unknown.not_recorded`, and the next update was admitted and settled. The proxy Stop
after the cases took 0.78 ms to admit and 11.8 ms to complete.

**`contention` (older):** valid-128 A, with 8 escape reads and saves running and no worker error.

- Proxy Stop: 0.36 ms admission, 4.3 ms completion. Tunnels Stop: 0.16 ms, 0.79 ms.
- Status while an exchange was in flight: p50 0.52 ms, max 18.8 ms.
- DNS Stop: 34.9 ms, `completed.stop`. A private exchange was in flight at its admission; store overlap was not observed.

**Lifetime modes:** `lifetime-open` through `lifetime-start` each confirm the host's deallocation and the lease's release at
their depth.

## Constructor budget (bisection) and what it does not bound

`CandidateProfile` is one explicit **experimental** profile. Its values are not shipping values, defaults or owner
decisions. That includes 64 KiB ordinary request and reply frames, a 32 KiB latest snapshot, a 16 KiB alias byte capacity per
partition, 64 outcomes in 64 KiB, a 256 KiB ring, 512 collection rows and 300 s retention. The profile is not selected.

The initializer's acceptance ceiling for these values is found by bisection, because the budget member is internal. In
85GRoD it is **6,902,606 B**. The initializer charges 5 alias partitions and the source lists 5, so
`aliasPartitionAccountingDiscrepancy` is false. The figure is unchanged from `2fe9cd2`. The superseded `eea6c8f` figure
(6,427,356 B, 4 partitions charged, no terminal-quit operation term) must not be promoted. The probe keeps no second byte
formula.

That figure and the private payload terms are conservative **encoded-byte reservations**:

- the service budget;
- outside it, one private transfer (an 8,388,608 B request frame and an 8,388,608 B reply frame) and one frozen input.

The measured whole-probe malloc, footprint and RSS figures are a different kind of number. **Neither the encoded
reservations nor the sampled whole-probe figures bound application memory.** Neither covers whole-application RSS, kernel
state, caches, thread stacks, the NIO event loops or any UI. The decoded values and in-flight copies behind the 27 MB and
40–55 MB phase figures above sit outside the encoded reservations, for example.

## Comparison with the 2fe9cd2 checkpoint (vqgH3t)

`vqgH3t` was run on `2fe9cd2` with probe `0308ba0e…` and runner `9af9b2a9…`. Its numbers below are quoted from its
recorded run and were not re-measured. 85GRoD's are from the current run.

| Item | vqgH3t (2fe9cd2) | 85GRoD (ebff753) |
| --- | --- | --- |
| Runs, modes | 28 runs, 20 modes | 29 runs, 21 modes (adds `client-quit-widest`) |
| Final Quit coverage | hand-composed only | hand-composed in flows, plus the actual `RuntimeClientQuit.quit` |
| Frames (every fixture) | as in the frames table | byte-identical |
| `codec-bounds` | +118 / +115; 715 / 865 / 911; 427 | identical |
| Constructor budget | 6,902,606 B | 6,902,606 B |
| validator-widest first read / save / Start | 321.4 / 502.1 / 534.0 ms | 343.0 / 550.4 / 600.5 ms |
| validator-widest idle Stop completion | 2.5 ms | 13.7 ms |
| validator-widest live opened / steady | 6.91 / 8.97 MB | 6.90 / 8.98 MB |
| validator-widest footprint peak / peak RSS | 61.9 / 81.4 MB | 65.8 / 80.2 MB |
| escape-maximum save phase max | 39.6 MB | 41.00 MB |
| Live-A Stop completion, all 12 trials | 2.6–5.2 ms | 2.7–19.7 ms |
| Live-A status max, no sampler | ≤ 1.02 ms | ≤ 2.72 ms |
| Held producer Stop | 2.6 ms | 21.3 ms |
| Post-release residue | 3.6–4.0 MB | 3.39–4.18 MB |
| `repeat` growth per cycle | about +46 KB | about +46 KB |

Byte counts are deterministic for their source and fixture, and they match. Timings and samples differ run to run. One run
per source does not show whether the slower Stop completions on `ebff753` are a product change or run-to-run variation.

## Earlier results: status of each

Run identities, all kept unchanged under `/private/tmp/conduit-runtime-stage1-20261024/`:

| Run | Source | Probe sha256 | Runner sha256 |
| --- | --- | --- | --- |
| `actual-client-profile-85GRoD` (final, this README; also in `runs/ebff753-85GRoD`) | `ebff753` | `b270f839…` | `ce845fd5…` |
| `vqgH3t` (also in `runs/2fe9cd2-vqgH3t`) | `2fe9cd2` | `0308ba0e…` | `9af9b2a9…` |
| `LQFiN4` | `2fe9cd2` | differs from vqgH3t's in one stale label | not restated here; see its metadata |
| `actual-client-profile-HS2OvZ` | earlier; see its metadata | `a29feca5…` | `05210ce6…` |
| `MxQvOR`, `FRvcbU` | earlier; see their metadata | `bbaed5b3…` | `7793f06f…` |

Earlier development runs are also kept.

**Invalidated or superseded by the audit** (still not to be reused):

- `escape-maximum`'s live malloc rising by about 2 MB per stage reflected probe-held observations, not host growth.
- The cancel "transfer free after 28–38 ms" times, which timed a whole read.
- The held helper's "2.7 ms after release", and the earlier `stopCompletionAfterReleaseMS` upper bound.
- The DNS-overlap wording.
- Any reading of `valid-maximum` as the widest valid configuration.

## Limitations

- **The client quit routine was exercised once, along one path.** P was held mid-replacement, so its write had started,
  persisted, and handed a receipt the final save rebased from. These branches were not exercised here:
  - the latch revoking a write that had not started (covered by the product test
    `testTheClientQuitFencesFirstThenFlushesOnceTheEarlierUpdateReleasesItsInput`);
  - an unavailable or ended stream, and with it the keep-caller-to-deadline path;
  - a total-deadline expiry;
  - an unsettled prior and the one post-release lookup.
  This run has no no-sampler trial of the routine. On an error path the mode does not cancel its two detached tasks (the
  routine's 30 s total and P's 60 s deadline bound them, and an unreleased host is pinned and reported); that path was not
  exercised.
- **Routine internals.** The routine's settlement waiter and subscription are private. Their lifetime is shown only
  indirectly: the host deallocated and the lease closed after the routine returned.
- **Internal members.** `RuntimePrivateCustody.held`, `RuntimeServiceLimits.retainedByteBudget` and the collection trackers
  are internal. Custody release is bounded by behaviour, the budget is found by bisection, and the cost of collection
  tracking is not isolated, because the probe makes no proxied requests.
- **Unattributed memory.** First-save growth (about 2 MB), the `repeat` growth (no plateau shown), the 27 MB live while P was
  held and the 3.4–4.2 MB post-release residue are all unattributed. None is evidence of a leak or of its absence.
- **No post-claim lost wait.** A post-claim lost wait (`admissionUnknown`) is not produced, because no package seam holds
  between the claim and the reply.
- **Re-encoded frames.** Frame sizes are re-encodings; the in-memory transport does not expose its bytes.
- **No real helper.** Every privileged hold is on the fake `PrivilegeClient` seam over `FakeMachine`.
- **Single machine, single run per source.** No figure is a distribution, an absolute widest bound or a shipping limit.
