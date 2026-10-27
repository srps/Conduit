# Actual runtime client profile probe (preliminary)

This is a resource and latency probe of the **actual** shared host and clients. It is not product code and not a selected
profile.

**Status:** the probe was revised after the independent audit (`real-client-profile-review-part-1-0613.md`). Its measurement
run on the frozen, coherent product source is **`actual-client-profile-vqgH3t`**, and the results below come from that run.
The [recorded metadata](runs/2fe9cd2-vqgH3t/metadata.json) and adjacent numeric NDJSON files preserve that run in the repository.

| Item | Value |
| --- | --- |
| Commit | `2fe9cd2701b6dc74028bbddb72c26e55617bad33`, product sources clean |
| Product-source fingerprint | `7b838f69…5d704`, identical before and after the run |
| Linked objects | unchanged during the run |
| Probe sha256 | `0308ba0eb0c51e4795f0eb317b831c10765b14fd5703998a7fd1837d467a69b2` |
| Runner sha256 | `9af9b2a9…7d7b` |

The parent froze every other build and test during the run. These metrics are bound to checkpoint `2fe9cd2`. They are not
final-release figures. The runs are local single-machine observations: latency is not
a distribution across machines, and none of these numbers is a shipping claim.

`LQFiN4`, the first run on the same product source, is also kept. Its **probe source** differs from vqgH3t's in one place
only: a stale fixed label that said "undercounts" after the correction had landed. Its byte counts match vqgH3t's, but its
timings and memory samples naturally differ from run to run. Every figure below is vqgH3t's. This README was edited after vqgH3t, so its own hash in that run's metadata predates these
edits.

`Probe.swift` links the existing Release objects with `-package-name conduit`. It adds no package product, dependency, test
hook or CLI mode. It drives these actual package facades:

- `StateRootBootstrap.acquire` over an owned scratch root;
- `RuntimeHost.open` with an explicit `RuntimeHostEffects` (the `pm-sim` runtime-host-effects fakes);
- `RuntimeHost.makeInMemoryControlClient`, giving the actual framed `RuntimeClient` and `PrivateEditorClient`;
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
- a product-source fingerprint: the index blob ids, the working-tree diff against HEAD and the untracked source files;
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
| `escape-maximum` | **no** (format-only; 514 start-blocking problems) | held: `failed.effect_failed`, no listener | widest frame, transfer and RAM |
| `padded-8mib` | yes | started | small values in a runtime file whitespace-padded to 8,388,608 B |
| `repeat` | no | held | retention |

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
Durations stay at their defaults, so none becomes invalid. The auditor estimated about 6.3 MB for this shape. Run `vqgH3t`
measured a 6,448,967 B read reply frame and a 6,350,146 B save request frame, and its private Start settled `started`.

**No widest point is a proven absolute bound.** Durations, other numbers, and enum and state combinations were not
exhaustively widened.

## What the probe holds (copy discipline)

Across stages, the probe holds only the fixture value, which stands in for the UI's draft source. Each step's observation and
its mapped draft (the client and UI copies) live in one scoped block. A stage taken inside a block names what it holds in
`probeHeld`, for example `fixture,observation,mapped-draft`. Every other stage is taken after its block ends, with
`probeHeld: fixture`.

The padded file's 8.39 MB `Data` is built at write time and dropped straight after. The codec-size re-encodings run after the
measured stage. Earlier runs held up to nine extra observations and drafts, and the padded `Data`, through every stage.

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
  - **Helper:** the privileged operation is blocked through `PrivilegeClient`.
  - The held helper's Stop timing, `stopOutcomeObservedAfterReleaseMS`, now stops the moment the Stop's outcome is observed.
    The earlier `stopCompletionAfterReleaseMS` also included the Restart's wait and a snapshot read, so it was an upper bound.
