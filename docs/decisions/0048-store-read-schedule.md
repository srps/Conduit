# 0048: Retry a failed store reading with backoff, audit a healthy one every 60 s, and withhold split DNS while blind

- Date: 2026-11-17
- Decision: proposed
- Implementation: partial
- Validation: none
- Supersedes: none
- Superseded by: none

## Context

Two observers read the SCDynamicStore. `VPNStatusMonitor` decides the VPN verdict, and the [level-triggered design](../design-vpn-detection-level-triggered.md) rewrites it in unit U3. `PushedResolverMonitor` reads the resolvers a VPN pushes ([0044](0044-split-dns-follows-vpn-pushed-resolvers.md)). Both read only when the store sends a change notification. The owner's requirement is that the VPN on/off verdict is exact.

Observed in the code:

- After a failed `SCDynamicStoreCreate` or subscription, `PushedResolverMonitor` keeps no store and never reads again, so detected split DNS stays off for the run (#304).
- The VPN monitor has no reading that is not prompted by a notification. A notification that never arrives, as when configd restarts under a session, leaves the verdict stale until the store next changes. Nothing reports the miss.
- With the U3 timer, `.unknown` comes only from a failed reading. `SplitDNSVPNGate` reads `.unknown` as connected and keeps the `/etc/resolver` entry files. If the VPN is down meanwhile, those files point at servers only the tunnel reaches, and every lookup under their domains fails, the VPN gateway's own name included.

Assumed: a store failure is transient, and a later attempt on a new session can succeed. No public API that reports a dead store session was found.

The owner chose the retry schedule on 2026-11-17, after options for decisions 2 and 4 of the design were laid out, and approved a new timer for #304 earlier.

## Decision

- **One read schedule for both observers.** After a failed create, subscribe or read, the observer tries again after 1, 2, 4, 8 and 16 s, then every 30 s until a reading succeeds. A retry after a create or subscribe failure builds a new store session. The first good reading resets the schedule. The schedule holds one pending wake-up and an attempt count, so it does not grow.
- **An audit read while healthy.** The VPN monitor reads the store every 60 s while readings succeed, whatever the notifications did. A reading that changes nothing has no effect. The pushed-resolver observer gets no audit here; design unit U6 can move it onto the VPN monitor's session.
- **One timer per observer.** An observer arms a single wake-up at the earliest of its flap deadline, its retry and its audit. The wake-up may run up to 10% late, so macOS can batch it with other wake-ups.
- **Retries are reported.** Each failure carries its step and the attempt. Attempts 1, 2, 4 … 64 emit an event, and after that every 64th, so a store that stays broken costs a few events an hour. The first good reading after a failure emits a recovery event with the attempt count.
- **Withhold split DNS while blind** (decision 2 of the design). `SplitDNSVPNGate` treats `.unknown` as not connected. No entry files are installed or kept until a reading succeeds.
- **Flap memory does not survive a stop** (decision 1 of the design). Each `start` gets a new timer.

## Alternatives

- **No audit, or event-only re-reads (wake, path change).** These set no limit on a missed notification, which the exactness requirement rules out. Event re-reads stay as design unit U5, in addition to the audit.
- **A second notification channel.** It makes a miss less likely and sets no limit either.
- **A fixed retry interval.** One short interval polls a store that stays broken. One long interval leaves split DNS withheld for that long after a single failed reading.
- **Keep `.unknown` as connected.** That installs entry files off VPN whenever a failure overlaps a disconnect.

## Consequences

- An unreadable store withholds split DNS. A single transient failure costs about a second. A store that stays broken costs split DNS until it recovers, and the events say so.
- The VPN monitor wakes once a minute while healthy, for one `SCDynamicStoreCopyMultiple`.
- #304 is fixed by the same schedule.
- The interval values are a judgement, not a measurement. Changing them needs the owner.

## Invariants and verification

- The schedule is a pure value. Unit tests cover the sequence, the cap, the reset on success and the event attempts.
- With a fake store that fails N times, each observer delivers a good reading after the scheduled attempts, and a create or subscribe failure is retried on a new session (#304's acceptance).
- With the store unchanged and a notification dropped, the VPN monitor reports the new verdict by the next audit.
- `SplitDNSVPNGate` withholds on `.unknown`. A pm-sim scenario covers a blind gap that overlaps a disconnect, with no entry files installed during it.
- Disproved if an observer stays failed with no further attempt, or if entry files exist while the last reading failed.

## Implementation evidence

The schedule and the pushed-resolver observer are implemented; the VPN monitor's parts wait for design unit U3.

- [`StoreReadSchedule.swift`](../../Sources/ProxyKernel/Network/StoreReadSchedule.swift) is the pure schedule: the delays, the cap, the reset on the first good reading, the reported attempts, the optional audit and the 10% leeway, with the constants in one place. [`StoreReadScheduleTests`](../../Tests/ConduitTests/StoreReadScheduleTests.swift) cover the sequence, the cap, the reset, the audit and the reported attempts.
- [`PushedResolverMonitor.swift`](../../Sources/PlatformMac/PushedResolverMonitor.swift) retries a failed create, subscribe or read on the schedule, on a new session after a create or subscribe failure. It holds one wake-up on [`StoreObserverClock`](../../Sources/PlatformMac/StoreObserverClock.swift), cancelled by a stop or a good reading, and each `start` opens a generation that a late callback or wake-up is checked against. It has no audit. The host emits `dns.split_detection_failed reason= attempt=` at the reported attempts and `dns.split_detection_recovered attempts=` on the first good reading after them ([`RuntimeHostSplitDNSDetection.swift`](../../Sources/ConduitRuntime/RuntimeHostSplitDNSDetection.swift), [`LiveSplitDNSDetection.swift`](../../Sources/PlatformMac/LiveSplitDNSDetection.swift)). This fixes #304.
- [`PushedResolverMonitorTests`](../../Tests/ConduitTests/PushedResolverMonitorTests.swift) fail a create, a subscribe or a read N times over a scripted store and a held clock, and check the delays, the new sessions, the reported readings and the recovery; a stop during a pending retry cancels it. [`RuntimeHostSplitDNSTests`](../../Tests/ConduitTests/RuntimeHostSplitDNSTests.swift) and [`LiveSplitDNSDetectionTests`](../../Tests/ConduitTests/LiveSplitDNSDetectionTests.swift) cover the events. pm-sim `dns-split-detection-retries` ([`SplitDNSFollowsVPNScenarios.swift`](../../Sources/pm-sim/SplitDNSFollowsVPNScenarios.swift)) runs the real monitor in the actual host through a create failure and a subscribe failure to a reading that puts the tunnel's server in use.

Does not prove: that a real `SCDynamicStoreCreate` or subscription that failed succeeds on a later session. The tests fail the calls themselves; that a failure is transient is the record's assumption.

Left for U3: the VPN monitor's retry, its 60 s audit and its single wake-up at the earliest of the flap deadline, the retry and the audit; `SplitDNSVPNGate` withholding on `.unknown`; a new timer for each `start`; and the pm-sim scenarios for a blind gap over a disconnect and a dropped notification.

## Open questions

None.
