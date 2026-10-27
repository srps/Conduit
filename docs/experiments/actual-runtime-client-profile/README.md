# Actual runtime client profile probe

A resource and latency probe of the **actual** shared host and native clients, at one measured control-service profile. It is not
product code and does not select a profile. Every figure below comes from ONE run, **`actual-client-profile-OdAmdZ`** on
`ef3e4df`. The figures are local observations on one machine: no latency here is a distribution and nothing is a shipping claim.

## Status

**Passing current run.** All 31 runs (23 modes, with 3 trials each of the four live-A contention modes) exited 0: 481 checks
passed, none failed, nothing was inconclusive or pinned, and every scratch root was removed. Nothing was rerun to get a better
figure, and the product was not edited.

| Item | Value (from `OdAmdZ`'s `metadata.json`) |
| --- | --- |
| Commit | `ef3e4dfcdc712e29b46a78953a01ab00caa4b852`, the same before and after; product sources clean, no untracked product files |
| Product-source fingerprint (`run.py`'s) | `c1459dc85d59530ec91142450b60fa81cb016ab910385b900ba626c39580147f`, unchanged during the run |
| Linked objects | unchanged during the run |
| Probe / runner sha256 | `abba219fb60314ffeb0e948f0becbee52bc99ee81e17dfa36be9622040048601` / `1d5488ac4b22bcfd3c5b1f85b10d2f82183605220b179b30e41e0b3593f7caeb` |
| Compiler | Apple Swift 6.4 (swiftlang-6.4.0.34.1), arm64-apple-macosx26.0 |

The parent reports that the all-41 workflow on this source passed 41/41 and had exited before the run, and that no other build
or test process ran during it. The README hash in the metadata is of the text before this rewrite.

**History.** All earlier runs are archived unchanged under [runs/](runs/):

- **On `011f589`:**
  - [`rSKjxl`](runs/011f589-rSKjxl/README.md) is excluded. The parent's early GO let its build overlap the all-41 workflow, and it was
    stopped with no results.
  - [`bwveLh`](runs/011f589-bwveLh/README.md) failed 1 of 31. In `lifetime-save` the flush was not confirmed, because the snapshot
    sink was refused with `inspection_failed resource=platform_state`. That was a race in `SystemRecordFileDestinationGuard` while
    `platform-state.json` was being created for the first time. The guard's bounded re-resolution in `ef3e4df` fixes it.
- **Before event integration:** `3ed13fa-8p7pkC` (with its failed compile `3ed13fa-DNVAPS`), `ebff753-85GRoD` and `2fe9cd2-vqgH3t`.
  Those runs saw no runtime events and no stream end at quit, and they used older candidate profiles, so their figures are not
  compared here.

The probe changed only its labels after `bwveLh` (see [the profile](#the-profile)). The [labels-only patch](runs/011f589-bwveLh/probe-labels.patch)
reconstructs its probe from the current frozen `Probe.swift`; metadata records both hashes.

## What it drives

`Probe.swift` links the existing Release objects with `-package-name conduit`. It adds no package product, dependency, test hook
or access widening, and drives the actual:

- `StateRootBootstrap.acquire` over an owned scratch root;
- `RuntimeHost.open` with explicit `RuntimeHostEffects`, using the `pm-sim` fakes and a `FakeSystemWakeObserver` the probe never
  fires;
- the framed `RuntimeClient` and `PrivateEditorClient` from `RuntimeHost.makeInMemoryControlClient`;
- the saved-value Start, `refreshPreflight`, `credentialsChanged`, `setLaunchAtLogin`, `readPage` and subscriptions;
- `RuntimeClientQuit.quit` (in `client-quit-widest`);
- the private and ordinary codecs, the Bridge projections, `ControlPagePacker`, the store and a live loopback listener.

No Keychain, GSS, helper, VPN, network path or machine setting is touched. Privileged operations go to `FakeMachine`, and the
helper status is `FakeHelperLifecycle` behind a probe gate. The only socket traffic is the probe's loopback connect to its own
proxy listener. Every upstream and tunnel is disabled, PAC routing, DNS forwarding and transparent proxying are off, and every
DNS name ends in `.invalid`. The PAC and GSS fakes stayed at zero calls in every mode. The store decode initializes
`GenericDefaults.shared` (`NSUserName()` and the host name, both read-only); every fixture value is explicit. The probe prints
numeric NDJSON only, and `run.py` fails a run on any string that is not a short label.

Every host mode ends by settling, confirming the diagnostic flush, dropping the clients and the host and observing its
deallocation, and checking that the wake observer started and stopped once. It then proves the state lease closed with a fresh
acquisition, and only then removes the scratch root. All 29 host runs confirmed every step (`codec-bounds` and `profile-sizing`
open no host).

## Reproduce

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcrun swift build -c release
python3 docs/experiments/actual-runtime-client-profile/run.py OUTPUT --repo "$PWD"
```

Each mode runs in a fresh process with its own scratch root, under a 300 s runner deadline, a 240 s in-process deadline and a
4 MiB output cap. `run.py` records, before compiling and after the last mode:

- HEAD, a product-dirty flag and a product-source fingerprint (index blob ids, working-tree diff and untracked files under
  `Sources/`, `Package.swift` and `Package.resolved`);
- the experiment files' sha256;
- every linked object's sha256 and mtime.

It fails the run if any of them changed. The tie between the objects and a build rests on the wrapper, which builds immediately
before running.

## The profile

The profile label is `CANDIDATE-4K-64K-10K-4M`. Every mode builds it through the actual `RuntimeServiceLimits` initializer.

| Term | Value | Status |
| --- | --- | --- |
| Ordinary request frame | 4,096 B | reviewed engineering value |
| Ordinary reply/stream frame; private request / reply frame | 65,536 B; 8 MiB / 8 MiB | selected frame caps |
| Collection rows; capture; retained | 10,000; 4,194,304 B; 8,388,608 B. The count and byte caps are independent, and a list over budget is unavailable whole | **selected, decision 0038** |
| Lanes (ordinary, read, stream); Stop lane; subscribers; ordinary pending | 4 each; 1 per module; 4; 8 | reviewed engineering values |
| Aliases per partition; outcomes; control log; retention | 64 (8,960 B); 64 (615,424 B); 64 (619,584 B); 300 s | reviewed. Bytes are 64 × the widest measured record (outcome 9,616 B, log entry 9,681 B, both `test-upstream`) |
| Ring and ingress; drain per turn; per event | 256 events / 262,144 B each; 32 items / 65,536 B; 8,192 B | reviewed. The widest observed event is 285 B (no catalogue sweep) |
| Latest snapshot; subscriber record | 65,233 B (the initializer's largest beside a 64 KiB reply); 1,024 B | derived; stated |
| Collection revisions; proofs; row retention | 2 per kind; 4 per kind; 60 s | reviewed engineering values |
| Retained-byte budget | 17,082,600 B, the initializer's own budget for these terms, found by bisection | derived |
| Quit total in `client-quit-widest` | 30 s | **experimental caller budget only.** The Quit total is the owner's choice (proposed decision 0039) and is not selected here |

**Encoded reservations are not process memory.** The 17,082,600 B budget and the private custody terms (one transfer and one
admitted input) are encoded-byte ceilings checked by the initializer, not preallocations or application-memory bounds. Actual
payload retention allocates as used. This accounting excludes decoded values, encoder scratch, thread stacks, NIO and other object
overhead. The memory figures below sample the whole probe, including its frozen fixtures and whatever runtime allocations are live;
they do not attribute those costs or bound an app with its UI.

## Frames and records

- **Ordinary requests.** `codec-bounds` frames all 25 ordinary calls at their widest legal forms; the switches are exhaustive, so a new
  kind fails to compile until it is measured. The widest is 427 B (`setLaunchAtLogin(false, …)`, and Quit with both final saves).
  Reload is 280 B. Every call frames within 4,096 B. These are the widest forms the probe built, not proven maxima.
- **Outcomes.** Every settled kind at its widest fits the outcome, log and 64 KiB reply caps:

  | Kind | Outcome, B | Lookup reply frame, B | `operationFinished` frame, B |
  | --- | ---: | ---: | ---: |
  | `test-upstream` (the widest) | 9,616 | 9,766 | 9,812 |
  | Preflight (widest reading, and the busy read) | 842 | 992 | 1,038 |
  | Saved-Start receipt with priors and the DNS companion | 887 | 1,037 | 1,083 |
  | Reload (widest answer) | 211 | 361 | 407 |

  The other small control replies and stream frames measured here are 138–241 B: admission, lookups, failure, page unavailable, stream end and caught up.
- **Reload answers.** All 16 framed as lookup replies at the reply cap and decoded back equal: 10 refusals, superseded, both
  `currentAtEnd` values, and the 3 held pairs that `isValidHeld(phase: .reload, …)` admits. The other 30 held pairs were refused,
  counted rather than built.
- **Preflight items.** 7 busy-read and 7 conclusive pairs were accepted. 2 were refused with `invalidValue`, the only error caught.
- **Snapshot.** The widest snapshot the probe built (14 notices, texts past their caps, counters at `Int.max`) has a 49,090 B payload
  and a 49,214 B reply frame. The baseline at the widest cursor is 49,393 B. That leaves 16,143 B under the 65,233 B capacity, and
  one byte more than the capacity is refused by the initializer. It is not a proven maximum.
- **Private frames.** Read reply / save request, in bytes:

  | Fixture | Read reply | Save request |
  | --- | ---: | ---: |
  | small (and padded-8mib) | 3,770 | 3,228 |
  | realistic-valid-64 | 772,415 | 755,514 |
  | realistic-valid-128 | 929,855 | 912,954 |
  | validator-widest | 6,448,967 | 6,350,146 |
  | escape-maximum | 7,482,072 | 7,383,251 |

  Widest metadata adds 118 B to a small read and 115 B to a small save.
- **Collections.** Fit was decided by the actual projection under `ControlRowBudget`, by bisection, never by dividing sizes. One
  connection row is 12,796 B widest, 6,096 B mixed-escape, 790 B realistic-wide and 258 B typical. Within 4 MiB:
  - connections: 327, 688, 5,309 and 10,000 rows respectively;
  - tunnel DNS hosts: 1,320, 3,728, 10,000 and 10,000;
  - upstream health (32) and tunnel bindings (128): every shape, at their configuration ceilings;
  - 10,001 typical rows: refused whole by the projection.

  1,024 connection rows paged at the 64 KiB reply cap took 205, 103, 13 and 5 pages, each page frame within the cap. Reserving the
  same row reach instead (10,000 × the widest row) would make the budget 388.4 MB rather than 17.1 MB.

## Events, shutdown and pressure (`pressure-candidate`)

The fixture is the validator-widest configuration (valid, 128 tunnels), driven through the actual framed clients. Every hold is on
a fake seam, and the probe injects no event.

1. **Saved Start.** Admitted in 6.0 ms and settled in 126.4 ms as `configurationSettled`, with the proxy `started` and both priors
   present. The listener and the fake system proxy came up.
2. **Four subscribers** opened with a baseline each. A fifth was refused `subscriberLimit`. All four collections were then read once
   through `readPage` on the real host, and each answered a page (0 rows) without a client error.
3. **Holds.**
   - A wide save-only update P was held in its runtime-file replacement.
   - A preflight pass was held in its helper read.
   - 7 more preflights were admitted, and the next was refused `queue_full`, as was `credentialsChanged`. This is consistent with P
     occupying the eighth pending slot; the probe does not prove it.
4. **Under every hold:**
   - status took p50 0.42 ms and max 0.51 ms over 20 samples;
   - a 6.4 MB private read was served in 331.5 ms;
   - a second private update was refused `transportBusy`.
5. **Lane window.** With the main thread asleep for 100 ms:
   - reads: 4 were served and 4 refused `transportBusy`;
   - ordinary commands: 4 were refused `transportBusy` and 4 `queue_full`;
   - a tunnels Stop sent in the same window was `accepted`.
6. **Proxy Stop with every hold standing.** Admitted in 1.45 ms and completed in 5.3 ms. The listener closed, the fake system proxy
   cleared and the snapshot stopped, while both holds were still in place.
7. **Release.**
   - All 7 preflights settled within 4.6 ms of the helper's release.
   - P persisted 15.3 ms after the store's release.
   - A fresh `credentialsChanged` settled in 0.68 ms.
   - A busy helper read completed `observed`, with `installed` shown and `helperReadBusy: true` (813 B).
   - The login-item save persisted. The host ignores the flag, so no login item is created.
8. **Hand-composed Quit, then the stream ends.**
   - **Frames.** Each subscriber received 1 baseline (7,822 B), 3 snapshots (≤ 7,716 B), 14 `operationFinished` frames (≤ 859 B)
     and 5 event frames (≤ 1,332 B).
   - **Events.** Those frames carried 13 events: 3 typed configuration-workflow and 10 untyped known; none carried the typed
     lifecycle family. The widest event record was 285 B, against the 8,192 B cap. There were 0 encode failures and 0 busy retries,
     and no resync or slow-consumer end.
   - **Stream end.** All four ended with `streamClosed(hostShutdown)` before the probe asked any of them to stop. They had already
     ended when the probe began its post-Quit wait.

**Memory.** Live malloc was 27.5 MB with everything held, and the phase maximum reached 54.8 MB after the held read and update
attempt. It fell to 9.9 MB on release and 4.0 MB after release. Footprint peaked at 77.7 MB and RSS at 94.6 MB.

## Client Quit routine (`client-quit-widest`)

This runs `RuntimeClientQuit.quit` itself over the framed and private clients, with the **experimental 30 s total**. An earlier
wide save-only update P was held in its runtime-file replacement. Every check passed.

- **While P was held (395.5 ms):**
  - the Quit had fenced (`terminal` latched), and no producer had run;
  - the proxy was down and the listener closed;
  - status took p50 0.43 ms and max 0.58 ms;
  - a read was served in 333.1 ms.
- **Results:**
  - Quit `completed.quit`, and P `configurationSettled`.
  - The final configuration save was save-only and persisted, and the final preferences save persisted.
  - Each producer ran once after P's release, configuration first. Each was handed P's settlement, and the configuration producer
    rebased both baselines from it.
  - The files on disk equal the final drafts, and the fake system proxy cleared.
- **Timing:**
  - the routine took 1,066.6 ms in total, 670.9 ms of it after P's release;
  - the configuration producer ran 20.6 ms after the release;
  - the preferences producer ran 647.5 ms after the release, once the 6,350,147 B final configuration save had settled.
- **Memory:** live malloc was 27.3 MB while P was held, with a 54.7 MB phase maximum. Footprint peaked at 76.0 MB and RSS at
  92.7 MB.

This used fake effects. The real Quit total needs real-helper and real-machine validation, which this probe neither performs nor
is authorized to perform.

## Flows and latency

- **validator-widest:**
  - first private read 364.9 ms;
  - save settled in 529.7 ms;
  - private Start settled in 533.6 ms;
  - idle proxy Stop admitted in 0.30 ms and completed in 2.6 ms;
  - hand-composed Quit 519.5 ms, its final save 515.0 ms.

  Idle Stops in the other flows were admitted in 0.28–0.43 ms and completed in 2.5–4.7 ms, with status p50 at 0.25–0.48 ms.
- **Live small A while an escape-heavy B (about 7.4 MB) is saved save-only.** 3 trials each, with and without the sampler. In every
  trial the Stop was admitted in its target phase, the listener closed, and B stayed unapplied.

  | Stop issued during B's | Sampler | Admission | Completion | Status max per trial, update-exchange / store-save |
  | --- | --- | ---: | ---: | --- |
  | update-exchange | on | 0.29–0.35 ms | 2.7–4.7 ms | 0.36 / 0.67, 0.29 / 0.97, 0.39 / 0.72 ms |
  | update-exchange | off | 0.29–0.37 ms | 2.7–5.9 ms | 0.62 / 0.36, 0.29 / 1.60, 0.47 / 1.09 ms |
  | store-save | on | 0.32–0.50 ms | 3.1–5.8 ms | 0.38 / 0.34, **13.27** / 0.65, 0.36 / 1.77 ms |
  | store-save | off | 0.33–0.35 ms | 2.7–**14.5** ms | 0.40 / 0.57, 0.34 / 0.39, 0.62 / 0.36 ms |

  One trial's 13.27 ms status sample (with the sampler) and another's 14.5 ms Stop completion (without it) stand out. This run does
  not separate their causes.
- **`held` (realistic-valid-128 A):**

  | Hold | Second exchange during the hold | Stop | After release |
  | --- | --- | --- | --- |
  | Producer | read and update refused `transportBusy` | proxy, 4.1 ms | the update settled in 58.6 ms |
  | Store | read served; update refused `transportBusy` | tunnels, 0.69 ms | the save settled in 8.8 ms |
  | Fake privileged operation | — | admitted in 0.25 ms; pending while held | outcome observed 6.2 ms after release (quantized by polling); the saved Restart settled with its prior |

  Status p50 was 0.34–0.45 ms in every hold.
- **`cancel`:** an expired read ended `notSent.deadlineExpired`, a cancelled read `notSent.cancelled`, and an expired update
  `notSent.deadlineExpired`. That update's lookup was `unknown.not_recorded`, and the next update settled.
- **`contention` (older):**
  - 8 escape exchanges beside a valid-128 A, with no worker error;
  - proxy Stop 2.8 ms and tunnels Stop 0.69 ms;
  - DNS Stop 36.1 ms (21 lookups), with a private exchange in flight at its admission;
  - status during exchanges: p50 0.47 ms, max 3.2 ms (505 samples).

## Memory (whole probe, sampled)

| Mode | Footprint peak | Peak RSS |
| --- | ---: | ---: |
| contention (largest) | 81.4 MB | 97.9 MB |
| pressure-candidate / client-quit-widest | 77.7 / 76.0 MB | 94.6 / 92.7 MB |
| escape-maximum / repeat / validator-widest | 69.9 / 69.6 / 64.0 MB | 85.0 / 84.7 / 86.8 MB |
| live-A contention trials | 62.4–65.3 MB | 79.1–81.9 MB |
| padded-8mib / realistic-valid-64 / -128 | 43.9 / 28.6 / 28.4 MB | 60.4 / 45.3 / 45.1 MB |
| small, lifetime and cancel modes | 7.3–8.4 MB | 22.0–24.9 MB |

- After release, 3.46–4.22 MB of malloc remains in every host mode. It is not attributed, and no leak or absence of one is
  inferred from it.
- **`repeat`.** Over 6 escape-maximum cycles, live malloc goes 9.375 → 9.585 MB, about +42 KB per cycle, with a phase maximum of
  38.3–42.1 MB per cycle. That is consistent with bounded outcome, alias and log retention, but six cycles reach no plateau, so the
  run shows neither a bound nor a leak.

## Limits of this evidence

- **Memory columns.** *Live* is malloc at a stage boundary. *Phase max* is the 1 ms sampler's maximum since the previous stage, a
  lower bound of the transient peak. Footprint (`ledger_phys_footprint_peak`) and RSS (`ru_maxrss`) peaks are process-wide and
  monotonic. All are whole-probe figures that include the probe's frozen fixtures, and none bounds application memory.
- **Sampler and polling.** The sampler takes the malloc zone locks about every 1 ms; the `-nosampler` modes rerun live A without it.
  Completion is observed by polling about every 1–2 ms, so completion times are quantized by that much. Client and host share one
  process.
- **Fake holds** (`StateFileAccessing`, the probe's helper gate, `PrivilegeClient` over `FakeMachine`) show the service's separation
  and bounds on this machine. They are not real helper or OS latency, or scheduler guarantees. The lane window depends on the main
  thread sleeping; it is a timing method, not a seam.
- **Events** are the ones this run's actions produced: no catalogue sweep, no connection burst, no VPN flap. The ring, ingress and
  drain terms were exercised far below their caps. The 8,192 B per-event cap is therefore checked against 285 B observed, not
  against the widest event the catalogue allows.
- **Not exercised here:**
  - the service's over-budget answer on a real host (read from `RuntimeServiceCore`; the projection's refusal is tested);
  - a post-claim lost wait (`admissionUnknown`);
  - the client quit routine's other branches (unstarted prior revoked, ended stream, deadline expiry), and a no-sampler trial of it;
  - a wake;
  - `testDNS` and `testUpstream` live, which could reach a resolver or an upstream; they are measured in the codecs only.
- **Widest values are the probe's own.** None is a proven absolute bound. Frame sizes are re-encodings, because the in-memory
  transport does not expose its bytes. The initializer's internal budget and record sizes were found by bisection.
- **Single machine, single run.** No figure is a distribution or a shipping limit. The Quit total stays the owner's choice under
  proposed decision 0039; the 30 s here is the experiment's caller budget.
