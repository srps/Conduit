# 0046: Bound what grows, validate what a trusted local source replaces

- Date: 2026-11-17
- Decision: proposed
- Implementation: implemented
- Validation: none
- Supersedes: none
- Superseded by: none

## Context

STYLE rule 1 came from TigerBeetle's TIGER_STYLE. It said every pool, queue, cache and buffer has a fixed capacity in config, and that "unbounded anything is a bug". `AGENTS.md` asked the owner before any unbounded collection, queue, cache or timer. The stated failure is a slow leak over weeks of daily use.

The bounds that protected Conduit all hold something that grows over time, or something whose size a peer controls:

- `inboundConnectionMaxLimit` caps connections from clients.
- `maxBufferedBodyBytes` and `maxSpooledBodyBytes` cap request bodies kept for replay.
- `RuntimeEventLog`, `RuntimeEventRepeatGate` and the DNS forwarder's query slots cap what a storm fills.
- The PAC route cap (#93, #141) limits what a remote PAC server can put into a cache of 512 URL keys.

The rule also asked for caps on values that hold neither. Each of these is a full reading of local state, written by trusted processes, that the next reading replaces:

- #305 asks for a cap on the pushed-resolver reading. Its own impact section says nothing accumulates and memory is bounded by what the store holds.
- Decision 6 of [the level-triggered VPN detection design](../design-vpn-detection-level-triggered.md) proposed a 64-tunnel cap on `TunnelSnapshot`. A reading over it would fail, so a Mac that stays over it would be blind for good, to guard memory that was never at risk. If `.unknown` withholds split DNS (the design's decision 2), that Mac would also never get split DNS.
- The 16-domain cap of [0044](0044-split-dns-follows-vpn-pushed-resolvers.md) on each pushed resolver is below what the owner wants to support. Raising it, which is not done yet, needs a separate limit on the status data. That limit is a real one, from the 64 KiB reply frame of [0030](0030-ordinary-runtime-reply-frame-cap.md).

A cap on such a value adds a failure mode and protects nothing. A truncated reading can drop the entry that matters, such as the tunnel that carries the VPN. A refused reading leaves Conduit blind while the source is healthy.

The owner asked to revisit the rule and to support providers properly instead of limiting them where no limit is needed.

Observed: on 2026-11-17 a process running as the user (uid 501) tried to write `State:/ConduitWriteProbe` with `scutil` and got `Permission denied`. No key was created. Assumed: only root and entitled processes can write `State:` keys.

## Decision

- **Bound what grows.** A collection, queue, cache, buffer or timer that grows over time, or whose size comes from input Conduit does not trust, has a fixed capacity in config. The bound says what happens at the limit (reject, evict or spill) and emits a `RuntimeEvent` when it applies. Adding one still needs the owner's approval.
- **Validate what a trusted local source replaces.** A value rebuilt whole on each read of a trusted local source needs no cap. The example is a reading of the SCDynamicStore. Its size is the source's size, and the next read replaces it. It is validated at its boundary (STYLE rule 4), and malformed entries are rejected with an event.
- **Transport and display limits are separate.** A frame cap, a message size or a row count in Settings applies where that limit is, to what crosses it, and never to the data underneath.
- **Untrusted means outside the machine or outside the trust boundary.** Network peers, clients of the local listeners, PAC and DoH servers, upstream responses and files a user process can write are untrusted. Root-owned system state is trusted. Configuration files are user-writable, so configuration keeps the resource ceilings of [0021](0021-bounded-configuration-at-all-boundaries.md), such as 32 upstreams and 128 tunnels, whatever else validation checks.
- **Retained state is growth.** A structure that keeps entries from earlier readings, such as `LiveSplitDNSPolicy`'s flap hold, which merges fresh resolvers with retained ones, grows over time even when each reading is bounded by its source. It keeps its cap.

## Alternatives

- **Keep the rule as written.** Every snapshot keeps a cap, an overflow policy, an event, tests and an owner decision, and each cap adds a truncation or blindness failure. This is what produced the 64-tunnel and 16-domain discussions.
- **Drop the rule.** The leak it was written for is real for caches, queues and per-connection state, and the existing bounds have stopped storms.
- **Cap snapshots at a very large value.** The cost of the failure mode stays, only rarer, and the value still needs a justification nobody can give.

## Consequences

- Decision 6 of the VPN detection design is settled as no cap. `TunnelSnapshot` carries every tunnel the store names.
- #305 no longer needs a cap on the pushed-resolver reading itself. The flap hold keeps its cap, and the outputs keep their limits wherever a transport or the helper sets one.
- Reviews ask two questions of a new collection: does it grow, and who controls its size. A no to both needs validation, not a cap.
- Trusting the store is a policy, not a protection. A process that can write `State:` keys can fabricate tunnel addresses and so choose the VPN verdict, and an oversized reading costs Conduit memory and CPU in proportion. A cap would not stop either: a writer that can fake one tunnel's address can fake the verdict within any limit. Such a process can already change the machine's routing and DNS directly.

## Invariants and verification

- Every collection that grows over time or takes its size from untrusted input keeps a configured bound with an event at the limit. The bounds listed in Context stay as they are.
- A snapshot of a trusted local source is never truncated. A malformed entry in it is rejected with an event.
- Disproved if an uncapped snapshot is shown to grow without a matching growth in the source, or if a `State:` key is shown writable without root or an entitlement.

## Implementation evidence

The rule is the code-review contract in [`AGENTS.md`](../../AGENTS.md) (the "Ask first" list) and STYLE rule 1. No code changes with it.

Does not prove: that every `State:` key is root-only. The check covered one key outside `State:/Network`.

## Open questions

None.
