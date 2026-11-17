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
- **Where store captures live.** `pm-vpn-check --snapshot` and `--watch` (#308) record what macOS reports while a VPN connects, flaps and drops. Masking removes addresses and names, but a capture still keeps tunnel counts, subnet masks, flags, ordering and timing. Those can identify a machine or a corporate network, and the repository is public.

## Decision

- **Measure from the last good reading.** The timer records the time of its last good reading and that a failure followed it. On recovery, a tunnel that counted before the gap and no longer does has its windows measured from that last good reading. A gap longer than `minVisible` plus `grace` reports `.disconnected(.networkLost)` at once. A shorter gap leaves the rest of the window. This is option (b) of the design's decision 7.
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

- After a blind gap longer than `minVisible` plus `grace`, a tunnel that counted before the gap and has no address after it reports `.disconnected(.networkLost)` on the first good reading. U3 adds this to the exhaustive model check and to a pm-sim scenario.
- No file under `Tests/` or `Sources/` holds a raw capture. Review checks fixtures for machine-specific values.
- Disproved if the model check finds a gap ordering where a recovery reading reports up for a tunnel the reading shows without an address.

## Implementation evidence

None yet. U3 implements the blind-gap rule.

## Open questions

None.
