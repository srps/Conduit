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
| `daemon.ready` | Daemon runtime host finished startup (`detail: mode=…`). Emitted after launch recovery has finished, so a consumer never sees readiness while a crashed run's settings are still being handed back. |
| `platform.launch_recovery_restored` | Launch-time crash recovery found a surface a run that never tore down left applied, restored the journal's recorded prior values and released it (`surface=systemDNS` or `surface=systemProxy`, `stale=true` when the records were over 7 days old and were restored without a liveness probe). One event per surface per launch from both hosts, in the order system DNS, system proxy, resolver files. Emitted before the log line. |
| `platform.launch_recovery_nothing_to_do` | Recovery had nothing to act on for a surface (`surface=`, `reason=` one of `nothing_recorded`, `already_settled`, `fresh_install`, `no_journal`). |
| `platform.launch_recovery_declined` | Recorded state exists, but a local listener is still serving it, so another session owns the machine and it was left alone (`surface=`, `reason=live_listener`). |
| `platform.launch_recovery_discarded` | System DNS: a resolver answers on `:53` but no interface points at loopback any more, so the records described nothing and were dropped without a write (`surface=systemDNS`, `reason=no_interface_points_at_loopback`). |
| `platform.launch_recovery_adopted` | The one-time resolver-file scan on the first launch of a release that records resolver files (`surface=resolverFile`, `adopted=`, `removed=` whether adopted files were removed because the switch is off, `foreign=` files with other contents left alone, `unjudged=` entry files left in place). |
| `platform.launch_recovery_skipped` | A recovery step was not attempted (`surface=`, `reason=config_unavailable` when the config failed to load, which only the resolver scan needs; `reason=journal_unreadable`). The daemon emits these to `events.ndjson` even when it then exits on a bad config. |
| `platform.launch_recovery_failed` | A restore threw, or part of it did not land and the records were kept for the next launch to retry (`surface=`, `reason=` the error, or `records_kept`). |
| `lifecycle.superseded` | A start or stop stopped short, because a later start or stop had begun in the meantime (`reason=superseded`) or, for a proxy start, the listeners it started were down by then (`reason=runtime_down`). Checked after each suspension; inside its platform work the operation also stops before its next manager step. The later operation owns the surfaces; its work was queued behind this one's. `detail: operation=proxy_start\|proxy_stop\|dns_start\|dns_stop\|runtime_start\|runtime_stop generation=… current=… reason=…`. |
| `lifecycle.coalesced` | A start or stop arrived while the same kind of operation was the latest and still running, and joined it instead of queueing a second copy of its platform work (`detail: operation=… joined=<generation>`). |
| `lifecycle.termination_drain_expired` | The app's quit waited `deadline_ms` for the platform queue and went ahead with its clears; a step still running is serialised with them by its manager's lock (`detail: deadline_ms=…`). |
| `lifecycle.crash_restart` *(planned)* | First startup after an unclean exit; detail references prior exit evidence and the matching crash-report name. |
| `lifecycle.update_restart` *(planned)* | Restart performed by the in-app updater. |

