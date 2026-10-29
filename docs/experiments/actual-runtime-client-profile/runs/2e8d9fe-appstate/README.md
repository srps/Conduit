# Selected app composition: actual Release client profile

All 31 fresh process trials passed 481 checks, with no failures, inconclusive or
pinned results. Every scratch root was removed, every host released, its wake
observer stopped and its lease reacquired. Metadata records clean product source
`2e8d9fe7f8752ea20d0798c29416ed8910d8a417`, stable product fingerprints and unchanged
linked Release objects. The complete workflow finished before this run; no other
build/test/probe ran concurrently. README hashes describe the text before this
report was written.

The actual `RuntimeServiceProfile.inProcessApp()` is compared with independent
codec-derived sizing in every host mode. Ordinary frames stay 64 KiB, private
frames 8 MiB, complete capture 4 MiB / 10,000 rows and host retained rows 8 MiB. The initializer
accounts 17,082,600 encoded bytes; this is neither a reservation nor app memory.

The actual widest `RuntimeClientQuit.quit` routine used a 10,000 ms total and returned
in 974.47 ms, including a deliberately held earlier update and final frozen config
and preferences. Both final files verified, the listener closed, system proxy
cleared, flush confirmed and host/lease released. The 3.295 s mode process duration
also includes setup and final verification. Fake timing is not real-helper or
AppKit timing.

[Metadata](metadata.json) and [build/run provenance](build-and-probe.json) retain
all commands, object and source hashes and the 31 trial records. Each `.ndjson`
contains short-label numeric evidence enforced by the runner, including all 481
semantic checks. No actual user configuration, Keychain, helper, VPN or host
settings were used.

The worst-shape probes retain fixtures, observations and multiple drafts on
purpose. Their process RSS/malloc includes those objects and runtime overhead;
it cannot be read as Conduit's steady-state RAM or as a 4 MiB/17 MB allocation promise.
The app-consumer observation is a separate Debug test, and native/real-machine
and hosted acceptance remain separate.
