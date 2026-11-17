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

- **Measure from the last good reading.** The timer records the time `L` of its last good reading and that a failure followed it. On recovery at `now`, a tunnel that counted at `L`, is still named by an interface key, and no longer counts is treated as lost at `L`. Its debounce ends at `L + minVisible`. The session counts as connected until `min(now, L + minVisible)`, and grace ends `grace` after that. With no other tunnel counting, a gap longer than `minVisible + grace` reports `.disconnected(.networkLost)` at once. A shorter gap leaves the rest of the window: with `L = 0`, the default windows of 1 s and 5 s, and recovery at 5.5 s, the session reports `.reasserting` until 6 s. This is option (b) of the design's decision 7.
- **Captures stay on the machine that recorded them.** They are never committed. Tests get small hand-written fixtures derived from them, with nothing specific to a machine or network.

## Alternatives

- **Judge the recovery reading as if no gap happened** (option (a)). It reports up for a few seconds when the evidence says down, which the owner's requirement rules out.
- **Commit masked captures as fixtures.** Replays would be exact, but masking cannot remove what identifies a network's shape, and a public commit cannot be withdrawn.

## Consequences

- A brief real flap that overlaps a blind gap gets less grace than one the session watched, and can report `.disconnected(.networkLost)` until the next reading with the address back. That errs toward installing nothing off VPN.
- A lost notification is not a known gap, so this decision does not cover it. The audit read of the design's decision 4 does.
- The timer's memory gains one instant and one flag. "A failed reading leaves the memory untouched" becomes "a failed reading records only that it failed". The model check's oracle and its blindness property change with it.
- Questions that need a capture, such as whether a service key outlives a utun's interface keys, are answered by reading the capture locally and writing the finding into a fixture by hand.

## Invariants and verification

- After a blind gap longer than `minVisible + grace`, when the only tunnel that counted before the gap is still named by an interface key and has no address, the first good reading reports `.disconnected(.networkLost)`. If its interface keys are gone, it reports `.disconnected(.userInitiated)`, as for any removal. If another tunnel counts, it reports `.connected`. U3 adds these to the exhaustive model check and a pm-sim scenario.
- No file under `Tests/` or `Sources/` holds a raw capture. Review checks fixtures for machine-specific values.
- Disproved if the model check finds a gap ordering where a recovery reading reports `.connected` or `.reasserting` after `L + minVisible + grace` with no tunnel counting.

## Implementation evidence

None yet. U3 implements the blind-gap rule.

## Open questions

None.
