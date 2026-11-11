# Level-triggered VPN detection

Status: units U0 to U2 are implemented. Nothing in the running product uses the new types yet. Units U3 to U6 are an outline and wait on the owner decisions listed at the end.

The owner's requirement is that VPN detection, on or off, is never wrong. This document explains why the shipped monitor cannot meet that requirement, what replaces it, and the order of the migration.

## Why the shipped monitor gets it wrong

`VPNStatusMonitor` is edge-triggered. Each `SCDynamicStore` notification names the keys that changed. The monitor reads those keys, turns each into a per-interface observation, and applies it to a `VPNStateFuser` that accumulates what it has been told. The verdict is correct only if the fuser has been told everything, in order, since the process started.

That condition fails in five ways. An audit of the code found them, and a model check over the shipped logic reproduced them.

| Failure | Cause | Issue |
| --- | --- | --- |
| A tunnel that vanishes while the monitor is stopped stays `.connected`. | `stop()` keeps the fuser. `start()` primes only from the keys present, so the fuser never hears of the removal. | #303 |
| A stop during the debounce or the grace window leaves the state at `.connected` or `.reasserting`. | `stop()` cancels the timers that would have moved the fuser on, and keeps the fuser. | |
| A fast start, stop, start installs two stores. | `installStore()` checks only `started`, so both queued installs run. | #300 |
| An IPv4 key with no addresses turns `.disconnected` into `.unknown`. | The monitor admits any utun with an IPv4 key. The fuser has never seen this one connected and reports that it knows nothing. | |
| A store that cannot be created or subscribed to is silent. | `installStore()` returns with no event and no state. | |

The model check ran every ordering of store changes, timer expiries, stops, and starts to a fixed depth against a transliteration of the monitor that drives the real `VPNStateFuser`. It counted a run as wrong when the settled verdict disagreed with the store. With no restart, 100,842 of 2,000,000 orderings were wrong. With a stop and a start, 49,996 of 303,002 were wrong. A level-triggered prototype had none.

These are not five bugs to patch. Each is the same defect: the verdict depends on a history that the monitor can miss.

## The design

Treat every input as a prompt to read the whole store and reconcile. A notification, a start, a flap deadline, a wake, and a network path change all do the same thing. The verdict is a function of three inputs: the snapshot just read, the clock, and a small timing memory. A missed input costs latency, never correctness, because the next input reads everything again.

### The types

`TunnelSnapshot` (in `ProxyKernel`) lists every `utun` the store names. Each `Tunnel` has an `interface`, its `ipv4Addresses`, `hasRoutableIPv6`, a `serviceID` if a service key names it, `overridesPrimary`, and `hasInterfaceKey`. `hasInterfaceKey` is false for a tunnel that only a service key still names. The timer needs it to tell a removed interface from one that lost its address.

`TunnelSnapshot.parse(store:)` (in `PlatformMac`) is a pure function over one `SCDynamicStoreCopyMultiple` result. It reads `State:/Network/Interface/utun[0-9]+/IPv4`, the matching `IPv6` keys, and `State:/Network/Service/*/IPv4` and `IPv6` keys whose `InterfaceName` is a utun. It has the same shape as `PushedResolverReading.parse`.

`TunnelReading` is `.snapshot(TunnelSnapshot)` or `.failed(Failure)`, where the failure is `storeCreate`, `storeSubscribe`, or `storeRead`. A failure is a value the caller must handle, so it cannot be silent.

`TunnelStoreReading` (in `PlatformMac`) is the store as detection uses it. `read()` returns a `TunnelReading`. `subscribe(queue:onChange:)` returns a subscription or a failure. `onChange` carries no keys, so a subscriber cannot act on a delta. A subscription owns one store session and ends it on `cancel()`, so a session cannot outlive the start that opened it. `SystemTunnelStore` is the `SCDynamicStore` implementation. `FakeTunnelStore` holds keys, parses all of them on every read, signals only while subscribed, can hold or drop signals, and can fail a read or a subscribe.

