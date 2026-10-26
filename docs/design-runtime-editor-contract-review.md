# Private editor and client integration: next-cut review

Status: proposal for review, 2026-10-26. No new owner decision or implementation
is implied. The shared-host workflow slice is verified separately; AppState
still owns its runtime and writers. Accepted decisions 0014/0015/0018/0025/0027/
0031/0032 govern this proposal. The production daemon socket remains later work.

## One owner, one client path

RuntimeHost and its private workflow/store serve the app through the actual framed
RuntimeClient. Add no AppState save coordinator or direct in-process mutation
shortcut. The service adapter consumes the host instead of becoming a second
runtime owner. Use one host incarnation across host, workflow, service and
observations; the store's baseline namespace has a separate authority purpose.

An editor observation captures current runtime, platform and preference values
with matching per-component baselines in one owner turn. Its component state must
distinguish verified, permitted absence and retained last-known values; it must
not manufacture authority for a failed observation. A baseline carries its exact
namespace, component and UInt64 version, without narrowing it into Int-based
control ordinals. The existing v1 configuration generation keeps its accepted-view
meaning and is not reused as a persistence or applied-state token.

Ordinary editor reads use this memory observation. Only explicit reload observes
disk and reconciles eligible changes. A different client's reload cannot replace
a dirty draft or refresh its original save preconditions.

## Private values and operations

Extend the existing explicit private codec rather than putting frozen configuration
values or private URLs in ordinary control messages. Use the same private exchange
through the real in-memory transport now and a later socket. Its work and capacity
must remain independent of Stop/status. Ordinary operation lookup/events retain
bounded safe metadata and handles, not the configuration body.

Separate operations by selected semantics:

- Runtime/platform updates carry the full frozen input, relevant component
  baselines and explicit lifecycle intent. The sole store supplies exact verified
  inputs; mixed apply remains held until all required inputs verify.
- Preference updates use their own component baseline and no runtime lifecycle
  generation or apply. A preference failure cannot veto independently verified
  runtime work.
- Private reads return a coherent memory observation. Reload is a distinct
  deliberate action, with ordinary safe outcome metadata and private values
  returned only through the private channel.

Keep launch-at-login as app administration, while persistence still goes through
one store. Its field shares platform.json today: use a narrow administrative
operation under that component's precondition and preserve its current value
when a runtime/platform edit does not express that administrative intent. Do not
add a direct app writer or let an old draft restore the flag accidentally.

Only a causal receipt for the matching submitted update may advance that draft's
baselines. Preserve edits made after submission. Snapshots and ordinary reads do
not retokenize dirty drafts; explicit reload/review remains conflict recovery.

Quit fences the runtime immediately and closes ordinary admission. Reserve one
final flush of the client's latest valid local draft, whether already submitted
or still waiting on autosave. It uses the same private runtime/platform and
preference operations and sole store, within one total Quit deadline, and is
never applied. Its reserved write claim must survive the Quit fence until that
flush window closes. Preserve lifecycle intent from before Quit and write no
disable. Invalid drafts do not block Quit; writes already started may complete.
There is no direct app save or second writer. Stop fences control before
persistence, and late writes cannot restore stopped enable intent. Ordinary knob saves under a
Stop fence must not implicitly re-enable a module. Map the interactive per-module
commands to the already selected per-module intent/fence policy; the current
whole-host process-start facade is not the final interactive API.

## Before the AppState switch

1. Select the affected limits below from measurements; finalize the concrete
   private observation/update/reply values with codec and compatibility fixtures.
2. Connect the actual host to the existing service/client, implement private
   editor operations and consolidate administrative/preference saves in the sole
   store. Inventory every AppState presentation/preflight read and command.
3. Verify DNS/intercept, tunnels and proxy together: recovery, retries, helper and
   platform effects, mixed changes, draft conflicts, partial persistence,
   supersession and shutdown. Keep real-host and AppState twins until parity.
4. Activate AppState once. It retains drafts, presentation, notifications, updates
   and AppKit administration; delete its replaced orchestrator, runtime/reconciler/
   observer and direct-save paths in that integration change. Then consolidate
   the twin tests into shared coverage plus thin composition/client tests.

RuntimeActor is the selected step after convergence, moving the whole control
cluster together. Production socket/LaunchAgent handoff and real-machine release
acceptance remain separate work; none is proved by this proposal.

## Interactive admission still to implement

Put host-owned store operations in generation order within bounded ordinary
admission. A Start waiting behind an in-flight operation rechecks its ticket and
fences before acting; newer Start/Stop supersedes it. Refuse capacity before
changing lifecycle intent, distinguish capacity from persistence failure and
retain Stop's independent capacity. This follows 0014/0015, rather than adding a
new owner policy or a second unbounded queue.

The current process-start facade is not ready to expose unchanged to interactive
clients: a busy store is reported as commitFailed after Start has cleared the
fence. A later reload can then pass that fence. There is one production daemon
Start call, a held daemon Start exits the process, and no production reload
caller today; concurrent cases currently
exist only in tests/scenarios. Before service/client adoption, cover capacity
holds retaining a prior Stop fence and genuine persistence failure followed by
reload, alongside runtime/platform updates. The model and host admission tests
must evolve with that integration.

Complete the preference and narrow administrative platform commit operations,
per-module intent/fences and reserved Quit flush before the app switch. They use
the same store and private path. The current whole-host startup generation is
not a substitute for the selected per-module interactive contract.

## Decisions and design gates

- **Private editor reply ceiling:** unselected. The request cap stays 8 MiB;
  ordinary reply/stream frames stay 64 KiB. Measure full observations, metadata,
  worst escaped fields and allocation lifetimes before recommending the private
  reply cap. A request measurement or a mirror is not an implemented reply codec.
- **Production service profile:** remaining queue, retained outcome/replay,
  subscriber, per-turn work, deadline and shutdown values are unselected. The
  existing coherent candidate is test-only; validate the actual host adapter
  before asking for shipping values.
- **Conditional later choices:** bind-new/repoint/retire listener handoff needs
  owner selection before changing current behavior. Whether a bounded #194
  applied-state expansion joins the release is also a scope decision. Neither
  justifies silently introducing independent effect groups or blocking an
  otherwise behavior-preserving host migration.

Concrete type names and exact field inventory remain review work. Implementations
must use the selected module boundaries and private channel, with no registry,
parallel writer, public test hook or new dependency.
