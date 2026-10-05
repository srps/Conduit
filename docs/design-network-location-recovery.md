# Network-location-safe recovery

Design for roadmap #110. Location selection and profile automation remain later work.

## Mutation contract

The app and daemon share a PlatformMac location store and recovery policy. A
snapshot enumerates stable SCNetworkSet and SCNetworkService IDs, including
inactive sets. The active set is observed independently of VPN/path changes.

The helper v5 command, `compare-network-settings`, carries a bounded typed
request: location ID, service ID, DNS or proxies, expected managed fields,
replacement managed fields, and whether the location must still be active.
Only ServerAddresses and Conduit's existing HTTP/HTTPS/PAC/bypass fields are
mutable. Authentication fields and unrelated protocol settings are excluded.
Applying PAC mode requires a nonempty URL before any mutation. Live-session
protection probes only enabled endpoints on enabled services in the active set.
Bypass lists share config/helper grammar bounds: 256 entries, 253 UTF-8 bytes
per entry, and 8 KiB encoded aggregate size. Configuration warnings identify larger
lists and manual system-proxy application rejects them before capture. Routing and
PAC startup remain available because they do not consume the helper bypass list.
The helper locks SCPreferences without waiting, verifies set membership, active
set when required, and expected fields before committing. It merges the selected
fields into the current configuration, preserving unrelated fields. Recovery can
target an inactive set without selecting it. Old v3/v4 commands retain their
behavior; old helpers reject v5 rather than receiving service-name fallbacks.

## Journal and recovery

New records carry stable location/service IDs, prior fields, and both the previous
and intended applied fields. Failed reapplication can therefore recover either
observable generation. Persist them before mutation and fail closed on persistence errors.
After a successful compare-and-write, finalize the journal without the previous
generation so a later external edit back to it is preserved. Compare/helper
execution failures in the same active location retry from a fresh snapshot,
with two attempts by default (configurable from one to four), structured retry
events, and no timer. Admission refusals and location switches do not retry.
Restoration compares the applied fields; external edits are preserved. Successful
or superseded records are released individually; failures remain for retry.
The cleared fast path requires no outstanding records, including inactive sets,
so stopping retries recovery after an earlier location-switch write failed.
Service/location deletion releases only that identity's record. Renames retain it.

Untracked settings, including a user's local resolver, are preserved and captured
unchanged as prior state. Residue cleanup requires legacy journal evidence or an
unreadable journal. A corrupt journal triggers recognized residue inspection and
cleanup, reports that prior settings are unknown, and stays intact for repair.
All journal writes refuse to replace that evidence, including other surfaces'
release markers. New network, environment and resolver application fails until
the journal is repaired and reloaded. Resolver cleanup may retain in-memory
adoption records for retry; these do not authorize new writes.
The unreadable-journal fallback deliberately favors removing recognized dead
listener residue over retaining an indistinguishable user-owned loopback setting.
Unlike an absent journal, corrupt existing evidence cannot prove Conduit never
changed the settings. This matches the established resolver/proxy recovery policy.
Legacy service-name entries have unknown location identity. Never migrate their
prior values into the current location by guessing. Sweep exact Conduit loopback
residue across all sets, removing those endpoints while preserving external
configuration, then retire ambiguous legacy records only after successful cleanup.
Unrecognized loopback or gateway endpoints (such as a previous configured host
or port) retain legacy evidence. Non-loopback endpoints exactly matching a known
legacy prior are left as-is; prior values are never installed by service name.
Other unmatched endpoints on a service associated by the legacy name require
residue inspection before retiring the record. If that name is absent, identity
is unknown and evidence is retained. Corporate endpoints on unrelated named
services do not block recovery. These name checks only limit ambiguity; they
never authorize installing legacy prior values.
Unattributed residue retains the legacy evidence and emits a failure rather than silently claiming recovery.
Known scoped records are restored independently before that legacy failure is
returned, so an ambiguous old record cannot prevent their teardown.
DNS residue cleanup returns explicit DNS to DHCP, since the original location is
unknown. Emit events describing that loss of prior-state attribution.

Unsupported or credential-bearing protocol settings are isolated to that service
and protocol. Its recovery record remains for retry; other identities and the
other protocol can still recover. No credential-bearing fields enter the snapshot.

When application is disabled, location reconciliation retries every outstanding
record, including the active location, so returning after a failed teardown cannot
leave settings pointing at a stopped listener. When application is enabled, an external location switch restores outstanding
inactive-location records and reconciles the active location through the existing host readiness and VPN gates.
Do not modify routing mode, VPN detection, or split-DNS policy. Active-set and expected-value checks
inside the privileged write reject a switch racing an apply.

