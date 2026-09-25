# Runtime Event Stream — Public Contract (schema v1)

**Status:** Contract. This document specifies the event stream
and observable state files as the **first-class extension surface** of
Conduit. Observer extensions (exporters, notifiers, dashboards) build
against this document — not against the Swift source.

## Stability promise

- The current schema is **v1**. A consumer that sees no explicit version
  marker must assume v1; future schema bumps will stamp themselves in
  `ready.json` / the control-socket `status` response before any breaking
  change ships.
- Within a major schema version, changes are **additive only**: new event
  names, new `kind` values, and new JSON fields may appear; existing fields
  never change type or meaning, and existing event names never change
  semantics. Build consumers that ignore unknown fields, kinds, and names.
- Event `detail` strings are diagnostic text: their *presence* is contract,
  their exact wording is not. Parse the documented `key=value` tokens, not
  sentence structure.

## Where events appear

| Surface | Form | Notes |
| --- | --- | --- |
| `$state-dir/events.ndjson` | One JSON object per line | Rolling, size-capped (default 1 MiB); oldest lines are trimmed. Written atomically per event. |
| `pmctl events [--follow]` | Same NDJSON lines | Reads the file; `--follow` tails it. |
| Control socket `events` command | Same NDJSON lines | Daemon-served. |
| In-app event log / `snapshot.json` | Same objects embedded in snapshots | The UI mirrors the daemon; it does not invent state. |

All file-boundary JSON is produced by `CanonicalJSON.encoder()`:
**timestamps are Unix-epoch seconds as a JSON number** (`Double`), directly
readable by `jq`, Splunk, Datadog, and `date -r`.

## Event object shape

```json
{"timestamp": 1781136000.123, "kind": "auth", "event": "auth.kerberos_fallback_ntlm", "detail": "host=proxy.corp:3128 reason=bad_mech"}
```

| Field | Type | Required | Meaning |
| --- | --- | --- | --- |
| `timestamp` | number (epoch seconds) | yes | Emission time. |
| `kind` | string enum | yes | Coarse category — see below. |
| `event` | string | yes | Dotted machine name, `<subsystem>.<what_happened>`. The primary dispatch key for consumers. |
| `detail` | string | no | Diagnostic detail, often `key=value` tokens separated by spaces. **Always credential-sanitized** (`Authorization`/`Proxy-Authorization`/cookies/bearer/long-base64 masked, URL userinfo stripped) before it reaches any sink. |

### `kind` values (v1)

`lifecycle`, `routing`, `auth`, `connection`, `health`, `config`, `vpn`.
New kinds may be added; ignore unknown ones.

## Event catalogue (v1)

Names marked *(planned)* are reserved by the roadmap and will appear with
exactly these semantics; do not repurpose them.

### lifecycle
| Event | Emitted when |
| --- | --- |
| `init` | Ring-buffer placeholder; never meaningful, filter it out. |
| `proxy.starting` / `proxy.stopping` | Orchestrator lifecycle transitions. |
| `daemon.ready` | Daemon runtime host finished startup (`detail: mode=…`). |
| `platform.launch_recovery_restored` | Launch-time crash recovery found a surface a run that never tore down left applied, restored the journal's recorded prior values and released it (`surface=systemDNS` or `surface=systemProxy`, `stale=true` when the records were over 7 days old and were restored without a liveness probe). One event per surface per launch from both hosts, in the order system DNS, system proxy, resolver files. Emitted before the log line. |
| `platform.launch_recovery_nothing_to_do` | Recovery had nothing to act on for a surface (`surface=`, `reason=` one of `nothing_recorded`, `already_settled`, `fresh_install`, `no_journal`). |
| `platform.launch_recovery_declined` | Recorded state exists, but a local listener is still serving it, so another session owns the machine and it was left alone (`surface=`, `reason=live_listener`). |
| `platform.launch_recovery_discarded` | System DNS: a resolver answers on `:53` but no interface points at loopback any more, so the records described nothing and were dropped without a write (`surface=systemDNS`, `reason=no_interface_points_at_loopback`). |
| `platform.launch_recovery_adopted` | The one-time resolver-file scan on the first launch of a release that records resolver files (`surface=resolverFile`, `adopted=`, `removed=` whether adopted files were removed because the switch is off, `foreign=` files with other contents left alone, `unjudged=` entry files left in place). |
| `platform.launch_recovery_skipped` | A recovery step was not attempted (`surface=`, `reason=config_unavailable` when the config failed to load, which only the resolver scan needs; `reason=journal_unreadable`). The daemon emits these to `events.ndjson` even when it then exits on a bad config. |
| `platform.launch_recovery_failed` | A restore threw, or part of it did not land and the records were kept for the next launch to retry (`surface=`, `reason=` the error, or `records_kept`). |
| `lifecycle.crash_restart` *(planned)* | First startup after an unclean exit; detail references prior exit evidence and the matching crash-report name. |
| `lifecycle.update_restart` *(planned)* | Restart performed by the in-app updater. |

