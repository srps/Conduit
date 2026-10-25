# Protected runtime artifacts: implementation checkpoint

Status: proposed implementation API, reviewed with Claude Code through the owner’s claude.ai Max subscription. No source implementation. This applies the existing diagnostic-protection policy in decision 0020 and issue [233](https://github.com/srps/Conduit/issues/233); it selects no new filename or snapshot-size policy.

## Confirmed failure

An owned scratch run of the built pm-proxy at the source merged by PR 232 used a configuration containing `{"schemaVersion":2,"witness":"original-intent"}` at `snapshot.json`. Running with `--state-dir SCRATCH --config SCRATCH/snapshot.json --port 0 --socks-port 0 --dns-port 0 --exit-after-ready` exited successfully and replaced the configuration with the runtime snapshot. No installed app, helper, credentials or machine settings were touched.

RuntimeHost has the same direct snapshot replacement. App log append/rotation is also outside the existing audit/events guard; that is source evidence, not yet an executed log composition reproduction. Fixed writable names would remove the direct name case, while filesystem aliases and arbitrary read-only inputs still require protection. Decision 0020 continues to permit custom writable config names until the owner chooses a replacement policy.

## Focused ownership

- Reuse `RecordFileDestinationGuarding`, `RecordFileDestinationGate` and the one protected-resource map. The gate owns latching/reporting, the guard owns metadata checks, and a physical writer owns encoding and file effects. No second path parser or collision policy.
- Keep the snapshot writer in ProxyKernel’s existing portable diagnostic-file family, using Foundation/Dispatch filesystem support. It takes a protocol and returns a protocol through a factory. This is not authority for helper, resolver, system-settings or other machine effects in the kernel.
- RuntimeHost and pm-proxy use the same snapshot writer. Encoding, guard inspection and replacement run on its serial drain, off the runtime owner. At most one snapshot is active and one latest value is pending; updates coalesce without a per-update task or an unbounded queue.
- Count bounds are structural. Raw snapshot strings and encoded bytes have no newly selected ceiling. Record measured encoded sizes and retained-value behavior; do not describe this as a process-memory bound or silently impose a new legacy snapshot-file limit.
- A destination refusal latches once and emits the existing structured refusal before its derived log line. Later submissions do not reopen the destination. Other write/encoding errors and recovery remain observable, without reflecting snapshot values.

## Flush and integration gates

The exact async composition remains to be finalized before adoption. Waiting must leave the runtime owner available. Preserve a finite physical-work reservation until it really ends; caller cancellation/timeout cannot free it early or release writer authority.

Reuse one absolute deadline for the diagnostic phase rather than adding a fresh readiness timeout or nested retry. Today the audit/events phase can wait 2 + 2 + 2 seconds, with the logger’s separate 2 seconds afterward. This is an existing diagnostic envelope, not the total shutdown budget. Preserve audit/events priority when adding snapshot flushing. Report exact queue/write/timeout facts; an empty queue after a refused or failed write is not proof the snapshot file is current. A timeout marker gets only the remaining budget, and its persistence must not be claimed without confirmation.

The ready file currently precedes snapshot output. It supplies no promise that a snapshot exists when that file becomes visible. Preserve the existing snapshot-at-return/terminal-exit behavior when the relevant write and flush actually succeed; report partial outcomes otherwise. No power-loss durability, whole-process shutdown bound or forced cancellation of physical I/O is established. Total shutdown remains the separate reviewed #47 gate.

## Verification and remaining slices

Use deterministic held-worker tests for coalescing, one scheduled drain, refusal latching, error recovery, timeout without a second wait, and the distinction between drained work and successful output. Verify guards/encoding do not execute on the main thread. Actual scratch host/headless tests must preserve config bytes for direct names and supported symlink/hardlink aliases, keep serving, and cover final state at exit. Run all workflow gates before pushing.

Rotating logs are a separate focused follow-up: protect the active file and every rotation source/destination plus the opened descriptor, attach the canonical event log before opening, and stop retrying a latched refusal. Updater metadata and legacy DNS import remain administrative/recovery owners; they are not relabeled as diagnostics.

Startup lease adoption follows protection: acquire off the owner before migration/recovery, use resolved authoritative paths everywhere, retain one authority at the executable boundary until actual process exit, and refuse busy before constructing a host. Store adoption must replace the legacy migration writer directly using the shared frozen loader and verified commits, rather than add a second observation/write path. Pending migration rewrites need an explicit internal fact; AppState receives a client through staged shared-host composition and never gains a concrete store API.