- **`cancel`:** a small live A. After each lost wait (main actor held), small reads are retried about every 1 ms. The record
  does not observe the release itself; it bounds it:
  - `lastBusyRefusalMS` is a lower bound (the transfer was still held then), or `-1` when no refusal was observed.
  - `acceptedAttemptStartMS` and `acceptedAttemptEndMS` bracket an upper bound: the accepted attempt reserves the transfer as
    its first step.
  - The earlier "transfer free after 28–38 ms, after one refusal" figure timed a whole valid-maximum read instead, and is
    withdrawn.
- **`contention` (older):** this case no longer claims that the DNS Stop's disable save overlapped a store save. It records
  whether a private exchange was in flight at admission, and `storeOverlapObserved: false`.

## Results of `vqgH3t` (2fe9cd2)

All 28 runs exit 0 with 0 label violations, every release is confirmed and every scratch root is removed. The 28 runs are
20 modes, with 3 trials each of the four live-A contention modes.

**Frames** (actual codecs; re-encodings of the delivered values):

| Fixture | Read reply, B | Save request, B | Runtime file, B |
| --- | ---: | ---: | ---: |
| small / padded-8mib | 3,770 | 3,228 | — / 8,388,608 |
| realistic-valid-64 | 772,415 | 755,514 | — |
| realistic-valid-128 | 929,855 | 912,954 | — |
| **validator-widest** (valid, Started) | **6,448,967** | **6,350,146** | 6,409,936 |
| escape-maximum (format-only) | 7,482,072 | 7,383,251 | — |

`codec-bounds`, unchanged at this commit:

- metadata widened adds +118 B to a reply and +115 B to a request;
- the widest receipt outcome is 715 B, its lookup frame 865 B and its `operationFinished` frame 911 B;
- the widest submit request is 427 B.

Snapshot replies are 1,589 B (small), 3,616 B (realistic), 7,718 B (validator-widest) and 7,570 B (escape).

**validator-widest Start:** 0 validation problems.

- The first read takes 321.4 ms, the save settles in 502.1 ms and the private Start settles `started` in 534.0 ms.
- Proxy Stop is admitted in 0.29 ms and completes in 2.5 ms. The listener closes and the system proxy clears.
- 0 PAC fetches, 0 GSS calls and 7 fake privileged commands.

**Memory.** These are whole-probe process figures.

- *live* is malloc at the stage boundary, with `probeHeld: fixture` unless a stage names more.
- *phase max* is the sampler's lower bound of that phase's transient peak.
- *footprint peak* and *peak RSS* are process-wide maxima.

| Fixture | Host opened, live | Steady after first save, live | Read phase max | Save phase max | Footprint peak | Peak RSS |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| small | — | — | — | — | 7.9 MB | 24.0 MB |
| realistic-valid-128 | — | — | — | — | 26.5 MB | 42.8 MB |
| validator-widest | 6.91 MB | 8.97 MB | 36.3 MB | 38.45 MB | 61.9 MB | 81.4 MB |
| escape-maximum | 7.07 MB | 9.27 MB | 37.1 MB | 39.6 MB | 69.0 MB | 83.9 MB |
| padded-8mib | 3.45 MB | 3.66 MB | — | 13.3 MB | 43.5 MB | 59.6 MB |

- **Copies held during a step:**
  - In escape-maximum, holding one observation and mapped draft adds about 2.1 MB (9.38 MB). Adding the edited draft brings
    it to about 4.1 MB (11.42 MB).
  - Once each step's block ends, live returns to 9.27–9.38 MB at every later stage.
  - The earlier "about +2 MB per stage" therefore came from probe-held copies, as the audit said.
- **Store growth after the first save:** live rises about 2.2 MB after the first save in both wide fixtures. That growth is
  not attributed.
- **Padded file:**
  - Reading the 8 MiB padded file at open peaks at 10.3 MB phase-max malloc, and the save's pre-read at 13.3 MB.
  - Live stays at about 3.7 MB, so neither the store nor the probe keeps the 8 MiB.
  - The `fixture-built` live value is 0.53 MB, because the padded `Data` is no longer held.