### routing
| Event | Emitted when |
| --- | --- |
| `direct_mode.entered` | Routing flipped to direct (`detail` carries the cause). |
| `local_pac.starting` / `started` / `stopping` / `stopped` / `restarting` / `updated` / `failed` | Local PAC server lifecycle; `detail: reason=…`. |
| `pac.refreshed` | The routing engine installed a freshly fetched PAC (`url=`, credentials stripped). The first install after a `pac.routes_invalidated` adds `after=` with its reason and logs at notice, so the app's `proxy.log` shows the reload. A different script drops every cached answer. The same script as the one loaded ends the detail with `script=unchanged` and keeps them: each is served on its next use and evaluated again in the background. |
| `pac.preview_completed` | Settings evaluated a PAC for a validated Browser Test URL; `target=` and `chain=` describe the answer also shown beside Preview PAC. Evaluation runs off the main thread, with one preview in flight. |
| `pac.preview_failed` | Settings rejected the diagnostic URL or failed to fetch/evaluate the PAC. The error text is also shown beside Preview PAC. An invalid target is rejected before fetching. |
| `pac.refresh_wait_refused` | A caller found a PAC refresh running with 64 callers already waiting on it (`limit=`), so it went on without waiting for the outcome. Only control-plane callers wait, so this marks a runaway caller. |
| `pac.refresh_failed` | A PAC fetch or compile failed; `detail` is the error text. The last working evaluator stays in place, unless `pac.routes_invalidated` dropped it. A fetch that started before a `pac.routes_invalidated` and failed after it ends its `detail` with `superseded=refetching`: it does not count towards the backoff, and the fetch is retried on the new network. |
| `pac.refresh_backoff` | A path-triggered refresh was skipped because the URL is in failure backoff (`failures=`, `remainingSeconds=`). Wake, VPN connect and disconnect, user action and a changed URL bypass it. |
| `pac.routes_invalidated` | The routing engine dropped every answer computed on the network that just changed: the route cache and any evaluation in flight (a background re-evaluation included), and for a VPN transition the loaded script. `reason=vpn_connected` (the VPN came up, at cold start or after an outage), `vpn_disconnected` (it went down for good; a flap does not invalidate) or `network_changed` (a material `network.path_changed`, not the first path); `routes=` cached routes dropped; `script=dropped`, `kept` (`network_changed`: requests are evaluated afresh by the loaded script while it is fetched again) or `none`; `fetch=restarted` when a fetch was running (it installs nothing and fetches again) or `idle`. A forced PAC fetch follows; after a VPN transition it ignores the backoff, after a path change it honours it and is skipped on an unsatisfied path. Until a script loads, requests go through the configured upstreams as `pac.no_usable_route reason=not_loaded`. Only emitted while PAC routing is on; logged at notice. |
| `pac.evaluation_slow` | Running the PAC script for a request took over 500 ms (`host=`, `ms=` the script's own run, not the wait for the evaluator queue, `suppressed=`). At most once per host every 10 minutes, from a table of at most 64 hosts; `suppressed` counts the slow evaluations of that host held back since the previous event. The warning line (`PAC evaluation took Nms for <host>`) is derived from it. A cached answer is served for up to 10 minutes and evaluated again in the background once it is a minute old, so a slow host costs a request its wait only on its first request and after an invalidation. |
| `pac.revalidation_failed` | A background re-evaluation of a cached answer failed or timed out, with no request waiting on it (`host=`, `reason=evaluation_failed` or `timeout`, `suppressed=`). The cached answer goes on being served until its 10 minutes are up and is tried again a minute later. Not emitted when a `pac.routes_invalidated` or a refresh with a different script dropped that answer while the re-evaluation ran. At most once per host every 10 minutes (same table as `pac.evaluation_slow`); logged as a warning. |
| `pac.evaluation_refused` | The PAC evaluation queue was full, so a request was answered without evaluating (`host=`, `reason=queue_full` or `waiters_full`, `limit=`). The request is also a `pac.no_usable_route` with `reason=refused`. |
| `pac.no_usable_route` | PAC routing is on but gave a request nothing to route by, so it went through the configured upstreams only: no DIRECT, no direct-reachability shortcut, no PAC direct fallback (`reason=`, `host=`, `rejected=`, `suppressed=`). `reason` is `empty` (no entries, including every entry CFNetwork drops: `HTTPS`, `HTTP`, `SOCKS5`, `QUIC`, unknown words, `""`), `unsupported` (every entry rejected, at least one of a type Conduit cannot use, such as `SOCKS`), `invalid` (every entry rejected for a bad host or port), `evaluation_failed`, `timeout`, `not_loaded` (no script loaded yet), `refused` (see `pac.evaluation_refused`) or `superseded` (the answer came from a PAC the configuration no longer names, or was computed before a `pac.routes_invalidated`). Also emitted with `unsupported`/`invalid` when the only usable entry was a `DIRECT` that followed rejected entries and strict mode suppressed it as a fallback. `rejected` lists the rejected entry types, at most 8, never a host or URL. A chain keeps only its first 8 rejected entries; when it had more, `rejectedTotal=` gives the count (the reason still accounts for all of them). At most one event per reason per minute; `suppressed` counts the requests held back since the previous one. |
| `routing.strict_direct_reachable` | In strict mode a request failed through the upstream (502), and a single direct probe of its target answered (`host=`, `port=`, `hint=add_to_no_proxy_hosts`). The request still failed; nothing is retried directly. Add the host to No-proxy hosts if it should bypass the proxy. At most one probe, and one event, per host every 10 minutes, and at most 4 probes in flight (further hints are skipped). No probe runs while routing is changing under the proxy; see `routing.strict_direct_reachable_suppressed`. The probe follows the direct path's metadata/loopback policy: in gateway mode a blocked host, or one that resolves to a blocked address, is never connected to and gets no hint. |
| `routing.strict_direct_reachable_suppressed` | In strict mode a request failed through the upstream (502), but no hint probe ran because routing was changing under the proxy, so the failure says nothing about the host (#97). `reason=flap` during a VPN flap hold (`.reasserting`), `direct_mode` while in direct mode, `vpn_transition` while a VPN connect or disconnect is being handled and for 15 s after it, or after a direct-mode change such as upstreams recovering. Also `host=`, `port=` of the failure that emitted it, and `suppressed=` the failures not probed for that reason and transition since the last event, this one included. One event for the first suppressed failure of each reason and transition, then at most one a minute while it lasts; the log line (info) is derived from the event. A suppressed host is not put on its hint cooldown, so its next failure after the window is probed. |
| `routing.probe_blocked` | In gateway mode a direct probe refused to connect under the metadata/loopback blocklist, so its target counts as not directly reachable (`host=`, `port=`, `kind=reachability` for the non-strict reachability shortcut or `strict_hint` for the strict-mode hint, `reason=blocked_name` when the host itself is blocked or `blocked_address` with `address=` when it resolved or connected to a blocked address). Nothing was connected to. At most one event per host every 10 minutes, from a table of at most 256 hosts; the log line is derived from the event. |

### auth
| Event | Emitted when |
| --- | --- |
| `auth.kerberos_succeeded` | Initial Kerberos leg produced a token (`host=`). |
| `auth.kerberos_fallback_ntlm` | Credential-class Kerberos failure downgraded to NTLM (`host=`, `reason=` one of `no_credential`, `credentials_expired`, `bad_mech`, `failure`, `no_ticket`, `service_ticket_unavailable`, `routine_<n>`; then the GSS codes `major=`, `minor=` (signed, as Kerberos errors are written) and, when the minor is a known Kerberos error, `krb5_error=` such as `KRB5KDC_ERR_S_PRINCIPAL_UNKNOWN` or `KRB5_KDC_UNREACH`; then `suppressed=`). At most once a minute for each host and reason; `suppressed` counts the fallbacks held back since the previous one. The NOTICE log line is derived from the event and follows the same limit; the snapshot's `lastAuthFallbackReason` still follows every fallback. SPNEGO often reports `minor=0` for a Kerberos-mech failure, which names nothing. So for `service_ticket_unavailable`, Conduit makes one diagnostic `gss_init_sec_context` against the raw Kerberos mech for the same SPN, inside the GSS gate, and reports its answer as `krb5_major=` and `krb5_minor=`, with `krb5_error=` naming the mech's minor (not SPNEGO's). If that call could not be made, it reports `krb5_probe=failed`. The diagnostic call costs a TGS request, so it runs at most once per host a minute, only while the host is failing. A fallback event whose failure was not probed has no `krb5_` fields. The call never changes the handshake's outcome or the NTLM fallback, and its token is discarded unread. |
| `auth.kerberos_failed` | A Kerberos failure reached the request with no NTLM answer: no saved password, a failure that permits no fallback, or a continuation token GSS rejected (`host=`, `reason=` as above, plus `other`; then `major=`, `minor=` and the `krb5_` fields as above when the failure has GSS codes; then `suppressed=`). At most once a minute for each host and reason; `suppressed` counts the failures held back since the previous one. Not emitted while a missing credential is being retried; `auth.credential_retry` covers that. |
| `auth.ntlm_configured` | NTLM credentials became available to the authenticator stack. |
| `auth.credentials_unavailable` | The saved NTLM password could not be read (`reason=` one of `not_found`, `denied` for a refused or dismissed Keychain prompt, `interaction_not_allowed` for a prompt that could not be shown, `invalid_payload`, `read_pending` when a handshake gave up after 2 s waiting for a read that is still out, typically behind an unanswered Keychain prompt, `status=<n>` for any other Keychain status, or `other`). `source=handshake` with `host=` when a handshake needed it: the NTLM fallback then goes without NTLM, and NTLMv2 mode fails the request. At most once a minute for each host and reason; `suppressed=` counts the reads held back since the last event. `source=proxy_start` when the read at proxy start failed; that read happens only when a password is saved. A missing password is reported here only in NTLMv2 mode; for the fallback, `auth.kerberos_failed` covers it. |
| `auth.credentials_dropped` | The upstream answered the NTLM authenticate leg with another 407, so the cached password was dropped and the next handshake reads it again (`host=`, `reason=rejected`). At most once a minute, so a wrong password does not become a Keychain read per request. |
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
| `upstream.tunnel_failed` / `upstream.exchange_failed` | A CONNECT tunnel or an HTTP exchange through the upstream failed and the client got a 502 (`target=`, `reason=`). Emitted before the error log line. Not emitted for a failure the cause makes expected (a transient path change), which is logged at info, nor for a request the pool refused locally, which never reached the upstream: exhaustion is `connection.pool_exhausted`, a handshake-limit refusal is `auth.handshake_rejected`. Coalesced like `direct.connect_failed`. |
| `connection.upstream_invalid_response` | The upstream's reply to a CONNECT could not be framed (malformed status or fields, signed/overflowing/duplicate/conflicting lengths, unsupported transfer coding, bad chunking, or a head over 64 KiB) (`upstream=`). The attempt fails and the connection is closed. Emitted before the warning log line. |
| `connection.pool_exhausted` | The connection pool refused a request at its `maxConnections` cap and the client got a 502 (`target=`, `reason=`). Emitted before the error log line; a local refusal is loud even during a transient path change, which demotes upstream failures to info. |
| `direct.connect_failed` | A direct connect the request was routed to failed unexpectedly (`target=`, `reason=`, `kind=`: `dns`, `refused`, `timeout`, `unreachable`, `link_local_recent`, `blocked` or `other`). Direct failures while the VPN is off, and repeats of a remembered link-local timeout, are info log lines only. Coalesced per listener by target and `kind`: the first failure is reported, repeats within 60 s are counted, and one summary with `suppressed=N windowSeconds=60` follows when the interval closes; at most 256 target/kind pairs are tracked, and an evicted pair reports its count first. The log line carries the same `suppressed=N`. |
| `direct.link_local_refused` | A direct connect to a link-local literal was refused at once because one timed out within the last minute (`target=`, `secondsAgo=`). Emitted once per remembered timeout; later refusals in the same minute are counted in the coalesced log line only. A dial started while another to the same target is in flight waits for it and is refused with it if it times out, or dials on its own if it does not. |

### health
| Event | Emitted when |
| --- | --- |
| `upstream.circuit_opened` / `circuit_half_opened` / `circuit_closed` | Circuit-breaker transitions per upstream. |
| `upstream.test.invalid` / `not_found` / `probe_empty` | `test-upstream` command edge outcomes. |
| `dns.pipeline_unresponsive` / `dns.relay_restarted` / `dns.transports_reset` | DNS forwarder self-healing actions. |
| `dns.listener_port_retry` | The forwarder was started on port 0, got an ephemeral UDP port, and found the TCP port of the same number held by another socket; it released the UDP port and is binding the pair again on a fresh one (`port=` the port given up, `attempt=`, `of=`, `reason=tcp_port_in_use`). Emitted before the log line. |
| `dns.listener_port_release_failed` | During a port-0 rebind the forwarder could not close the UDP port it was giving up (`port=`, `attempt=`, `error=`). The start fails rather than binding a second pair beside a socket that may still answer; `stop()` closes it again. Emitted before the log line. |
| `dns.tcp_listener_unavailable` | The forwarder has no TCP listener. `outcome=udp_only`: the TCP bind failed on a configured port, or for a reason another port would not cure, and the forwarder serves UDP only (`port=`, `error=`). `outcome=start_failed`: started on port 0, no port was free on both UDP and TCP within the attempt budget, and the start failed (`port=` the last one tried, `attempts=`). Emitted before the log line. |
| `network.path_changed` | A debounced network-path update changed a material field (status, the set of interfaces by name and type, the set of gateways, IPv4/IPv6/DNS support) since the last one acted on, with what it decided (`satisfied=`, `dns=reset|idle`, `pac=refresh|skipped_unsatisfied`), `changed=` the fields (`status`, `interfaces`, `gateways`, `supports_ipv4`, `supports_ipv6`, `supports_dns`) or `initial` for the first path, `unchanged_before=` the unchanged updates since the last change, one `<field>=<old>-><new>` token per changed field, and `path=` the description (last, free text). Emitted before the NOTICE log line and before the actions it names. The host's system DNS reconcile is not gated by it: it runs for every path report, changed or not. |
| `network.path_unchanged` | Debounced network-path updates changed nothing material, so the DoH transports were kept and the PAC was not refetched (`count=` unchanged updates since the last change, `dns=kept`, `pac=skipped`, `path=`). The host's system DNS reconcile still runs for each of them, since a VPN client can rewrite service DNS with no material path change. Expensive/constrained flips count as unchanged. Coalesced: emitted at counts 1, 2, 4 … 64 and then every 64th, so a churning path costs a few events a day; the next `network.path_changed` carries the full count. Emitted before its NOTICE log line. |
| `error_rate.alarm` | The recent-failure window crossed the alarm threshold (`failures=`, `windowSeconds=`); the window is drained and the alarm holds off for 30 s. Only failures that implicate an upstream count: a direct route's origin failure (DNS, refused, timeout), a client hang-up and a local refusal are counted in the metrics but never fill the window. |
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
