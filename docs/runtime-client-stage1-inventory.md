# Runtime client: stage-1 inventory and review gates

Checkpoint: 2026-10-24, before AppState adopts the client. This is an inventory and
measurement plan, not an additional accepted decision or a claim of release
completion. Decisions 0013–0015 remain the authority.

## Implementation status (branch foundation)

Implemented on this branch; not merged at this checkpoint:

- Typed `lifecycle.*` events, four names: the `RuntimeEvents` values, the kernel `RuntimeEvent.typed` field, the producers in `LifecycleLane`, the termination drain and `AppUpdates`, the wire projection and the strict or unknown wire record.
- The `ControlRuntime*` value types, the v2 envelope (version 2, separate from v1's version 1) and its frame codec, which writes `Date` values as epoch seconds on the scale of `ControlTimestamp`, plus pages and the snapshot projection.
- The `RuntimeClient` protocol (`submit`, `lookupAdmission`, `outcome`, `subscribe`, `readPage`, `readSnapshot`) with its deadline, subscription and client-error types. Each v2 message carries a correlation ID, and the stamps and page requests name the incarnation they read.

Not implemented: the in-memory client and its admission, lookup and subscription engine; the production v2 socket; a config commit or start DTO; a `ConduitRuntime` target; AppState adoption. Request lookup and admission exist only as protocol shapes, so their behavior is unverified. v1 control, helper IPC and the installed helper are unchanged, and no production peer uses v2.

Not selected: shipping numeric limits for frames, pages, queues or retention. The v1 16 KiB frame (`ControlSocket.maxFrameBytes`) is retained. The design's 16 KiB v2 figure and 64-row pages remain review inputs.

Open owner gates: config projection and coupling, listener handoff, and measured bounds and shutdown. No registry is selected.

## Focused evidence

Focused runs reported on the uncommitted tree: 127 codec tests and 287 event tests. The simulator scenarios carry 7 lifecycle and 15 update assertions. These are focused counts, not a full gate run. The corrected combined foundation subsequently passed all 39 workflow-equivalent gates, including 2,506 tests (two skips), 85 simulator results and perf; exact identity, review repairs and limits are in the [verification checkpoint](verification-runtime-client-foundation-2026-10-24.md).

## Lifecycle model evidence

`Tests/ConduitTests/LifecycleLaneModelTests.swift` runs an independent reference model against the production `LifecycleLane` in `PlatformMac`:

- Breadth-first exploration to depth 6, with `maxHeld` 3, `maxWaiters` 2 and a 20,000-state budget: 904 states and 2,628 histories. 531 states were new at the depth bound, so the search did not reach a fixed point. The result is a bound at depth 6, not an exhaustive proof.
- Seeded histories: 200 fixed seeds, 40 steps each, beyond the breadth-first depth.
- Adapter-level fault injection: four injected faults, with shortest witnesses of 1, 2, 2 and 2 steps. These faults sit in the adapter the test drives. They are not mutations of the production source.
- Cleanup: passing and fault tests release the operations they hold. The harness cannot force a corrupted checked continuation awake, so that failure mode is not exercised.

This does not cover every Task or NIO schedule, and it does not resolve sanitizer issue [#118](https://github.com/srps/Conduit/issues/118).

## Measured raw persisted configuration

`Tests/ConduitTests/RuntimeConfigSizingTests.swift` measures the raw persisted `ProxyConfig` encoding. It is input evidence only. It is not the size of a v2 value, of a secret-free commit envelope, or of a full command payload, and none of those is defined yet.

| Fixture | Raw bytes | Validation |
| --- | ---: | --- |
| `default` | 1,849 | boundary-valid |
| `large_valid` | 11,482 | boundary-valid |
| `long_strings` | 17,977 | boundary-valid |
| `escaping` | 11,563 | boundary-valid |
| `high_count` | 21,212 | boundary-valid |

- These are five measured points, not a largest-valid claim. Item counts alone do not prove a byte bound.
- Two raw fixtures (`long_strings`, `high_count`) exceed the v1 16 KiB frame, so a full-config command cannot use that frame unchanged. Whether it takes a larger v2 frame or chunked transfer is an owner choice.
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
- Profile labels, upstream names/hosts, DNS entries, tunnel labels/remote hosts
  and several collection counts have no complete current validation ceiling.
  `maxConnections` also has no upper ceiling. New count/string restrictions are
  not approved by this inventory.
- Config, platform integration and UI preferences persist separately. Config
  plus platform settings can jointly determine a machine effect; preferences
  remain separate. Receipts describe exact verified component values, not a
  transaction across files, Keychain and machine surfaces.

The original preferred shape remains explicit committed safe values with
component receipts/revision checks and private sensitive bindings. A full pinned
config registry was considered and is not selected or implemented. It would add
retention/expiry failures and would still need an exact-value transfer design at
the later daemon boundary. No durable snapshot history is introduced.

The owner favors the future daemon architecture and asks to be told when a
concrete decision is needed. Complete the inventory and measurement work before
bringing back a larger v2 frame versus chunked-transfer choice. Save-before-apply
requires exact immutable input; it does not require a registry. Stop/Quit policy
is independent of this choice.

## Bounds and measurement

V1 remains 16 KiB. The design's 16 KiB v2 figure, 64 rows/page and other example
values are review inputs, not selected shipping defaults. Item counts alone do
not prove a byte bound. Pages must obey encoded bytes and guarantee either
progress or an explicit oversized-row result; totals cannot become sample sizes.

Claude's initial inventory used hand arithmetic. Those estimates do not prove
that a baseline, page or config fits and do not authorize new config limits.
Executable fixtures must identify the exact source schema, encoder/envelope,
input configuration, validation result and encoded byte count. Measure defaults,
representative larger configurations, long strings/counts and JSON escaping.
Raw persisted-config sizes are useful input but are not measurements of a future
secret-free commit envelope that has not been defined yet.

Frame/parser/queue/retention limits are explicit configuration in the contract
foundation. Their shipping values need measured fixtures and owner review.
Unknown/expired/capacity outcomes remain explicit; boundedness is not a claim
that all currently valid unbounded configurations fit a single finite frame.

## Event migration inventory

Live `lifecycle.*` producers include superseded, coalesced,
termination_drain_expired **and version_changed** (AppUpdates). The fourth producer
was missed by the initial three-name inventory. The working tree now types it too,
so all four names emit typed values. The family is not called complete yet: the
catalogue is still hand-maintained, and only the four lifecycle names are typed. `lifecycle.crash_restart` is catalogued as planned,
not an emitted event. Migrated names derive metadata from typed fields; the
legacy producer must refuse the closed namespace, including dynamically formed
names. Historical records can remain readable without inventing typed evidence.

The independent LifecycleLane model drives the production lane. It reports its
actual exploration bounds/coverage and tests injected adapter defects. This does
not prove all Task or NIO schedules or resolve sanitizer issue #118.
