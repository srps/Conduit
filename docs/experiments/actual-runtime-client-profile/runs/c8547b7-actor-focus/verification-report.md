The focused verification passed and Probe.swift and run.py are frozen. I've finished in this session: no more builds, measurements or edits. I left the marker in place for you.

**Result (one attempt, nothing failed, so there were no failed attempts to keep):**
- The script's exit code was 0.
- The product's Swift 6 Release build completed in 92.6 s.
- The probe compiled with `-swift-version 6` on Swift 6.4 (`swiftlang-6.4.0.34.1`, arm64-apple-macosx26.0), and `compile.log` is empty: no errors and no warnings.
- **small:** exit 0 in 1.19 s, 48 records, 0 failed checks, nothing inconclusive, host and state root released.
- **client-quit-widest:** exit 0 in 3.26 s, 44 records, 0 failed checks, nothing inconclusive, released.
  - The routine returned in 923.7 ms of its 10 s total. Every step settled, the two final saves ran once each in order, and the configuration save applied nothing.
  - After the quit, the listener was closed, the fake system proxy was cleared and the host reported the proxy down.

**Provenance (read from `metadata.json`):**
- HEAD before and after was `c8547b7c098e5abcb0d620067b801cadf27247cf`.
- `productSourcesDirty` is false, there are 0 untracked product files, and the product source fingerprint is `22573d2a041a595feb6dc5ba47ff435ba0502d3d2f1bd71051e1f8170307ce6e`.
- Source, the linked objects and the experiment files were all unchanged during the run.

**Frozen hashes:**
- **Probe.swift:** `af37b3ce54a5af8c8afaced6a9ca750be26740d21fae22125afb85f3c2bd7113`. Unchanged in this session, since there was nothing to fix.
- **run.py:** `2ae0f902e3bb66d9875d8549e169cbf3e195f9099016926850b8906a2879e070`. The only change is the `-swift-version 6` flag, its comment and the docstring.
- **README.md (untouched):** `ea12df0ab5217a3068aff0e7e2100b4b23d4353de3ed42e59d5503b5730d5850`

**Limits:**
- This result applies to Source `c8547b7c` only. Once the fairness fix changes Source, full31 has to rebuild and recompile the probe against the final Source.
- `cancel` and `pressure-candidate`, the modes with the probe-only RuntimeActor holds, were not run here.
- Each mode ran once, with the memory sampler on.
- Everything ran on fakes and loopback only. There is no full-capture or app-RAM claim, and `pressure-candidate` keeps `connectionsOpenedByProbe=0` and `fullCaptureWitness=false`.
- The README still uses the old `*-main-held` names, which is yours to update.

The manifest at `/private/tmp/conduit-runtime-stage1-20261024/runtime-actor-profile-author-manifest.json` has the full record. I just updated it to note that full31 waits for the fairness fix and that the marker is yours. The run outputs are in `runtime-actor-profile-focused-ppTeAT/`.