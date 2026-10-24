# Runtime client: stage-1 inventory and review gates

Checkpoint: 2026-10-24, before AppState adopts the client. This is an inventory and
measurement plan, not an additional accepted decision or a claim of release
completion. Decisions 0013–0026 record the selected shapes and separate implementation status.

## Implementation status

Foundation merged in PR #220 (`fd630d1`), with hosted Swift/CodeQL checks passed:

- Typed `lifecycle.*` events, four names: the `RuntimeEvents` values, the kernel `RuntimeEvent.typed` field, the producers in `LifecycleLane`, the termination drain and `AppUpdates`, the wire projection and the strict or unknown wire record.
- The `ControlRuntime*` value types, the v2 envelope (version 2, separate from v1's version 1) and its frame codec, which writes `Date` values as epoch seconds on the scale of `ControlTimestamp`, plus pages and the snapshot projection.
- The `RuntimeClient` protocol (`submit`, `lookupAdmission`, `outcome`, `subscribe`, `readPage`, `readSnapshot`) with its deadline, subscription and client-error types. Each v2 message carries a correlation ID, and the stamps and page requests name the incarnation they read.

The framed adapter is implemented on `codex/framed-runtime-client`: the v2 codec
runs over an injected byte transport, with explicit limits/deadlines, one-send
mutation error mapping and single-pull stream handles. Its package factory returns
the existing `RuntimeClient` protocol; the concrete adapter remains private.
See [the adapter checkpoint](runtime-framed-client-2026-10-24.md) for source and
verification evidence. It is not an in-memory service or production transport.

Not implemented: the admission/lookup/subscription engine, the production v2
socket, the combined configuration commit/start workflow and AppState adoption.
Request lookup and admission are exercised through scripted/simulated transports;
actual host behavior remains unverified. V1 control and helper IPC are unchanged,
and no production peer uses v2.

The shared-host extraction merged in PR #221 (`3d566d8`) and added ConduitRuntime, with its own [verification checkpoint](verification-runtime-host-extraction-2026-10-24.md). AppState still runs its twin; this inventory does not claim client adoption.

Selected for private configuration: one full frozen request (0018), capped at eight
MiB and refined by domain/startup bounds (0021–0022). Its explicit codec and
[domain bridge](../Sources/ProxyControlBridge/PrivateConfigurationBridge.swift) are
implemented through PR #227/#228; global single-body admission and independent
Stop/status capacity remain adoption obligations.
Not selected: ordinary v2 frame/page/queue/retention limits. The v1 16 KiB frame (`ControlSocket.maxFrameBytes`) is retained. The design's 16 KiB v2 figure and 64-row pages remain review inputs.

Open gates: verified component receipts and the selected mixed-apply gate (0025),
complete writer adoption under the selected canonical root (0020), listener
handoff, measured admission/capacity/latency and total shutdown. External-file
edit conflicts remain an owner decision before expected-prior store checks. No
registry is selected. Runtime and sidecar input/staging boundaries merged in
PR #228/#230; the runtime replacement/read-back primitive/model merged in PR #229.
These foundations are not the asynchronous store.

## Focused evidence

Focused runs reported on the uncommitted tree: 127 codec tests and 287 event tests. The simulator scenarios carry 7 lifecycle and 15 update assertions. These are focused counts, not a full gate run. The corrected combined foundation subsequently passed all 39 workflow-equivalent gates, including 2,506 tests (two skips), 85 simulator results and perf; exact identity, review repairs and limits are in the [verification checkpoint](verification-runtime-client-foundation-2026-10-24.md).

## Lifecycle model evidence

`Tests/ConduitTests/LifecycleLaneModelTests.swift` runs an independent reference model against the production `LifecycleLane` in `PlatformMac`:

- Breadth-first exploration to depth 6, with `maxHeld` 3, `maxWaiters` 2 and a 20,000-state budget: 904 states and 2,628 histories. 531 states were new at the depth bound, so the search did not reach a fixed point. The result is a bound at depth 6, not an exhaustive proof.
- Seeded histories: 200 fixed seeds, 40 steps each, beyond the breadth-first depth.
- Adapter-level fault injection: four injected faults, with shortest witnesses of 1, 2, 2 and 2 steps. These faults sit in the adapter the test drives. They are not mutations of the production source.
- Cleanup: passing and fault tests release the operations they hold. The harness cannot force a corrupted checked continuation awake, so that failure mode is not exercised.

This does not cover every Task or NIO schedule, and it does not resolve sanitizer issue [#118](https://github.com/srps/Conduit/issues/118).

## Historical raw persisted-configuration probes

`Tests/ConduitTests/RuntimeConfigSizingTests.swift` measures the raw persisted `ProxyConfig` encoding. It is input evidence only. It is not the size of the subsequently selected private request or of a full framed command. These are foundation-era observations before decisions 0018–0022, not current largest-valid measurements.

| Fixture | Raw bytes | Validation at the foundation checkpoint |
| --- | ---: | --- |
| `default` | 1,849 | boundary-valid |
| `large_valid` | 11,482 | boundary-valid |
| `long_strings` | 17,977 | boundary-valid |
| `escaping` | 11,563 | boundary-valid |
| `high_count` | 21,212 | boundary-valid |

- These are five measured points, not a largest-valid claim. Item counts alone do not prove a byte bound.
- Two raw fixtures (`long_strings`, `high_count`) exceed the v1 16 KiB frame, so a full-config command cannot use that frame unchanged. Decisions 0018–0022 subsequently selected one private frame capped at eight MiB with domain limits; chunking is not the selected shape.
- The raw encoding carries URL fields that can hold tokens. The fixtures use artificial tokens. The encoding is private data and does not cross the control wire as it is.

## Presentation coverage

The source inventory is `RuntimePresentationAdapter` and
`ProxyOrchestratorSnapshot`, with view/preflight reads checked separately. The
existing v1 `ControlDaemonStatus` is insufficient and remains compatible.

| Source group | v2 representation obligation |
| --- | --- |
| Proxy runtime state, active upstream, health summary; DNS/tunnel run states and errors | Authoritative scalar snapshot; stable typed states and sanitized diagnostic text |
| Proxy, SOCKS, PAC, DNS and transparent-proxy actual bindings | Scalar actual endpoints; derive intercept readiness and local PAC address from these values |
| Direct-mode cause | One typed cause; derive the boolean rather than transmit a separately writable flag |
| VPN state/interface, flap count/duration/time, preserved streams | Scalar observed state and raw metrics, including unknown state |
| Auth outcome/time/fallback reason | Scalar observed result, independent of configured auth mode |
| Request/error/recovery, DNS/DoH/cache and tunnel counters, uptime | Raw cumulative values; UI reset baselines remain local |
| Active connections, upstream health, tunnel bindings and tunnel-DNS hostname/result lists | Complete revision-qualified pages with totals, continuation and explicit stale/unavailable results |
| Activation preflight and helper observation | Bounded freshness/config/incarnation-qualified observation; no synchronous helper probe on snapshot reads |
| Per-surface applied state | Explicitly unavailable until the corresponding #194 implementation; never inferred from a saved flag |

Editor drafts, UI selection/windows, counter reset baselines, credential enrollment,
helper installation, update administration and AppKit actions remain app-owned.
The bridge maps kernel values into independent control values; it does not import
PlatformMac just to obtain a preflight value type.

## Configuration input classification

`ProxyConfig` is not a safe control DTO. Its absence of password fields does not
make all of its values suitable for ordinary Codable control messages.

- Numeric/boolean/enum settings and ordinary endpoint/identity fields can be
  projected deliberately. Identity is coupled to credential selection:
  `CredentialManager` keys an account by domain, username and profile name.
- PAC, health-check and DoH URLs can contain query tokens. PAC currently rejects
  userinfo, which does not establish that other URL fields or query strings are
  safe. Keep sensitive inputs private; do not reject existing query-bearing
  configurations as an incidental transport refactor.
- Decisions 0021–0022 now bound the inventoried configuration collections and
  identity/display/host/path/URL strings through one resource policy. Runtime
  semantics and stricter existing grammars remain at their owning gates. This
  inventory introduces no additional count or scalar ceiling.
- Config, platform integration and UI preferences persist separately. Config
  plus platform settings can jointly determine a machine effect; preferences
  remain separate. Receipts describe exact verified component values, not a
  transaction across files, Keychain and machine surfaces.

The selected shape is one private, explicitly encoded request containing the full
frozen configuration (0018), rather than separate public/private halves. Values
stay out of ordinary events/status. Save-before-apply requires exact immutable
input; it does not require a snapshot registry. The registry alternative was
rejected because it adds retention/expiry and exact-value transfer obligations.
Stop/Quit policy remains independent.

## Bounds and measurement

V1 remains 16 KiB. The design's 16 KiB v2 figure, 64 rows/page and other example
values are review inputs, not selected shipping defaults. Item counts alone do
not prove a byte bound. Pages must obey encoded bytes and guarantee either
progress or an explicit oversized-row result; totals cannot become sample sizes.

Claude's initial inventory used hand arithmetic. Those historical estimates do not
prove that a baseline or page fits. The accepted configuration limits are recorded
separately in 0021–0022, with startup grammar and sidecar caps in 0024/0026.
Executable fixtures must identify the exact source schema, encoder/envelope,
input configuration, validation result and encoded byte count. Measure defaults,
representative larger configurations, long strings/counts and JSON escaping.
Raw persisted-config sizes remain historical input, not measurements of the actual
private-frame pipeline, active host workload or maximum process memory.

Frame/parser/queue/retention limits are explicit configuration in the contract
foundation. Their shipping values need measured fixtures and owner review.
Unknown/expired/capacity outcomes remain explicit; boundedness is not a claim
that every field at its individual maximum fits a single finite frame. The actual
encoded-byte cap is enforced separately.

## Event migration inventory

Live `lifecycle.*` producers include superseded, coalesced,
termination_drain_expired **and version_changed** (AppUpdates). The fourth producer
was missed by the initial three-name inventory and is included in the merged
foundation. All four emitted names now use typed values across producer, codecs,
bridge and assertions. Other families remain legacy and the global catalogue is
still hand-maintained. `lifecycle.crash_restart` is catalogued as planned,
not an emitted event. Migrated names derive metadata from typed fields; the
legacy producer must refuse the closed namespace, including dynamically formed
names. Historical records can remain readable without inventing typed evidence.

The independent LifecycleLane model drives the production lane. It reports its
actual exploration bounds/coverage and tests injected adapter defects. This does
not prove all Task or NIO schedules or resolve sanitizer issue #118.