- **`repeat`:**
  - Over 6 escape-maximum cycles, live malloc after each cycle goes 9.305 → 9.537 MB, about +46 KB per cycle.
  - Phase max per cycle is 38–42 MB.
  - That growth is consistent with bounded outcome, alias and log retention (64 outcomes, 300 s), but a plateau is not shown.
- **After release:** 3.6–4.0 MB malloc remains in every host mode, including `small`. It was not attributed.

**Live small A while escape-heavy B is saved save-only.** B is about 7.4 MB.

- There were 6 trials with the sampler and 6 without.
- B's `update-exchange` lasted 463–498 ms and its `store-save` 66–102 ms.
- In every trial, the Stop was admitted in its target phase, and the listener closed, the system proxy cleared and B stayed
  unapplied with the host view on A.

| Condition | Stop admission | Stop completion | Status p50 | Status max |
| --- | ---: | ---: | ---: | ---: |
| during B `update-exchange`, sampler on | 0.30–0.35 ms | 2.7–4.4 ms | 0.24–0.38 ms | 0.48 ms, 2.1 ms, **17.2 ms** |
| during B `store-save`, sampler on | 0.31–0.36 ms | 2.7–5.0 ms | 0.26–0.39 ms | 0.73 ms, 1.4 ms, **8.6 ms** |
| during B `update-exchange`, no sampler | 0.28–0.35 ms | 2.6–5.2 ms | 0.25–0.33 ms | ≤ 1.02 ms |
| during B `store-save`, no sampler | 0.32–0.45 ms | 2.6–5.0 ms | 0.24–0.35 ms | ≤ 1.01 ms |

The two outliers (17.2 ms and 8.6 ms) appeared only with the sampler on, once each across 6 trials. That is consistent with
sampler interference but does not prove it. Earlier uncontrolled runs had single maxima of 96 ms and 9.3 ms.

**Idle live Stop** (every fixture whose Start succeeded): admitted in 0.24–0.29 ms; completed in 2.5–4.4 ms, with one 7.3 ms
(realistic-valid-64). Status p50 is 0.24–0.38 ms.

**Format-only (`escape-maximum`, `repeat`):** status and Stop are labelled `proxy-not-running-start-held` with
`proxyRunning: false`. They are not live-Stop evidence.

**`held`** (realistic-valid-128 A), each hold separately labelled:

