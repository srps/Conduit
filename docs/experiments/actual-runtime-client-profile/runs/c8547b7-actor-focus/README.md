# RuntimeActor focused Release probe — c8547b7

This is a focused check of `small` and `client-quit-widest`, one fresh process each, on product commit `c8547b7c098e5abcb0d620067b801cadf27247cf`. Both pass with no failed checks, label violations or incomplete host/lease release. The probe compiles in Swift 6 language mode with no warnings. Metadata records clean/stable product sources, linked objects and experiment hashes.

The actual widest client Quit returns in about 924 ms of its selected ten-second total with fake effects. This is neither native/helper timing nor app RAM. The full 31-trial run is deferred until the remaining full-list control-fairness correction, so this focused result is not a replacement for it. The probe-only owner-held cancel/pressure modes were not exercised here. See [the verification report](verification-report.md) and [metadata](metadata.json).