`VPNUpPredicate` says which tunnels count as the VPN being up. The default, `anyIPv4Tunnel`, is the rule the shipped monitor applies: a utun whose interface IPv4 key lists an address. The predicate is a value passed to the timer, so a narrower rule later is a different predicate and not a different state machine.

`VPNFlapTimer` is the only memory. `reconcile(_:now:window:up:)` takes a reading and the time and returns a `VPNDetection`: the phase, the `VPNObservedState` it maps to, the tunnels carrying a connected state, the live tunnels, and a deadline. The timer remembers three things:

- `lostAt`: when each tunnel that is still in the store stopped counting.
- `counted`: which interfaces counted in the last reading.
- `connectedUntil`: the latest instant the state was connected.

A session creates a new timer on each start. `lostAt` holds entries only for tunnels in the current snapshot, so it cannot grow past the snapshot.

### The statechart

One statechart describes an observation session. The timer computes the phase on every reconcile and never stores it.

| Phase | Condition | State reported | Deadline |
| --- | --- | --- | --- |
| `up` | A tunnel counts. | `.connected` | The next debounce to end, if a lost tunnel is still inside one. |
| `debouncing` | No tunnel counts. A tunnel stopped counting less than `minVisible` ago. | `.connected` | The next debounce to end. |
| `reasserting` | No tunnel counts or debounces. A lost tunnel is still in the store. `connectedUntil` is less than `grace` ago. | `.reasserting` | `connectedUntil + grace`. |
| `down(reason)` | None of the above. | `.disconnected(reason)` | None. |
| `blind(failure)` | The reading failed. | `.unknown` | None. |

The reason for `down` is `networkLost` when a lost tunnel is still in the store, `userInitiated` when the session saw the VPN up and no tunnel is left to recover, and `unknown` when the session never saw the VPN up.

Every comparison is against the clock, not against a count of timer firings. If the wake-up for a deadline is late, the next reconcile reports the phase that the elapsed time implies. If the wake-up never comes, the next input of any kind does the same.

A failed reading leaves the memory untouched. The next reading that succeeds continues from the clock.

### What stays the same

Flap behaviour matches the shipped monitor. A loss shorter than `minVisible` is silent. A loss that recovers inside `grace` reports connected, reasserting, connected. A loss that outlasts `grace` reports `.disconnected(.networkLost)`. A removed interface reports `.disconnected(.userInitiated)` at once, with no window. Grace runs from the moment the state stopped being connected, which is why `connectedUntil` exists: with two tunnels, the tunnel that ended the connected state may be gone from the store by the time grace is measured.

## How the equivalence is tested

`VPNFlapTimerModelCheckTests` holds both checks. Both run a small store model: two tunnels that can be absent, IPv6-only, addressed, or holding an IPv4 key with no addresses, beside a service tunnel that never changes.

The exhaustive check runs every ordering of twelve operations to depth 5 from two starting stores: 497,664 orderings and 542,906 intermediate states. The operations are seven store changes, three waits (inside `minVisible`, inside `grace`, past both), a restart, and a toggle that loses notifications. After every operation it asserts five properties:

- Convergence. After every deadline has run, the state is `.connected` exactly when a tunnel counts. A tunnel that counts is reported at once. A readable store never reads `.unknown`.
- Idempotence. The same reading at the same time, twice, returns the same detection and leaves the same memory.
- Restart equivalence. A new timer on the current store settles on the same state as the timer that watched the store get there.
- Notification loss. After any number of lost notifications, one more reading restores convergence.
- Blindness. A failed reading reports `.unknown` and leaves the memory untouched.

The differential check runs every ordering of the store changes and the waits to depth 6 from three starting stores, with no restart and every notification delivered. It drives a transliteration of `VPNStatusMonitor` over the real `VPNStateFuser` and a session over `VPNFlapTimer` on the same virtual clock. The state changes, the times of those changes, the connected interface, and the live set must be equal. 2,631,072 orderings are equal.

