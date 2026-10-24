# Runtime client and typed lifecycle foundation: verification checkpoint

Date: 2026-10-24. Scope: the stage-1 foundation on `codex/runtime-client-events`,
not the complete RuntimeClient implementation or the 0.6 release.

## Source identity and checks

- Verified commit: `d438d01ebe23bd738c15ba7922bd8f32602d427f`; base includes PR #218 (`bba6ca3`) and
  PR #219 (`230681e`). Later documentation commits do not change the verified source.
- Relevant-source SHA-256 before/after: `b3c8e71c7110ff39c8f2e9d16593eb407c52b7c47ef3b7bc2bf5588c0fd3d2d8`.
  Includes Sources, Tests, scripts, workflows, Resources, package files, bundle
  script and VERSION; the fingerprint was unchanged across the complete run.
- All **39 workflow-equivalent checks passed**, including build, compiler import
  fences and negative fixtures, licence/event/decision checks and their fixtures,
  Kerberos workers, argument/signing/dev-bundle scripts, both updater stand-in
  end-to-end variants, security/routing/resource/standalone-shutdown regressions,
  HTTP target preservation, simulator outcome checks and the performance gate.
- Full XCTest: **2506 tests, 2 skips, 0 failures**.
- `pm-sim all`: **85 results passed**. The lifecycle scenario has seven
  assertions; update-coordinator has fifteen, including malformed metadata.
- Performance gate passed: 10.13 s wall,
  36143104 bytes max RSS. This is the existing bounded
  streaming regression, not a benchmark of future transport or actor isolation.
- Commands follow [swift.yml](../.github/workflows/swift.yml), with
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`. No installed Conduit
  or helper was stopped, replaced or installed; no VPN was needed.

The runner and complete per-check logs are under
`/private/tmp/conduit-runtime-stage1-20261024/full-gates/` (`results.json`,
`swift-tests.log`, `pm-sim-all.log`, `perf-gate.log` and the other named logs).
The command manifest is `full-gates.py` beside that directory. Temporary logs
are local evidence, not durable repository artifacts.

## Implemented scope and review

The four emitted `lifecycle.*` names now have typed domain/wire values through
producer, kernel envelope, bridge and semantic consumer assertions. Other event
families remain legacy. The Foundation-only RuntimeEvents fence uses the Swift
compiler; the catalogue fixture suite accepts 16 benign changes and rejects 55
mutations. Its tokenizer covers recognized string forms, while the runtime legacy
initializer remains the authoritative guard against computed untyped lifecycle names.

The production LifecycleLane is compared with an independent reference model:
904 states / 2,628 histories through depth six, with three held operations and two
idle waiters, under a 20,000-state budget. 531 states are new at the depth bound,
so this is not a fixed-point proof. There are also 200 seeds of 40 steps. Four
adapter defects have shortest witnesses of one/two/two/two steps. These are
adapter mutations, not production-source mutations; a corrupt continuation
cannot be forcibly resumed by the harness.

The package-internal async client protocol, v2 values/strict codec, snapshot
projection and byte-bounded page packing are foundations only. Request recovery,
incarnation and correlation are represented; an actual engine must enforce them.
There is no production or in-memory RuntimeClient implementation, admission or
subscription engine, config commit/start DTO, or production v2 socket. V1 and
helper codecs retain their version/format. The new v2 Date codec uses Unix epoch
seconds; a literal-wire test observed two failing assertions before that repair,
even while a same-codec round trip passed.

Claude implemented and verified through authenticated `claude.ai` Max CLI runs;
API credentials/providers were excluded. Codex reviewed actual patches and log
results. An independent Claude source review found no demonstrated production
regression in this foundation, and identified two corrected issues: a no-transport
test client fabricated host answers, and the static checker missed a split literal.
Codex observed the old checker pass the split-name fixture and the new checker
reject it. All 39 checks were rerun after these corrections; the earlier green
source (`a1bfe768`, SHA `726ea300…`) is separate evidence, archived under
`full-gates-before-review-corrections/`.

## Remaining gates and limits

- No shipping frame/page/queue/retention/deadline defaults were selected. Raw
  persisted-config measurements in the [inventory](runtime-client-stage1-inventory.md)
  are not full config-command measurements or a largest-valid-input bound.
- Before engine adoption, retain bounded immutable collection versions, avoid
  whole-collection projection on every page, bound scalar presentation with an
  explicit full-inspection strategy, and handle oversized known events without
  blocking control. The current helpers are not a responsive subscription engine.
- Future informational typed families need tolerant file/pmctl handling before
  those families ship; the v2 wrapper already retains bounded redacted unknown
  display records and rejects contradictory known payloads.
- Save-before-apply remains planned. Decision 0017 selects writer exclusion;
  no lease/lock code or new persisted revision schema is included here. Config
  projection/coupling, alias coverage, listener handoff and measured budgets remain
  affected-path work. No full pinned-snapshot registry was selected.
- Unit/model/simulator evidence is not owner or serving-machine validation,
  does not close sanitizer #118, and does not prove daemon ownership or real
  Keychain/Kerberos/CFNetwork session behavior.
