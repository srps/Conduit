# 0047: A blind gap is measured from the last good VPN reading, and store captures stay local

- Date: 2026-11-17
- Decision: proposed
- Implementation: planned
- Validation: none
- Supersedes: none
- Superseded by: none

## Context

[The level-triggered VPN detection design](../design-vpn-detection-level-triggered.md) replaces the VPN monitor with a full store reading and a flap timer. Two of its open choices have to be settled before unit U3 rewrites the monitor. The owner's requirement is that the VPN on/off verdict is exact.

- **The first reading after a blind gap.** When the store cannot be read, the timer keeps its memory and reports `.unknown`. Today the first good reading after the gap is judged as if it followed the last good one directly. A tunnel that counted before the gap and has no address after it then starts its debounce at the recovery reading. The session reports `.connected` for `minVisible` and `.reasserting` for `grace`, 6 s with the default windows, however long the gap was. `SplitDNSVPNGate` treats both states as up, so split DNS stays installed while the evidence says the VPN is gone.
- **Where store captures live.** `pm-vpn-check --snapshot` and `--watch` (#308) record what macOS reports while a VPN connects, flaps and drops. Masking replaces addresses, names, subnet masks and flags (#308), but a capture still keeps its topology: how many tunnels and services, which keys each has, their ordering, and the timing of every change. Those can identify a machine or a corporate network, and the repository is public.

## Decision

- **Measure from the last good reading.** The timer records the time `L` of its last good reading and that a failure followed it. A loss seen at recovery is dated at `L`. The verdict at recovery time `now` is the one the timer gives at `now` if the recovery snapshot had been read at `L` and read again at `now`, with no reading in between. Both of those readings use the flap windows that were in force at `L`, for the debounce and for the grace that follows it, so a Settings change during the gap cannot lengthen or shorten a loss dated before it. A phase that starts after the recovery reading uses the current windows. Every existing rule then applies unchanged: a debounce or grace already running at `L` keeps its deadline, grace follows a debounce that ends during the gap, and windows changed in Settings during a running phase do not move it. Example: a single tunnel counted at `L = 0`, the default windows are 1 s and 5 s, and it has no address at recovery. Recovery at 5.5 s reports `.reasserting` until 6 s, and recovery at 7 s reports `.disconnected(.networkLost)` at once. This is option (b) of the design's decision 7.
- **Captures stay on the machine that recorded them.** They are never committed. Tests get small hand-written fixtures derived from them, with nothing specific to a machine or network.

## Alternatives

- **Judge the recovery reading as if no gap happened** (option (a)). It reports up for a few seconds when the evidence says down, which the owner's requirement rules out.
- **Commit masked captures as fixtures.** Replays would be exact, but masking cannot remove what identifies a network's shape, and a public commit cannot be withdrawn.

## Consequences

- A brief real flap that overlaps a blind gap gets less grace than one the session watched, and can report `.disconnected(.networkLost)` until the next reading with the address back. That errs toward installing nothing off VPN.
- A lost notification is not a known gap, so this decision does not cover it. The audit read of the design's decision 4 does.
- The timer's memory gains one instant, one flag and the flap windows in force at that instant. "A failed reading leaves the memory untouched" becomes "a failed reading records only that it failed". The model check's oracle and its blindness property change with it.
- Questions that need a capture, such as whether a service key outlives a utun's interface keys, are answered by reading the capture locally and writing the finding into a fixture by hand.

## Invariants and verification

- The verdict at a recovery reading equals the timer's verdict at the same instant for the same history with that snapshot read at `L` and again at the recovery instant, both with the windows in force at `L`. U3 adds this as a property of the exhaustive model check, including Settings changes during the gap, beside cases for the example above, a removed interface (`.disconnected(.userInitiated)`), and another tunnel still counting (`.connected`), and a pm-sim scenario.
- No file under `Tests/` or `Sources/` holds a raw capture. Review checks fixtures for machine-specific values.
- Disproved if the model check finds a gap ordering where the two verdicts differ.

## Implementation evidence

None yet. U3 implements the blind-gap rule.

## Open questions

None.
