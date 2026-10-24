# Private configuration foundation: verification checkpoint

Date: 2026-10-24. This verifies the neutral SecretBytes move and records the
selected private-request policy. It does not implement a private configuration
codec, transfer engine, store, writer lease or AppState adoption.

## Source and checks

Verified code commit: `bdf9bcfba9b06f156a0c1a19d41da84d84de98db`.
Relevant-source SHA-256:
`492e2da8d9dfe7ffde2226907c1f7b548d2901adae931f7eec3c99be15cf64b9`.
The source fingerprint covers tracked/nonignored Sources, Tests, scripts,
workflows, Resources, Package.swift/resolved, bundle-app.sh and VERSION. It was
unchanged throughout the full run. This record and the subsequent state-root
review are documentation-only additions.

All 39 workflow-equivalent gates passed: debug build, compiler import fences and
fixtures, notices, event catalogue and fixtures, decision/history checks and
fixtures, 2,510 tests (two skips; zero failures), worker entry points, install/dev
bundle/signing-script fixtures, unsigned and signed stand-in updater checks,
wire/redaction/security regressions, all 85 pm-sim results, outcome checks,
DNS shutdown/status checks and perf. The perf gate reported 10.22 seconds wall
time and 33,685,504 bytes maximum RSS. These are headless fixture measurements,
not private-codec memory/latency benchmarks or real corporate-VPN evidence.

Claude implemented and ran the focused verification through the owner's
claude.ai Max subscription (first-party claude.ai authentication; API overrides
removed). The focused run passed 86 secret/credential/auth/Keychain tests,
including 20 SecretBytes tests, plus the build, import fence and security simulator.
Codex ran the complete gates, checked actual results and independently reviewed
the patch. Decision checks were rerun after the partial implementation evidence
was added.

## Specific evidence

- The moved implementation in `Sources/ConduitShared/SecretBytes.swift` is
  byte-identical to the former kernel implementation on main; both SHA-256 values
  are `e1ccd5c05249cd5f7d4db3e9ef58b53f9d8cc808ad20837ce23348f1bfa1fdca`.
  The old kernel path contains a package typealias. Storage, redaction, equality,
  Sendable and zero-on-final-release behavior were not rewritten.
- The new identity test passes the Shared-qualified value through Kernel-alias
  signatures and back without conversion. Existing app/Auth/headless targets
  build, including callers importing both modules.
- A separate compiler-negative fixture importing only ConduitShared attempted
  to synthesize Codable around SecretBytes. Compilation failed for both Encodable
  and Decodable as required. This manual probe does not prove every possible
  future diagnostic composition is safe.
- The synthetic single-request probe compiled and executed successfully against
  the recorded foundation objects. All eleven fixtures validate and reconstruct
  equal runtime/platform values. Its generic JSON mirror is test-only; it does
  not implement the private-codec discipline in decision 0018.

## Decisions and remaining gates

Decisions 0018/0019 record the owner-selected single private request and eight-MiB
encoded-frame cap with independent Stop/status work. The cap is planned, not
enforced by this move. Existing file validation, v1 control and helper IPC are
unchanged. No new external dependency or public API was added.

The [canonical state-root review](design-runtime-state-root-review.md) remains
an owner-review proposal. Its narrower daemon split-path compatibility effect
must not be silently implemented. The diagnostic overwrite reproduction is
tracked separately in [#222](https://github.com/srps/Conduit/issues/222).

Still due: typed private values and explicit codec, actual transfer/working-memory
bounds, responsive admission/subscriptions, verified persistence with complete
writer coverage, stop-fenced apply, listener handoff and total shutdown behavior.
No serving app was replaced, helper installed or live-machine cleanup exercised.
