# Runtime configuration file boundary

Status: architecture reviewed with Claude Code using the owner's claude.ai Max
subscription. Strict grammar is accepted in [0024](decisions/0024-strict-configuration-file-grammar.md).
Cursor/reader foundations are implemented locally (537 focused tests passed);
file filtering and adoption remain planned. This is an implementation design, not another execution queue.

## Ownership and operations

- **ConduitShared lexical cursor:** strict JSON syntax, UTF-8, escapes, decoded
  scalar callbacks and bounded iterative skipping. It owns no field tables,
  component policy, wildcard rule or resource ceiling. The private scanner uses
  these mechanics instead of retaining a parallel lexer.
- **ConduitShared resource policy:** existing `DomainResourceField`, counters and
  the single typed `DomainResourceCheck.configuration` traversal. Streaming file
  and private adapters map format positions to those fields. Reuse scalar-budget
  bookkeeping where needed; do not copy prefix/width/limit policy into each lexer.
- **ProxyKernel persistence:** bounded runtime-file reader, file schema/filter,
  original-version envelope, in-memory migration and legacy component extraction.
  Its normal operation accepts a file URL or supplied bytes through the same
  format boundary. File acceptance does not imply runtime eligibility;
  `ProxyConfig.validate` continues to own runtime semantics.

The reader opens read-only/nonblocking, checks the opened descriptor is a regular
file, and bounds the actual read to 8 MiB with a cap+1 probe. Metadata is a hint,
not the bound. Symlinks keep following their target, which must be regular.
IO/close failures are surfaced. This selects no new sidecar or journal byte cap.

## One frozen document

A filter checks strict grammar throughout and retains only the first occurrence
of required known keys. Unknown and later duplicate values are strictly skipped
without object expansion. Required component tables derive names from the actual
file decoders, including nested objects. Resource checks happen while reading
known values, before typed allocation, using the neutral policy.

A typed envelope obtains both the original schema version and `ProxyConfig` from
one Foundation decoding operation. Missing original version remains 0 for migration,
although `ProxyConfig` itself defaults to the current version. Integral spelling
such as 2.0 follows the existing Int decoder; the byte cursor does not reinterpret
schema versions. Remove the separate `SchemaVersionEnvelope` parse.

The loader derives required components from its own reads: runtime always, legacy
platform/preferences only where the corresponding sidecar is absent. Runtime-only
import and headless/argv input do not start type-checking unused legacy component
fields. Strict syntax still covers all bytes. Legacy extraction uses this frozen
input, never another read of the runtime path. Stage all candidates before any
migration write, retaining the existing write order.

## Adoption and evidence

Replace the runtime `Data(contentsOf:)` read, legacy extraction path rereads,
AppState's raw import decoder and argv's separate migration behavior. Keep import
runtime-only. Newer schemas fail through the same file-format gate before editor
assignment. Ordinary saves check resources before encoding and use the selected
exact schema-two staging; save/apply coordination stays with the forthcoming sole
workflow/store.

Test the actual readers/adapters, nonregular inputs, growth after stat, first and
escaped duplicate keys, required-component behavior, original-byte preservation,
missing/integral schema versions and migration staging. Single-violation resource
cases must agree with the typed check. With multiple violations, an early byte
scanner can report input order while the typed walk reports its defined order;
that does not justify duplicating policy or delaying early refusal.

The [pre-change witnesses](experiments/config-file-preflight/README.md) establish
ignored-value tolerance and a limited Foundation depth observation. Pin depth
against the actual file decoder. Neither those probes nor the planned APIs prove
memory/RSS bounds, complete adoption or release readiness.