| Hold | Second exchange | Status p50 | Stop | After release |
| --- | --- | ---: | --- | --- |
| Producer (the caller's mapping closure) | read and update `notSent.transportBusy` | 0.37 ms | proxy, 2.6 ms | update settles in 62 ms |
| Store (runtime-file replacement) | read still served; update `notSent.transportBusy` | 0.34 ms | tunnels, 0.79 ms | save persists in 21 ms |
| Helper (privileged operation) | — | 0.34 ms | admitted in 0.13 ms, `pending` at 200 ms | outcome observed 4.8 ms after release, quantized by polling |

In the helper case the Restart settled `failed.stale_revision`, because the Stop superseded it.

**`cancel`** (small A; bounds only, release not observed):

| Case | Result | Busy refusals | Lower bound | Upper bound (accepted attempt) |
| --- | --- | ---: | --- | --- |
| Read past its deadline | `notSent.deadlineExpired` | 1 | still held at 0.07 ms | 1.7 to 2.4 ms |
| Cancelled read | `notSent.cancelled` | 1 | still held at 0.15 ms | 1.5 to 2.8 ms |
| Update past its deadline | `notSent.deadlineExpired` | 0 | none | 0.001 to 0.97 ms |

The expired update's lookup reported `unknown.not_recorded`, and the next update was admitted and settled.

**`contention` (older):** valid-128 A, with 8 escape reads and saves running.

- Proxy Stop: 0.37 ms admission, 4.6 ms completion.
- Status max while an exchange was in flight: 5.3 ms.
- DNS Stop: 33.6 ms, `completed.stop`. A private exchange was in flight at its admission, and store overlap was not observed.

**Candidate budget at 2fe9cd2:** the bisection gives **6,902,606 B**.

- The initializer charges 5 alias partitions, matching the source, so `aliasPartitionAccountingDiscrepancy` is false.
- The rise from 6,427,356 B at `eea6c8f` is the corrected accounting.

## Earlier results: status of each

**Still meaningful.** Byte counts are deterministic for their source and fixture, and these runs are against `eea6c8f`:

| Fixture | Read reply frame, B | Save request frame, B |
| --- | ---: | ---: |
| small | 3,769 | 3,228 |
| realistic-valid-64 | 772,414 | 755,514 |
| realistic-valid-128 | 929,854 | 912,954 |
| escape-maximum | 7,482,071 | 7,383,251 |

- `codec-bounds`:
  - Metadata widened to `UInt64.max` versions and `Int.max` revisions adds +118 B to a reply and +115 B to a request.
  - The widest safe receipt is 715 B, with an 865 B lookup reply frame and a 911 B `operationFinished` frame.
  - The widest submit request is 427 B, within 64 KiB.
  - None of these is an absolute bound (see the fixtures section).
- **Outcomes:** these were verified in every run.
  - Live Stops closed the listener and cleared the fake system proxy.
  - Held transfers refused before sending.
  - B stayed unapplied beside a live A.
  - Releases were confirmed.
  - The `realistic-valid-128` names in those runs did not yet end in `.invalid`.

**Invalidated or superseded by the audit:**

- `escape-maximum`'s live malloc rising by about 2 MB per stage reflected probe-held observations, not host growth.
- The cancel "transfer free" times.
- The held helper's "2.7 ms after release".
- The DNS-overlap wording.
- Any reading of `valid-maximum` as the widest valid configuration.

Run identities, all kept unchanged under `/private/tmp/conduit-runtime-stage1-20261024/`:

| Run | Probe sha256 | Runner sha256 |
| --- | --- | --- |
| `actual-client-profile-HS2OvZ` | `a29feca5…` | `05210ce6…` |
| `MxQvOR`, `FRvcbU` | `bbaed5b3…` | `7793f06f…` |

Earlier development runs are also kept.

## Candidate profile and the accounting discrepancy

`CandidateProfile` is one explicit **candidate**, not a default or owner decision.

The initializer's acceptance ceiling for it is found by bisection, because the budget member is internal.

- At `eea6c8f` it was 6,427,356 B. That initializer charged **4** alias partitions against **5** in the source, and had no
  operation term for the terminal quit and its reserved flushes. **That figure is superseded and must not be promoted.**
- At the corrected `2fe9cd2` it is **6,902,606 B**, and the initializer charges 5 partitions, matching the source.

It remains a candidate value, not a default. The probe keeps no second byte formula.

Accounted control and private payload terms are conservative encoded-byte reservations:

- the service budget;
- outside it, one private transfer (an 8,388,608 B request frame and an 8,388,608 B reply frame) and one frozen input.

Measured whole-probe process peaks are a different kind of number. Neither bounds whole-application RSS, kernel state,
caches, thread stacks, the NIO event loops or any UI.

## Limitations

- **Internal members.** `RuntimePrivateCustody.held`, `RuntimeServiceLimits.retainedByteBudget` and the collection trackers
  are internal. Custody release is bounded by behaviour, the budget is found by bisection, and tracker cost is not isolated
  (the probe makes no proxied requests).
- **No post-claim lost wait.** A post-claim lost wait (`admissionUnknown`) is not produced, because no package seam holds
  between the claim and the reply.
- **Re-encoded frames.** Frame sizes are re-encodings; the in-memory transport does not expose its bytes.