### Where the timer and the fuser differ

The differential check leaves out one class of ordering. The exhaustive check still covers that class.

| Situation | Shipped monitor | Timer | Why the timer is right |
| --- | --- | --- | --- |
| An IPv4 key with no addresses appears on a tunnel that has had no address since the session began. | `.unknown`, or `.disconnected(.networkLost)` beside a removed tunnel. Removing the key later reports `.disconnected(.userInitiated)`. | No change. | The store shows no addressed tunnel, so the VPN is down. `SplitDNSVPNGate` reads `.unknown` as "assume connected", so the shipped answer can install entry files off VPN. |

Three differences fall outside what the differential check models:

- A notification that names two tunnels. The shipped monitor applies the keys one interface at a time in dictionary order and can report an intermediate state. The timer reads both at once.
- A late timer. The shipped monitor moves on only when its `DispatchWorkItem` runs. The timer reports the phase the clock implies, so it can skip `.reasserting` after a long stall.
- A change to `minVisible` or `grace` during a flap. The shipped monitor applies the new value to the next timer it arms. The timer applies it to the flap in progress.

## Migration units

Each unit is one pull request that leaves the product working.

| Unit | Change | Product behaviour |
| --- | --- | --- |
| U0 | `pm-vpn-check --snapshot` and `--watch` dump the masked store, so real Cisco Secure Client transitions become parse fixtures. | None. |
| U1 | `TunnelSnapshot`, `TunnelReading`, `parse`, `TunnelStoreReading`, `SystemTunnelStore`, `FakeTunnelStore`, `VPNUpPredicate`, `VPNFlapTimer`. | None. |
| U2 | The exhaustive check and the differential check. | None. |
| U3 | A level-triggered `VPNStatusObserving` over `TunnelStoreReading` and `VPNFlapTimer`. Each `start` gets a new timer, a new subscription, and a generation that late callbacks are checked against. A failed reading emits an event. | Fixes the five failures. Needs decisions 1 and 2. |
| U4 | The hosts and `pm-sim` compose the new monitor. Scenarios cover a stop during a flap, a tunnel removed while stopped, and a lost notification. A decision record lands here. | Same as U3, now exercised end to end. |
| U5 | Delete `VPNStateFuser`, the edge-triggered monitor, and the differential check that compares against them. | None. |
| U6 | Reconcile on wake and on a path change, add the periodic audit read, and add the VPN-service selector. | Needs decisions 3, 4, and 5. |

U3 to U6 are an outline. The owner approved U0 to U2 only.

## Open decisions

U0 to U2 do not depend on these. The types already express each option.

1. **Flap memory across a stop.** Recommended: drop it. A session creates a new `VPNFlapTimer`, so a stop during a flap restarts as whatever the store shows. Keeping the timer across a stop is also expressible, but it brings back a verdict that depends on what happened while nobody was reading.
2. **What `.unknown` means for split DNS entry files.** Recommended: withhold them. `SplitDNSVPNGate` reads `.unknown` as "assume connected" today. With the timer, `.unknown` arises only from the `blind` phase, when the store cannot be read.
3. **IPv6-only tunnels.** Recommended: report them, do not count them. `hasRoutableIPv6` is in the snapshot and `anyIPv4Tunnel` ignores it.
4. **A periodic audit read.** Recommended: every 60 s. Without it, a notification that never arrives leaves the verdict stale until the next store change. A reconcile with nothing changed has no effect. A new timer needs owner approval.
5. **A VPN-service selector.** Recommended: later. `serviceID` and `overridesPrimary` are in the snapshot, and a selector is a `VPNUpPredicate`.

One question needs captures from U0 before U3: whether a service key naming a utun ever outlives the interface keys. If it does, `hasInterfaceKey` is what keeps that tunnel from reading as a flap.

`TunnelSnapshot` has no size cap in code. Its size is the number of utun interfaces the store lists. A cap is a new limit and needs owner approval.