### routing
| Event | Emitted when |
| --- | --- |
| `direct_mode.entered` | Routing flipped to direct (`detail` carries the cause). |
| `local_pac.starting` / `started` / `stopping` / `stopped` / `restarting` / `updated` / `failed` | Local PAC server lifecycle; `detail: reason=…`. |
| `pac.refreshed` | The routing engine installed a freshly fetched PAC (`url=`, credentials stripped). |
| `pac.refresh_failed` | A PAC fetch or compile failed; `detail` is the error text. The last working evaluator stays in place. |
| `pac.refresh_backoff` | A path-triggered refresh was skipped because the URL is in failure backoff (`failures=`, `remainingSeconds=`). Wake, VPN reconnect, user action and a changed URL bypass it. |

### auth
| Event | Emitted when |
| --- | --- |
| `auth.kerberos_succeeded` | Initial Kerberos leg produced a token (`host=`). |
| `auth.kerberos_fallback_ntlm` | Credential-class Kerberos failure downgraded to NTLM (`host=`, `reason=` one of `no_credential`, `credentials_expired`, `bad_mech`, `failure`, `no_ticket`, `service_ticket_unavailable`, `routine_<n>`). |
| `auth.kerberos_failed` | A Kerberos failure reached the request with no NTLM answer: no saved password, a failure that permits no fallback, or a continuation token GSS rejected (`host=`, `reason=` as above, plus `other`). At most once a minute for each host and reason. Not emitted while a missing credential is being retried; `auth.credential_retry` covers that. |
| `auth.ntlm_configured` | NTLM credentials became available to the authenticator stack. |
| `auth.handshake_rejected` | Pending-handshake bound (global or per-source) rejected a new upstream 407 handshake. |
| `auth.credential_retry` | The initial Kerberos token was unavailable and is being retried (`host=`, `attempt=`, `delayMs=`). |
| `auth.credential_outage` | A retried handshake still had no credential; further handshakes to that upstream fail at once for the hold (`upstream=`, `holdSeconds=`). |
| `recovery.skipped` | The recovery ladder was not run because the health check failed for a missing credential, which no ladder step can supply (`reason=credential_unavailable`, `summary=`). |
| `auth.privilege_request` | A privileged-helper call was made; request/outcome pair, raw helper values never included. |
| `config.auth_changed` / `config.auth_reauth_failed` / `config.tunnel_auth_reauth` | Auth-section config reload outcomes. |

### connection
| Event | Emitted when |
| --- | --- |
| `streaming.response_interrupted` | Upstream died mid-streamed-response; the client connection is closed rather than silently truncated (`uri=`, `upstream=`, `cause=`). |
| `upstream.response_timeout` | Upstream exceeded `upstreamResponseTimeout` for a response. |
| `upstream.tunnel_failed` / `upstream.exchange_failed` | A CONNECT tunnel or an HTTP exchange through the upstream failed and the client got a 502 (`target=`, `reason=`). Emitted before the error log line. Not emitted for a failure the cause makes expected (a transient path change), which is logged at info, nor for a request the pool refused locally, which never reached the upstream: exhaustion is `connection.pool_exhausted`, a handshake-limit refusal is `auth.handshake_rejected`. |
| `connection.upstream_invalid_response` | The upstream's reply to a CONNECT could not be framed (malformed status or fields, signed/overflowing/duplicate/conflicting lengths, unsupported transfer coding, bad chunking, or a head over 64 KiB) (`upstream=`). The attempt fails and the connection is closed. Emitted before the warning log line. |
| `connection.pool_exhausted` | The connection pool refused a request at its `maxConnections` cap and the client got a 502 (`target=`, `reason=`). Emitted before the error log line; a local refusal is loud even during a transient path change, which demotes upstream failures to info. |
| `direct.connect_failed` | A direct connect the request was routed to failed unexpectedly (`target=`, `reason=`). Direct failures while the VPN is off, and repeats of a remembered link-local timeout, are info log lines only. |
| `direct.link_local_refused` | A direct connect to a link-local literal was refused at once because one timed out within the last minute (`target=`, `secondsAgo=`). |

