# Level-triggered VPN detection

Status: units U1 and U2 are implemented in #307. U0, the capture tool, is in #308. Nothing in the running product uses the new types yet. Units U3 to U6 are an outline and wait on the owner decisions listed at the end.

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

`TunnelReading` is `.snapshot(TunnelSnapshot)` or `.failed(Failure)`. A `Failure` names the step that failed (`storeCreate`, `storeSubscribe`, `storeRead`, or `storeUnsubscribe`) and carries the `SCError()` code read straight after the call. A failure is a value the caller must handle, so it cannot be silent.

`TunnelStoreReading` (in `PlatformMac`) is the store as detection uses it. `read()` returns a `TunnelReading`. `subscribe(queue:onChange:onUncancelledRelease:)` returns a subscription or a failure. `onChange` carries no keys, so a subscriber cannot act on a delta. A subscription owns one store session. `cancel()` ends the session and returns a failure if the store refused to detach the queue. After a failed cancel the store can go on calling `onChange`, so the subscriber reports the failure and ignores calls from that session. The owner must cancel before it releases a subscription. Releasing one uncancelled is a bug in the owner, and a debug build traps on it. A release build must not leak the session silently, so the release itself detaches the queue as a backstop and passes the result to `onUncancelledRelease`: success if the session ended, or the failure a cancel would have returned. U3 maps that call to a `RuntimeEvent`. `FakeTunnelStore` follows the same contract.

`SystemTunnelStore` is the `SCDynamicStore` implementation. It keeps one session for reads and drops it after a read fails, so the next read opens a new one.

`FakeTunnelStore` holds keys and parses all of them on every read. It signals the way configd does. A change marks each subscription that existed when it happened, and a marked subscription has at most one signal queued, however many changes it stands for. A write that leaves a key unchanged signals nothing, and neither does a key outside the subscribed patterns. A held change is delivered only to the subscriptions that were there for it. A cancel takes back a signal that has not run. One switch, `signalsQueuedBeforeCancelStillRun`, turns that last rule off. `SCDynamicStore` does not promise that a detached queue has no callback left on it, so U3 uses the switch to prove that its generation check drops a call from an earlier session.

`VPNUpPredicate` says which tunnels count as the VPN being up. The default, `anyIPv4Tunnel`, is the rule the shipped monitor applies: a utun whose interface IPv4 key lists an address. The predicate is a value passed to the timer, so a narrower rule later is a different predicate and not a different state machine. A session passes the same predicate to every reconcile.

`VPNFlapTimer` is the only memory. `reconcile(_:now:window:up:)` takes a reading and the time and returns a `VPNDetection`: the phase, the `VPNObservedState` it maps to, the tunnels carrying a connected state, the live tunnels, and a deadline. The timer remembers four things:

- `debounceEnds`: for each tunnel that stopped counting and is still in the store, when its debounce ends.
- `counted`: which interfaces counted in the last reading.
- `connectedUntil`: the latest instant the state was connected.
- `graceEnd`: when the grace window ends, once it has started.

A session creates a new timer on each start. `debounceEnds` holds entries only for tunnels in the current snapshot, so it cannot grow past the snapshot.

### Windows are fixed when a phase starts

`minVisible` and `grace` come from Settings, and the owner can change them at any time. The timer reads each one once per phase:

- The reading that first sees a tunnel lose its address stores that tunnel's debounce end, `now + minVisible`.
- The first reading after the last debounce ended stores the grace end, `connectedUntil + grace`.

A later reconcile compares the clock with the stored ends and ignores the window it is handed for a phase already running. A new window applies to the next phase that starts.

This gives the guarantee that matters for a verdict nobody is allowed to get wrong. While the store stays as it is, the phase only moves forward: `debouncing`, then `reasserting`, then `down`. A settled `.disconnected(.networkLost)` stays settled whatever the owner types into Settings.

An earlier version stored the time of the loss and recomputed both ends from the window of each call. Raising `minVisible` to 30 s then turned a settled `.disconnected(.networkLost)` back into `.connected`, and raising `grace` to 3600 s turned it into `.reasserting`, with the store unchanged. `SplitDNSVPNGate` treats both states as up, so entry files would have been installed again off VPN.

### The clock

`now` is seconds on a monotonic clock, and the timer uses only differences. U3 reads it from `ContinuousClock`, which keeps counting while the Mac sleeps.

