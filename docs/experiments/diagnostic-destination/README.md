# Diagnostic destination composition probe

Codex ran this owned loopback/scratch probe on2026-10-24 against the actual debug pm-proxy composition. The first attempt waited for connection EOF after a successful response and timed out; the corrected probe terminates after the fixture response body. The successful run refused audit-on-config, emitted exactly one structured refusal, preserved config bytes, served two local HTTP requests and exited0 on SIGTERM. No installed app/helper or user configuration was read or changed. No VPN is required.

Reproduce after an Xcode-prefixed debug build:

```sh
python3 docs/experiments/diagnostic-destination/PMProxyProbe.py /absolute/path/to/pm-proxy
```

This is executed composition evidence, separate from the unit/simulator coverage. It does not test app UI composition, arbitrary concurrent filesystem retargeting, or deployment storage. All processes, sockets and files belong to the probe and are joined/removed on exit. The final successful result was:

> PASS: actual pm-proxy composition refuses audit-on-config, emits one refusal, serves two owned HTTP requests and stops normally; config bytes unchanged