### health
| Event | Emitted when |
| --- | --- |
| `upstream.circuit_opened` / `circuit_half_opened` / `circuit_closed` | Circuit-breaker transitions per upstream. |
| `upstream.test.invalid` / `not_found` / `probe_empty` | `test-upstream` command edge outcomes. |
| `dns.pipeline_unresponsive` / `dns.relay_restarted` / `dns.transports_reset` | DNS forwarder self-healing actions. |
| `dns.listener_port_retry` | The forwarder was started on port 0, got an ephemeral UDP port, and found the TCP port of the same number held by another socket; it released the UDP port and is binding the pair again on a fresh one (`port=` the port given up, `attempt=`, `of=`, `reason=tcp_port_in_use`). Emitted before the log line. |
| `dns.listener_port_release_failed` | During a port-0 rebind the forwarder could not close the UDP port it was giving up (`port=`, `attempt=`, `error=`). The start fails rather than binding a second pair beside a socket that may still answer; `stop()` closes it again. Emitted before the log line. |
| `dns.tcp_listener_unavailable` | The forwarder has no TCP listener. `outcome=udp_only`: the TCP bind failed on a configured port, or for a reason another port would not cure, and the forwarder serves UDP only (`port=`, `error=`). `outcome=start_failed`: started on port 0, no port was free on both UDP and TCP within the attempt budget, and the start failed (`port=` the last one tried, `attempts=`). Emitted before the log line. |
| `network.path_changed` | A debounced network-path update reached the orchestrator, with what it decided (`satisfied=`, `dns=reset|idle`, `pac=refresh|skipped_unsatisfied`, `path=` the description). Emitted before the log line and before the actions it names. |
| `error_rate.alarm` | The recent-failure window crossed the alarm threshold (`failures=`, `windowSeconds=`); the window is drained and the alarm holds off for 30 s. |
| `recovery.suppressed` / `recovery.cooldown_started` | A health failure did not start the ladder because one is in flight or a cooldown is running (`reason=`, `remainingSeconds=`, `summary=`); a finished ladder starts its cooldown (`seconds=`). |
| `tcp_relay.reasserted` / `tcp_relay.unresponsive` | The transparent-proxy relay probe found the helper's port-443 relay gone and reissued it, or found it bound but not accepting (`host=`, `target=`). |

### config
| Event | Emitted when |
| --- | --- |
| `config.routing_changed`, `config.logging_changed`, `config.metadata_changed`, `config.proxy_limits_updated`, `config.dns_restart`, `config.health_restart`, `config.proxy_restart`, `config.proxy_restart_failed`, `config.strict_mode_pac_refresh`, `config.tunnels_reconcile`, `config.tunnels_reconcile_rejected`, `config.upstreams_refresh`, `config.upstreams_deferred` | Per-subsystem outcomes of a config reload. The set grows with the targeted-reload work; treat unknown `config.*` names as informational. |
| `config.platform_integration` | A platform integration switch (system proxy, shell environment, resolver files, system DNS, launch at login) changed on save and its surface is about to be applied or cleared; `detail` names the action. Emitted by the app, before the side effect. |

### vpn
| Event | Emitted when |
| --- | --- |
| `vpn.connected` | VPN observer reports an active link. |
| `vpn.disconnected.user` / `vpn.disconnected.lost` | Deliberate vs. lost disconnect (drives different recovery posture — see `docs/design-vpn-flap-resilience.md`). |
| `vpn.flap.start` / `vpn.flap.recovered` | Debounced flap window opened / closed (`detail` carries durations and preserved-stream counts). |

## Sibling observable files

| File | Contents |
| --- | --- |
| `$state-dir/snapshot.json` | Full `ProxyOrchestratorSnapshot`, written atomically (temp + rename) on the status interval. Superset of what the UI shows. |
| `$state-dir/ready.json` (`pm-proxy`) / `daemon-ready.json` (daemon) | Written once at startup readiness: bindings / initial status. |
| `$state-dir/audit.ndjson` *(planned)* | Per-connection audit records (CONNECT target, PAC decision, route, auth method), credential-masked. Separate contract; documented when it ships. |

## Consumer guidance

- Dispatch on `event` (exact match), group on `kind`.
- Tail with rotation-awareness: the file is trimmed in place (rewritten
  atomically), so `tail -F` (capital F) semantics are required.
- Never assume an event you depend on is the *only* signal: snapshots are
  the state of record; events are the change log.
- The sanitizer is the last line of defense, not an invitation: if you
  build an exporter, do not log `detail` into systems with weaker access
  controls than the user's own machine without review.