That choice decides what a sleep does to a flap. A debounce or a grace window that ran out during the sleep is over at the first reconcile after wake, so the session reports `.disconnected(.networkLost)` at once if the tunnel is still without its address. A clock that stops during sleep would resume the window with seconds left and report `.reasserting` for a loss that is minutes old. The shipped monitor's timers use Dispatch's uptime clock, which stops during sleep, and `recoverStaleReassertingAfterWake` in the orchestrator handles a `.reasserting` that is still standing after a wake.

The wake-up for a deadline is a Dispatch timer and can fire late after a sleep. That costs latency only. U5 reconciles on wake, which removes the latency.

### The statechart

One statechart describes an observation session. The timer computes the phase on every reconcile and never stores it.

| Phase | Condition | State reported | Deadline |
| --- | --- | --- | --- |
| `up` | A tunnel counts. | `.connected` | The next debounce to end, if a lost tunnel is still inside one. |
| `debouncing` | No tunnel counts. A lost tunnel's debounce has not ended. | `.connected` | The next debounce to end. |
| `reasserting` | No tunnel counts or debounces. A lost tunnel is still in the store. The grace end has not passed. | `.reasserting` | The grace end. |
| `down(reason)` | None of the above. | `.disconnected(reason)` | None. |
| `blind(failure)` | The reading failed. | `.unknown` | None. |

The reason for `down` is `networkLost` when a lost tunnel is still in the store, `userInitiated` when the session saw the VPN up and no tunnel is left to recover, and `unknown` when the session never saw the VPN up.

Every comparison is against the clock, not against a count of timer firings. If the wake-up for a deadline is late, the next reconcile reports the phase that the elapsed time implies. If the wake-up never comes, the next input of any kind does the same.

A failed reading leaves the memory untouched. The next reading that succeeds continues from the clock, as if it followed the last successful reading directly. Decision 7 proposes changing what that means for a flap window.

A `blind` detection has no deadline, so nothing in the timer asks for the next read. U3 has to schedule it. Decision 4 covers how.

### What stays the same

Flap behaviour matches the shipped monitor. A loss shorter than `minVisible` is silent. A loss that recovers inside `grace` reports connected, reasserting, connected. A loss that outlasts `grace` reports `.disconnected(.networkLost)`. A removed interface reports `.disconnected(.userInitiated)` at once, with no window. Grace runs from the moment the state stopped being connected, which is why `connectedUntil` exists: with two tunnels, the tunnel that ended the connected state may be gone from the store by the time grace is measured.

## How the timer is tested

`VPNFlapTimerModelCheckTests` holds three checks. All run a small store model: two tunnels beside a service tunnel that never changes. Each of the two can be absent, IPv6-only, addressed with an IPv6 key beside the IPv4 key, addressed with the IPv4 key alone, holding an IPv4 key with no addresses, or named only by a service key.

### The oracle

Every reconcile in the first two checks is compared with an oracle. The oracle is a function from the list of readings a session took to the detection it must report: the phase, the disconnect reason, the carrying and live tunnels, and the deadline. It follows the statechart above and keeps no memory. It finds a debounce end by walking back through the readings to the one that first saw the loss, and a grace end by walking back to the first reading of the current run without a connected state. It shares no state and no arithmetic with `VPNFlapTimer`.

### The exhaustive check

The exhaustive check runs every ordering of 24 operations to depth 4 from two starting stores. An operation that changes nothing is not taken, because that ordering equals the shorter one without it, which is checked as a prefix. That leaves 274,666 orderings and 289,563 states.

| Operations | Count |
| --- | --- |
| One tunnel changes: up, IPv4 key dropped, removed, IPv4 key with no addresses (either tunnel), left with a service key only (first tunnel), left IPv6-only whatever it had, left with an addressed IPv4 key alone (second tunnel). | 11 |
| Both tunnels change in one notification: a handover from one to the other, and both losing IPv4. | 2 |
| Waits: inside `minVisible`, inside `grace`, past both. | 3 |
| A restart. A stop or a start, so the store and the clock move while nothing reads. | 2 |
| A toggle that loses notifications. A toggle that makes reads fail. A toggle that makes deadline wake-ups late. | 3 |
| A window change: the default 1 s and 5 s, `minVisible` of 0, and 3 s with 15 s. | 3 |

After every operation it asserts:

