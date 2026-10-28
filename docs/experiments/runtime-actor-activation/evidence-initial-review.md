I've finished the initial probe review. The RuntimeActor adaptation in `Probe.swift` and `run.py` is sound: no deadlock and nothing still holding the main actor in place of the owner. I found one label that is literally false, plus three things to check when reading the outputs. None of them needs a code change or a rerun. I couldn't hash the files (no Bash here), but the current files match the `activation.patch` in every region I read.

## Defects and overclaims

**1. `connectionsOpenedByProbe: 0` is false as written (low severity, scope unaffected).**
- `Probe.swift:3880` hard-codes the value, and the comment at `:3877` says "the probe opens no proxy connection".
- But `:3847`, inside `pressure.savedStartSettledWithCausalReceipt`, calls `loopbackAccepts(port)` just before the pages are read. That connects a TCP socket to the live proxy listener and closes it without sending anything.
- What is true: the probe sends no proxy request, drives no dispatch and makes no full capture, so `fullCaptureWitness=false` stands.
- Fix it in the docs, not in Probe.swift (editing the probe would invalidate the frozen hash), e.g. "no proxy request; one connect-only liveness check, closed before the pages".
- Also read `activeConnectionsTotal` in the pressure output. A value of 1 would be this connect, not a collection witness.

**2. The checks don't prove the owner hold actually overlapped the exchanges (pre-existing gap, now the key evidence).**
- `ownerHeldAfterCallersSpawned` and `ownerHeldAfterCallerSpawned` only prove the RuntimeActor job was still running after the tasks were created.
- `pressure.stopNotRefusedWhileOrdinaryAndReadLanesFull` passes even if no lane filled. The real witnesses are `readLaneFillObserved` and `ordinaryLaneFillObserved` (`:4002-4003`), which are written to the output but never checked.
- In the cancel mode, the result labels are also never checked.
- Accept the owner-held claims only if the outputs show:
  - **Lane window:** both fill flags are `true`. The 673e53a run had 4 reads refused and the ordinary lane at 4 `transportBusy` plus 4 `queue_full`.
- **Cancel:**
  - case (a): `client.notSent.deadlineExpired`;
  - case (b): `client.notSent.cancelled`;
  - case (c): a deadline end, then a lookup (`unknown.not_recorded` in 673e53a), then the fresh update settles.

**3. Two comments claim more than the flags show (wording only).** `:2306` says "every exchange the caller sends afterwards meets a held owner", and `:2882` says the hold "spans the send". The flags only show the hold stood at spawn, or at the cancel. A passing run can't overclaim the timing, because a hold that ends early marks the run inconclusive (exit 3), which fails `run.py`.

**4. README wording.**
- `README.md:3` says these modes "are excluded from strict-pool runs", but `run.py` has no strict-pool run and doesn't enforce an exclusion. Its docstring correctly says "exclude".
- `README.md:3` also says "full31 awaits the full-list fairness correction", which f3abd5f has now overtaken.
- `README.md:199` and `:314` still describe the old main-thread-sleep method alongside the historical 673e53a numbers. You already track this.

## What I checked and found sound

- **Hold mechanics:**
  - `holdOwner` is one synchronous `@RuntimeActor` job. It sets `inFlight` from inside the job, so `ownerHeld` returns only once the owner is actually held. It sets `finished` before the job ends, so "not finished" at any moment means the hold was still standing then.
  - The client side never needs the owner: the transport, its lane reservation, the gate timer and cancel, and the private channel's custody all run off RuntimeActor. Lanes therefore fill and deadlines fire during a hold, while the owner's rounds queue behind it.
- **No deadlock, nothing main-held:**
  - The only `usleep` calls are in `holdOwner` and in the sampler's own `Thread` (`:224`). The main actor only ever awaits.
  - Every hold ends by itself (150, 120, 150 and 100 ms) and is awaited before release (`:2872`, `:2894`, `:2919`, `:3994`).
  - If a hold isn't entered within 5 s, the mode fails with `ownerHoldNotEntered`.
- **Labels:**
  - The new strings fit `run.py`'s label check (`LABEL`, at most 120 characters). The `ownerHeldWindows` label already passed in the c854 `small` mode with 0 label violations.
  - The hold flags are booleans.
  - The `cancel` labels and the lane-window label were never run on c854; for the lane-window `method` string I checked the characters only, not the length.
- **Real-host release and lease:** the logic is unchanged. Settle and flush are awaited across the actor boundary. The proof still waits for the host to deallocate, then acquires the lease twice. `hostProxyIsUp` reads the state in one owner turn and returns only a Bool.
- **Scope:**
  - The probe links the `.build/release` objects with `-package-name` and `-swift-version 6`. `Package.swift` has no `enable-testing`; its only unsafe flag is an rpath linker flag.
  - So this is the shipping production modules, run against fakes and loopback. It is not the signed app bundle, the app/UI target or the helper. It is separate from the optimized XCTest-with-testability evidence behind the 10k fairness result.
  - `pressure-candidate` is not a full 10k run and has no over-bound witness.
- **Corrected resource assessment:** it is consistent with the probe. The probe's row kernels are immutable, so they can't show copy-on-write divergence, and no whole-value or MiB worst case is claimed.

## Still to confirm from the final results

- The `metadata.json` for R5 and full31 should show `probe_sha256 = af37b3ce…` and `runner_sha256 = 2ae0f902…`, with sources and objects unchanged during the run.
- The values from items 1 and 2 above.

I'll wait for your final results before accepting.