# Verification: DNS launch recovery from the relay witness (2026-11-05)

This is the owner's real-machine check for [0041](decisions/0041-dns-recovery-from-helper-relay-witness.md)
(#201). It shows that a crashed session's system DNS comes back at the next launch with no click
and no notice.

## Setup

- Conduit 0.6.1+ built from main at `6fd66849` (#270) and installed with
  `./bundle-app.sh --release --install`. The build is signed with the local signing identity.
- The helper was reinstalled with `sudo ./install-helper.sh` for that identity. Its ping lists
  `dns-relay-status`.
- "Manage system DNS" was on, on Wi-Fi.

A first attempt at 15:35 didn't count. The helper had been installed for the release-signed
0.6.1 app, so it refused every command from the new build (`auth.privilege_helper_refused
reason=unauthorized`). System DNS was never applied and recovery had nothing to do. Reinstalling
the helper for the new identity fixed that, and the check below ran afterwards.

## Steps and result

1. The app started and the helper started the DNS relay. System DNS pointed at 127.0.0.1.
2. The owner ran `kill -9` on the app.
3. The owner relaunched it.

From `~/Library/Logs/Conduit/proxy.log`:

```
[2026-11-05T15:41:01.972Z] [NOTICE] [System] DNS relay started on :53 -> :5053 via helper.
[2026-11-05T15:41:30.875Z] [NOTICE] [System] DNS relay on :53 stopped.
[2026-11-05T15:41:30.876Z] [WARNING] [System] Launch recovery (surface=systemDNS stale=false evidence=relay_target_refused): found settings recorded by a run that never tore down (likely a crash); restored the previous settings.
[2026-11-05T15:41:31.100Z] [WARNING] [System] Launch recovery (surface=systemProxy stale=false evidence=port_refused): found settings recorded by a run that never tore down (likely a crash); restored the previous settings.
[2026-11-05T15:41:35.594Z] [NOTICE] [System] DNS relay started on :53 -> :5053 via helper.
```

The helper's witness read the dead session's forwarder as refused. Recovery stopped the orphaned
relay, restored the recorded DNS settings with no prompt and no notice, and the new session then
started its own relay and applied DNS again. Afterwards `networksetup -getdnsservers Wi-Fi`
printed `127.0.0.1`.

## Not covered

- The 0042 fallback: a helper without `dns-relay-status`, or a silent target, which should show
  the notice with Update Helper. It was not exercised on the real machine.