- The oracle. Each reconcile on the way, and each one the properties below make, returns what the oracle expects.
- Convergence. After every deadline has run, the state is `.connected` exactly when a tunnel counts. A tunnel that counts is reported at once. A store that was read never reads `.unknown`.
- No way back. With the store unchanged, a phase only moves forward, a disconnect keeps its reason, and a grace window keeps its end, whatever window each reconcile is handed.
- Idempotence. The same reading at the same time, twice, returns the same detection and leaves the same memory.
- Restart. A new timer on the current store reads `.connected` or `.disconnected(.unknown)`, with no deadline. The timer that watched the store get there settles on `.connected` for the same stores. For the others it settles on `.disconnected` with the reason its own history gives. So a restart keeps connected against disconnected and can change the reason.
- Notification loss and read failure. After any number of lost notifications or failed reads, one more reading restores convergence. The check takes that reading itself.
- Late deadlines. While wake-ups are late, a wait moves the clock and runs no deadline. The overdue wake-up runs when the toggle goes back or when another reading stands in for it, under whatever window is set by then, and returns what the oracle expects.
- Blindness. A failed reading reports `.unknown` with no deadline and leaves the memory untouched.

The reason a watched session settles on depends on what it saw:

| The session | Settles on |
| --- | --- |
| Saw a tunnel up that is still in the store under an interface key, without its address. | `.disconnected(.networkLost)` |
| Saw the VPN up, and no such tunnel is left. | `.disconnected(.userInitiated)` |
| Never saw the VPN up, which includes every new session on a store with no addressed tunnel. | `.disconnected(.unknown)` |

The check counts how many states settle on each of the four verdicts and fails if any count is zero. It also fails if no state has an IPv4-only tunnel, or if none has an overdue deadline under a window that changed since the last reading. The exhaustive check reaches 60 states of that second kind and the seeded check 289.

### The seeded check

Depth 4 is what 24 operations allow in a test run. A seeded check covers longer histories: 10,000 orderings, each 24 operations long, from a fixed seed. That is 240,000 states, with the same assertions after every operation.

### The differential check

The differential check runs every ordering of the ten one-tunnel changes and the three waits to depth 6 from three starting stores, with no restart, one window, and every notification delivered. It drives a transliteration of `VPNStatusMonitor` over the real `VPNStateFuser` and a session over `VPNFlapTimer` on the same virtual clock. The state changes, the times of those changes, the whole list of connected interfaces, and the live set must be equal. 2,121,874 orderings are equal.

On the development machine, in a debug build, the three checks take 5.5 s, 3.8 s, and 19.9 s. The exhaustive and differential checks assert their ordering counts, so a change to the alphabet or the depth fails the test until the count is updated.

### What the checks do not prove

The checks hold `VPNFlapTimer` to the statechart. They do not show that detection is never wrong. Four limits remain, and U3 has to close the first three in code.

**Convergence assumes another reading occurs.** The timer cannot ask for a reading. A `blind` detection has no deadline, and neither does a settled one. After a lost notification or a failed read, the convergence property holds only because the check takes one more reading itself. Nothing in U1 or U2 makes that reading happen in the product. U3 closes the gap in two places:

- After a blind reading, the monitor schedules a re-read and keeps doing so on a bounded schedule until one succeeds.
- After a lost notification, nothing tells the monitor that it missed anything, so only a reading on a fixed period can bound the damage. That is the audit read of decision 4. Until it exists, the verdict is correct only while every notification arrives. Decision 4 therefore has to be settled before U3, not in U6.

**Deadlines are punctual or late, never arbitrary.** A wake-up in the model runs on time, or late at an instant the stall toggle and the three waits allow. The waits are 0.4 s, 2 s, and 10 s, so the model covers a handful of durations per window, not every one. A wake-up that never runs is covered only by the reading the check injects, which is the first limit again.

**The store is small and well formed.** The model has two tunnels beside one service tunnel. The IPv4-only tunnel is the second tunnel only, and only in the exhaustive and seeded checks. The differential check does not model it. Every key in the model has the right types. `parse` reads a key that is not a dictionary as absent and an `Addresses` that is not a list of strings as empty, and it says nothing when it does. A malformed key on the tunnel that carries the VPN would then read as down with no trace. U3 has `parse` return the tunnel keys it dropped, and the monitor emits an event for them.

**The oracle shares three choices with the timer.** The oracle shares no state and no arithmetic with `VPNFlapTimer`, but it was written from the same specification. If one of these choices is wrong, both are wrong together and the checks pass:

- A failed reading drops out of the history. The oracle sees successful readings only, so it cannot disagree with the timer about what a blind gap means. Decision 7 is about this choice.
- A debounce starts at the reading that observes the loss, not at the moment the store changed. A late reading starts a late debounce.
- Grace is fixed by the first reading after the debounce ended. That reading supplies the `grace` value, however late it is.

### Where the timer and the fuser differ

