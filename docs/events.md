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
| `lifecycle.crash_restart` *(planned)* | First startup after an unclean exit; detail references prior exit evidence and the matching crash-report name. |
| `lifecycle.update_restart` *(planned)* | Restart performed by the in-app updater. |

### routing
| Event | Emitted when |
| --- | --- |
| `direct_mode.entered` | Routing flipped to direct (`detail` carries the cause). |
| `local_pac.starting` / `started` / `stopping` / `stopped` / `restarting` / `updated` / `failed` | Local PAC server lifecycle; `detail: reason=…`. |

### auth
| Event | Emitted when |
| --- | --- |
| `auth.kerberos_succeeded` | Initial Kerberos leg produced a token (`host=`). |
| `auth.kerberos_fallback_ntlm` | Credential-class Kerberos failure downgraded to NTLM (`host=`, `reason=` one of `no_credential`, `credentials_expired`, `bad_mech`, `failure`, `no_ticket`, `routine_<n>`). |
| `auth.ntlm_configured` | NTLM credentials became available to the authenticator stack. |
| `auth.handshake_rejected` | Pending-handshake bound (global or per-source) rejected a new upstream 407 handshake. |
| `auth.privilege_request` | A privileged-helper call was made; request/outcome pair, raw helper values never included. |
| `config.auth_changed` / `config.auth_reauth_failed` / `config.tunnel_auth_reauth` | Auth-section config reload outcomes. |

### connection
| Event | Emitted when |
| --- | --- |
| `streaming.response_interrupted` | Upstream died mid-streamed-response; the client connection is closed rather than silently truncated (`uri=`, `upstream=`, `cause=`). |
| `upstream.response_timeout` | Upstream exceeded `upstreamResponseTimeout` for a response. |

### health
| Event | Emitted when |
| --- | --- |
| `upstream.circuit_opened` / `circuit_half_opened` / `circuit_closed` | Circuit-breaker transitions per upstream. |
| `upstream.test.invalid` / `not_found` / `probe_empty` | `test-upstream` command edge outcomes. |
| `dns.pipeline_unresponsive` / `dns.relay_restarted` / `dns.transports_reset` | DNS forwarder self-healing actions. |

### config
| Event | Emitted when |
| --- | --- |
| `config.routing_changed`, `config.logging_changed`, `config.metadata_changed`, `config.proxy_limits_updated`, `config.dns_restart`, `config.health_restart`, `config.proxy_restart`, `config.proxy_restart_failed`, `config.strict_mode_pac_refresh`, `config.tunnels_reconcile`, `config.tunnels_reconcile_rejected`, `config.upstreams_refresh`, `config.upstreams_deferred` | Per-subsystem outcomes of a config reload. The set grows with the targeted-reload work; treat unknown `config.*` names as informational. |

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