Managed proxy reconciliation also runs after helper availability, VPN/path reports,
and wake. Preferences notifications with an unchanged location ID also schedule
proxy reconciliation: a VPN client can rewrite PAC after its VPN/path reports
have already settled. Waiting for another NWPath report can leave the corporate
PAC active for minutes. This repairs failed startup writes and late same-location PAC rewrites.
It reads the active settings first and skips already-matching writes; an external
edit becomes the new captured prior state before repair. Both hosts coalesce
preferences bursts before scheduling a task: one tracked delivery and one pending
pass. They also coalesce helper work, wait for lifecycle work, and check
the lifecycle generation before mutation. Listener bindings remain unchanged.

Drift repair is bounded per surface and active location: at most
`maximumDriftRepairs` (default 4) within a sliding `driftRepairWindow` (default
60 s). A VPN client or MDM profile that re-applies its own proxy settings after
every Conduit write therefore cannot hold both programs in a write loop. Past the
budget its settings stand and one `platform.location_contended` event reports the
episode. A repair counts once it has committed any write, even if a later service
fails, because each commit posts a notification; a pass that wrote nothing keeps
its own retry bound. Services already applied and recorded are not re-committed.
The withheld repair returns its retry delay, and each host keeps at most one
pending pass for when the window reopens, so Conduit's settings come back even if
the other program goes quiet and no notification follows. A location change also
starts a fresh budget. Explicit apply at start and restoration at stop are never limited.

Preferences notifications repair proxies only. Same-location DNS rewrites are
repaired by the per-report DNS reconcile on VPN/path changes (#101).

## Verification and deployment

Fakes model multiple locations, stable identities, external edits, deletion,
switches during mutation, failures, and repeat recovery. Unit tests and pm-sim
cover those contracts; both host harnesses cover observer delivery. Bounds cap
snapshot size, request size, and outstanding location records. No verification
mutates the serving app or installed helper. Deployment needs an explicit helper
installation and controlled corporate-VPN validation. The general target is
macOS 26/27. 0.4.0 passed the macOS 26 corporate-VPN cycle with helper v5; the
release owner waived unavailable macOS 27 testing, which remains untested.

## Implementation and deployment status

The helper operation, shared recovery policy, journal, observer, fakes, and both
host compositions are implemented. Observer work is coalesced and guarded by the
host's existing lifecycle generation so a later stop supersedes it. Observations
wait for lifecycle lanes to become idle before reading readiness, so a notification
during stop cannot enqueue reapplication behind teardown. Requested runtime
readiness drives apply even if the journal currently has no records, so passing
through an empty location cannot suppress a later valid-location retry.
DNS reconciliation restores inactive records independently, then establishes
the privileged relay idempotently at the actual bound forwarder port. A failed relay start withholds system DNS redirection;
a later notification can retry even without saved DNS records. Ordinary VPN/path
reconciliation also takes the scoped path before checking legacy saved records,
waits for lifecycle work and uses the actual forwarder port. Existing
service-name manager paths remain only for explicit legacy harness composition;
production hosts always construct the scoped store. Dev launches inject fakes.

When no console user is present, scoped removal of loopback listener fields is
admitted, while corporate endpoints and bypass lists cannot be removed through
that exception. Malformed scoped arguments retain their invalid-arguments
response/audit category after peer and caller-identity admission; they cannot
execute or be mistaken for session readiness failures. Valid 127/8 addresses, localhost and IPv6 loopback are supported.
Installing prior
values is deferred. The journal keeps the previous settings until login; this
removes dead loopback endpoints without widening apply permission at loginwindow.
Endpoint/PAC URL removal also removes its enable flag, even when the prior
configuration was enabled, so cleanup cannot leave an enabled empty proxy.
DNS cleanup attempts to stop the privileged relay on every outcome, including
failed and deferred restoration. Journal evidence stays available for retry;
a failed relay-stop command emits a structured failure instead of claiming success.

New clients require the v5 helper for scoped operations, with no AppleScript or
service-name fallback. Run `sudo ./install-helper.sh` after installing this build;
no automated validation reinstalls the helper or replaces the serving app.
Legacy v3/v4 requests remain supported by the v5 helper. The journal now writes
canonical epoch timestamps and reads historical ISO-8601 records. Do not roll back
to an old client while scoped records remain outstanding; stop this build and
complete restoration first, and retain the journal when troubleshooting rollback.

Validated on macOS 26 with the corporate VPN client for 0.4.0; macOS 27 is untested.
Profile associations (#114) and opt-in location switching (#115) are separate work.