The differential check leaves out one class of ordering. The exhaustive and seeded checks still cover that class.

| Situation | Shipped monitor | Timer | Why the timer is right |
| --- | --- | --- | --- |
| An IPv4 key with no addresses appears on a tunnel that has had no address since the session began. | `.unknown`, or `.disconnected(.networkLost)` beside a removed tunnel. Removing the key later reports `.disconnected(.userInitiated)`. | No change. | The store shows no addressed tunnel, so the VPN is down. `SplitDNSVPNGate` reads `.unknown` as "assume connected", so the shipped answer can install entry files off VPN. |

Two differences fall outside what the differential check models:

- A notification that names two tunnels. The shipped monitor applies the keys one interface at a time in dictionary order and can report an intermediate state. The timer reads both at once.
- A late timer. The shipped monitor moves on only when its `DispatchWorkItem` runs. The timer reports the phase the clock implies, so it can skip `.reasserting` after a long stall.

A change to `minVisible` or `grace` during a flap is not a difference. The shipped monitor reads each value when it arms that timer: `minVisible` at the loss, `grace` when the debounce expires. The timer fixes each window at the same two moments. The differential check runs one window, so the exhaustive and seeded checks are what cover a change.

## Migration units

Each unit is one pull request that leaves the product working.

| Unit | Change | Product behaviour |
| --- | --- | --- |
| U0 | `pm-vpn-check --snapshot` and `--watch` dump the masked store, so real Cisco Secure Client transitions become parse fixtures. In #308. | None. |
| U1 | `TunnelSnapshot`, `TunnelReading`, `parse`, `TunnelStoreReading`, `SystemTunnelStore`, `FakeTunnelStore`, `VPNUpPredicate`, `VPNFlapTimer`. In #307. | None. |
| U2 | The exhaustive, seeded, and differential checks. In #307. | None. |
| U3 | Rewrite `VPNStatusMonitor` on the new types. Each `start` gets a new timer, a new subscription, and a generation that late callbacks are checked against. A failed reading emits an event and schedules a bounded re-read until one succeeds. `parse` returns the malformed tunnel keys it dropped and the monitor emits an event for them. A subscription released uncancelled emits an event from `onUncancelledRelease`. Delete `VPNStateFuser`, `UtunRawObservation`, `markNoTunnelsPresent`, `knowsAbout`, the grace latch, and the differential check that compares against them. | Fixes the five failures. Subsumes #300, #303, and #202. Needs decisions 1, 2, 4, 6, and 7. |
| U4 | Consumers take one `VPNVerdict` value: state, carrying, live, generation, and sequence. Remove the side boxes that carry the names beside the state (`connectedInterfaceName` and `liveInterfaceNames` on `VPNStatusMonitor` and `VPNStatusObserving`), the host's sequencer, and the rule in `LiveSplitDNSDetection.stop()` that keeps the last verdict. Deliver the first verdict before surfaces are applied. `pm-sim` scenarios cover a stop during a flap, a tunnel removed while stopped, and a lost notification. A decision record lands here. | One value per verdict, so a consumer cannot pair a state with another verdict's names. |
| U5 | Reconcile on wake and on a network path change. Remove the `snapshot.vpnState = .connected` write in `recoverStaleReassertingAfterWake` (`ProxyOrchestrator`), so the monitor is the only writer of the VPN state. | A verdict that went stale across a sleep is corrected by a reading, not by a guess. |
| U6 | Owner-gated changes: a different up predicate, an audit re-read every 60 s unless decision 4 has already put it in U3, and optionally `PushedResolverMonitor` on the same store session. | Needs decisions 3, 4, and 5. |

U3 to U6 are an outline. The owner approved U0 to U2 only.

## Open decisions

U0 to U2 do not depend on these. The types already express each option of decisions 1 to 5. Decisions 6 and 7 change `parse` and the timer. Neither is implemented, and each waits for the owner.

1. **Flap memory across a stop.** Recommended: drop it. A session creates a new `VPNFlapTimer`, so a stop during a flap restarts as whatever the store shows. Keeping the timer across a stop is also expressible, but it brings back a verdict that depends on what happened while nobody was reading.
2. **What `.unknown` means for split DNS entry files.** Recommended: withhold them. With the timer, `.unknown` arises only from the `blind` phase, when the store cannot be read. A blind reading delivers the same verdict under either option: state `.unknown`, no carrying tunnel, no live tunnel, and a failure event with the step and the store's error code. The options differ in what the gate does with it.
   - **Withhold.** `SplitDNSVPNGate` treats `.unknown` as not connected, so there are no entry files until a reading succeeds. Corporate names stop resolving through the VPN resolvers for as long as the store is unreadable, even if the VPN is up. Nothing is installed off VPN.
   - **Assume connected.** This is what the gate does today. The entry files stay, or are installed, for as long as the store is unreadable. If the VPN is down in that time, they are installed off VPN, which is the wrong verdict the requirement forbids.
