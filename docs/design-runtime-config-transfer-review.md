# Configuration update boundary: owner review

Status: proposal, 2026-10-24. No ADR or production configuration client/codec is
implemented. This is the next API decision before config apply/start adoption,
following decisions 0014, 0015 and the selected writer lease in 0017.

## Recommendation

Use **one private configuration update request containing explicit frozen values**,
with an explicit private encoder. Ordinary lifecycle controls, status, events,
admission replies and outcome lookup stay secret-free. No snapshot registry,
reference expiry or matching public/private halves is required.

The private value does not conform to general Codable. URL fields that may carry
tokens use the existing SecretBytes discipline and a redacted URL wrapper. Only
the private codec can encode/decode them deliberately. This prevents accidental
generic event/status encoding; redacted descriptions are logging hygiene, not a
security boundary. JSON serialization can still create temporary String/Data
copies, so this does not promise all plaintext is zeroed.

Keep editing in AppState. A configuration workflow uses the sole injected store
to validate, save and verify required components, then passes the exact verified
immutable input to RuntimeHost. Runtime admission waits for verified persistence;
save outcomes, runtime admission and actual apply outcomes remain distinct.
The workflow must never call a live AppState back to obtain newer values.

The store is app-owned during convergence and daemon-owned later. The client
keeps drafts in both cases. The same private framing/codec is exercised in memory
before a socket adapter. A private update's acceptance is not runtime admission;
lookup must distinguish saving, persistence unknown/failure, runtime admission
and settlement. One request ID follows the workflow; internal phase/operation IDs
remain distinct types. A lost reply cannot authorize blind mutation replay.

Required receipts follow the affected effect: runtime-only changes can require
config alone, whereas a system-proxy repoint also needs the matching platform
settings. Unrelated UI preference failure does not refuse runtime work. Multiple
file writes are not an atomic transaction.

Stop retains its independent admission capacity and establishes the session fence
before any save. A late configuration save/transfer cannot restart a stopped
module. Caller deadlines detach waiting; owned physical writes/effects and their
frozen inputs remain alive until quiescent or process exit. This is bounded active
operation state, not retained snapshot history. Diagnostics cannot gate control.

## Alternative: public projection plus private URL bindings

The previous preferred implementation sketch puts safe values/receipts on ordinary
control and sends URL values through a private provider or envelope. It is viable
if both halves bind to the exact same committed input. Across processes it needs
explicit transfer and pairing, including missing-half, stale-half and cancellation
states. A reference alone cannot transfer an app-side value to the daemon.

The single private request preserves the explicit-value approach and removes that
pairing machinery. It does not make configuration smaller, eliminate its byte
budget or authorize raw configuration in diagnostics.

## Module shape

Proposed: private configuration values, client contract and explicit codec belong
beside the existing control contract in ConduitShared; mapping stays in
ProxyControlBridge. Move the neutral, non-Codable SecretBytes implementation from
ProxyKernel to ConduitShared, retaining a package typealias during migration so
Auth/headless consumers keep access. It imports Foundation/Darwin only; no new
target, external dependency or public access is needed. RuntimeEvents remains
event-only and contains no secrets.

A viable alternative keeps SecretBytes in ProxyKernel and puts the private
contract in a bridge, at the cost of configuration clients depending on the
kernel/bridge graph. Adding an app-to-bridge edge is not inherently forbidden;
its dependency cost is the tradeoff. Do not add a weaker duplicate secret wrapper
or a Shared-to-Kernel cycle.

If selected, record the private-codec exception and neutral-value placement in a
new refining decision referencing 0006/0014. Accepted records are not rewritten
into a different choice.

## Executed sizing input

The [test-only candidate](experiments/runtime-config-transfer/README.md) was run
against the actual Swift encoder and built foundation modules. All eleven
fixtures pass existing validation and reconstruct an equal runtime config.
Artificial tokens appear only in the provisional confidential encoding.

| Fixture | Safe candidate frame | Private URL frame |
| --- | ---: | ---: |
| Default in this probe environment | 2,381 B | 301 B |
| 40 upstreams + 40 DNS entries + 40 intercepts + 40 tunnels | 24,113 B | 301 B |
| 1,000 of each collection | 553,613 B | 301 B |
| 10,000 of each collection | 5,584,613 B | 301 B |
| 1 MiB UTF-8 profile | 1,050,950 B | 301 B |
| 1 MiB private health URL | 2,381 B | 1,048,869 B |

These are complete **provisional two-envelope** encodings, not raw-config size
claims or an accepted schema. The recommended single envelope has not been
encoded. The probe's generic JSON-value mirror is not the production typed DTO.
The chunk experiment checks frame sizes, not a production reassembly engine:
the 10,000-per-collection input uses 463 provisional 16 KiB frames across both
envelopes, versus 1,941 at 4 KiB.

No finite frame size covers every currently accepted unbounded string/count.
A larger frame alone does not resolve that. Configuration cannot be silently
truncated. Frame size, total staging, decode memory, active transfers and work per
turn need separate bounds. Bounded presentation summaries with an explicit full
inspection path are distinct from configuration transfer.

## Later gates, not selected by this proposal

- Choose frame/segmentation and total-transfer/staging budgets after the envelope
  shape. Any new configuration byte ceiling needs explicit owner approval.
- Complete canonical writer-authority coverage: RuntimeEnvironment permits
  outside config/platform/preferences/journal paths. Different state directories
  can therefore share a component. A per-directory lease alone does not exclude
  every overlap. Stable coordination identity must survive atomic data-file
  replacement and missing files. Active-handle bounds do not bound a permanent
  hash-lock directory; do not introduce an unbounded lock-file registry.
- Diagnostics destinations, such as auditLogPath, remain separate from mutation
  authority and cannot refuse runtime progress because a sink fails.
- Prove the actual store/client against independent bounded models, including
  delayed/unknown writes, partial coupled commits, Stop, late completion,
  disconnect and physical quiescence. Test OS leases with owned subprocesses.
- Listener handoff, total shutdown and production peer authentication/readiness
  remain their separate adoption/daemon milestones.

## Joint review

Claude reviewed the alternatives through the owner's claude.ai Max subscription;
Codex cross-checked source and executed the candidate encoder experiment. Both
recommend one private explicit request to remove pairing state. Codex corrected
earlier sketches that released input on caller timeout, coupled every file for
every edit, treated a non-Codable object as cross-process transfer, or let a
diagnostic-path lock gate startup. No such policy was implemented.
