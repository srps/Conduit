# Off-owner capture: the frozen kernel's object custody (read-only assessment, corrected)

Status: read-only. No Source, test, script, Probe.swift or run.py was edited, compiled or run. The R5 Source stays frozen. This version
replaces the first one, which wrongly applied the connection row guard to every kind and gave unmeasured layout numbers as a
worst case. No product design change is proposed.

## Corrected short answer
- **What a flight holds:** one frozen whole `orchestrator.snapshot` value, plus the selected kind's projected rows until commit.
- **How big it can be:** bounded by the kernel's existing capacities and configuration (the inbound connection limit, the configured
  upstreams and tunnels), **not** by the encoded row cap, for every kind.
  - The 10,000-row refusal before the freeze applies only to the *requested* kind's total.
  - A flight for a small kind (upstream health, tunnel bindings, tunnel DNS hosts) freezes the same whole snapshot, so it can pin the
    connection storage of that turn whatever its size.
  - No hard whole-value bound, and no MiB worst case, is claimed.
- **The freeze adds no unshared-to-shared transition for the collection storages.** In the same `pageSource` turn, `owner.snapshot()`
  runs `collections.revisions(of:)`, so each collection tracker already holds its storage (connections, upstream statuses, tunnel
  bindings, tunnel DNS status). The freeze is one more holder of that already shared storage, so it adds no owner copy.
  - The owner's O(n) copy-on-write on the next mutation exists today because of the tracker.
- **Extra retention relative to today:** only after a later `snapshot()` moves the trackers on. The flight is then the last holder of
  the older storages until commit, shutdown drop, or the job's end.
- **The existing fixtures project immutable kernels**, so they cannot witness this copy-on-write retention and must not be cited for it.

## 1. Structure (from the code)
- `RuntimeHostControlOwner.rowSource` captures `orchestrator.snapshot` whole for every kind, with no per-kind overloads (amendment 3).
- `RuntimeServiceCore.awaitCapture` checks only the requested reference's total against `collectionRowCapacity` before freezing.
- `ActiveConnectionStore` (`ProxyStatus.swift:193-265`) holds `ordered: [ActiveConnectionInfo]` and `indexByID: [UUID: Int]`:
  - `update(id:)` (an activity tick) mutates only `ordered`;
  - `insert` and `remove(id:)` mutate both.

  So after the freeze, which buffers the owner's next mutation copies depends on the mutation kind. The buffers the flight then keeps
  alive alone are whichever ones were copied.
- **Strings:** an array copy retains each element's string storage rather than duplicating it. The older buffer additionally keeps
  alive the strings of rows removed or rewritten since the freeze.
- **Projection transients are not new.** The sorted copy and the selected rows existed before, inside the owner turn. They now live in
  the job until commit, and the rows then move into the ledger, where their encoded bytes are charged.
- **Not an accounting bound.** Array and dictionary capacity growth, allocator rounding and string storage make any layout arithmetic a
  rough guide, not a RAM figure. This report gives none as a bound.

## 2. Duration
The flight's lifetime is the projection time of the selected kind. The optimized trials measured 0.48–0.63 s for 10,000 connection
rows; the small kinds are far shorter. Retention therefore follows how long and how often pages need a capture. Under connection churn
the app's observer keeps re-reading, as before.

## 3. Witnesses
- **The optimized fake-owner trials, `AppStateCollectionCaptureCostTests` (the parent's frozen file, read only) and Probe.swift's row
  kernels** all project immutable kernels. With no mutation during the flight, no copy-on-write divergence exists to observe.
- **An actual-host witness** would need a hold on the production projection, which would mean a production test hook. That is excluded.
- **Process RSS or footprint** around a sub-second transient of this size is inside allocator noise and earlier high-water marks, so it
  would be vacuous.

## 4. Optional one-off observation (written, not run)
`/private/tmp/conduit-runtime-stage1-20261024/kernel-cow-observation/` holds one standalone Swift file (≈50 lines) and its instructions.
- **What it is:** an external, throwaway program, not an XCTest, not a probe mode and not a product change. It links the same Release
  objects through the same `run.py` compile shape.
- **What it logs** (numbers only, no assertions), at 1,000 and 10,000 rows of the existing typical shape:
  - `MemoryLayout<ActiveConnectionInfo>.stride`;
  - the store's array capacity;
  - malloc-in-use deltas for one activity `update` (array copy) and one `remove` (index copy) while a second holder exists, and the
    bytes freed when that holder is released.
- **What it observes:** the kernel type's own copy-on-write on this machine and allocator. It does not drive the flight. The flight's
  part, holding one more value of the same storage, is structural (§1).
- **When to skip it:** if you judge it noise, this corrected structural report stands on its own.

## 5. Limits
- Nothing here measures the installed app's RSS, or retention under real connection churn.
- The one-off's numbers, if run, describe single allocations in a quiet single-threaded process. They are not a RAM bound for the app.
- Small heap-backed fields of the snapshot outside the four collections (error strings, bindings scalars) are frozen too. They were not
  sized here.