3. **IPv6-only tunnels.** Recommended: report them, do not count them. `hasRoutableIPv6` is in the snapshot and `anyIPv4Tunnel` ignores it.
4. **A periodic audit read.** Recommended: every 60 s. Without it, a notification that never arrives leaves the verdict stale until the next store change, and a blind reading stays `.unknown` until the next store change even after the store is readable again. A reconcile with nothing changed has no effect. A new timer needs owner approval.
5. **A VPN-service selector.** Recommended: later. `serviceID` and `overridesPrimary` are in the snapshot, and a selector is a `VPNUpPredicate`.
6. **A size bound on `TunnelSnapshot`.** Pending, and needed before U3. Recommended: 64 tunnels, enforced in `parse` as a failed reading. `AGENTS.md` requires asking before adding an unbounded collection, and no cap is in the code.
   - **What is unbounded.** A snapshot holds one entry per utun the store names. The timer's memory and the `carrying` and `live` lists are no larger than the snapshot. Nothing in Conduit limits the number today.
   - **What the OS allows.** The macOS SDK headers document no limit on the number of utun interfaces. The development Mac lists 9.
   - **The value: 64 tunnels.** That is seven times what the development Mac lists, and it keeps the timer's memory and every event that names the tunnels small.
   - **Where it is applied.** In `parse`, which then returns a `TunnelReading`. A store with more than 64 tunnels is `.failed` with a step of its own, so the event tells it apart from a store call that failed. The failure carries the count.
   - **What is counted.** Distinct utun interfaces, whichever key names them. A tunnel that only a service key names counts, because it is a snapshot entry like any other.
   - **Never a truncated snapshot.** A truncated snapshot can leave out the tunnel that carries the VPN and report a connected Mac as disconnected, or leave out a lost tunnel and turn `.networkLost` into `.userInitiated`. A failed reading reports `.unknown`, and decision 2 then says what the gate does.
   - **The timer's memory.** Untouched, as for any failed reading. When the count falls back under the limit, the flap windows continue from the clock, or as decision 7 settles.
   - **The re-read schedule.** Being over the limit is a stable condition, so an immediate re-read returns the same failure. The re-read after it follows the same bounded schedule as any blind reading and must not spin. The monitor emits the event when the condition starts and when the count changes, not on every read.
7. **What the first reading after a blind gap means.** Pending, and needed before U3. Recommended: option (b).
   - **(a) Today.** A failed reading leaves the memory untouched, so the first successful reading after a gap is judged as if it followed the last successful one directly. Take a tunnel that counted before the gap and has no address after it. Its debounce starts at the recovery reading, and `connectedUntil` moves to the recovery time. The session then reports `.connected` for `minVisible` and `.reasserting` for `grace`, which is 6 s with the default windows, however long the store was unreadable. The VPN may have been down for the whole gap. `SplitDNSVPNGate` treats both states as up.
   - **(b) Measure from the last successful reading.** The timer records that a reading failed after its last successful one. On recovery, a tunnel that counted before the gap and no longer does has its windows measured from that last successful reading: its debounce ends `minVisible` after it, and `connectedUntil` stays there. A gap longer than `minVisible` plus `grace` reports `.disconnected(.networkLost)` at once. A shorter gap leaves the rest of the window.
   - **What (b) costs.** A tunnel that really lost its address a moment before recovery gets a shorter window than a flap the session watched, so a brief flap that overlaps a blind gap can report `.disconnected(.networkLost)`. That errs toward disconnected, which installs nothing off VPN, and the next reading with the address back reports `.connected`.
   - **What (b) does not cover.** A lost notification is not a known gap. The monitor cannot tell that it missed one, so only the audit read of decision 4 bounds it.
   - **What changes.** The timer's memory gains the time of the last successful reading and whether a failure followed it. "A failed reading leaves the memory untouched" becomes "a failed reading records only that it failed". The oracle's first shared choice and the blindness property change with it. A reading over the limit of decision 6 is a blind gap like any other.

One question needs captures from U0 before U3: whether a service key naming a utun ever outlives the interface keys. If it does, `hasInterfaceKey` is what keeps that tunnel from reading as a flap.
