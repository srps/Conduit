# Verification: platform and preferences sidecar boundary (2026-10-24)

Scope: [decision 0026](decisions/0026-bounded-platform-and-preferences-files.md), partial implementation on branch
`codex/bounded-configuration-sidecars`. Synthetic scratch files only. No real configuration, serving app or helper was read or changed.
This is not owner or real-machine validation, not the sole store, and not a release check.

## What ran

One run of `bash /private/tmp/conduit-runtime-stage1-20261024/verify-sidecars.sh` on the final source. It exited 0 and printed
`PASS: sidecar checks`. Logs are under `/private/tmp/conduit-runtime-stage1-20261024/sidecar-checks/`.

| Step | Result |
| --- | --- |
| `swift build` (DEVELOPER_DIR set) | Build complete on the rerun. The first run warned about a redundant `as` test in the new reader catch; that catch is now typed and the rerun printed no warning for the changed files. |
| `swift test --filter 'ConfigurationFile\|ConfigSaveGate\|AppStateHarness\|Preferences\|ConfigMigration\|ConfigExactPersistence\|Resource\|JSONByteCursor\|VerifiedRuntimeFileReplacement\|Sidecar'` | 297 tests, 0 failures, 0 unexpected. Includes 28 `ConfigSidecarBoundaryTests` and 2 `AppStateHarnessSidecarRefusalTests`, each passing in the log. |
| `check-kernel-imports.py` | Passed (103 Swift files). |
| `check-event-catalogue.py` | Passed (207 names). |
| `check-decisions.py --require-history` | Passed. |
| `test-decisions.py` | Passed. |
| `pm-sim config-file-boundary` | PASS, 13 of 13 assertions. |
| `pm-sim runtime-file-replacement` | PASS, 17 of 17 assertions. |
| `pm-sim config-sidecar-boundary` | PASS, 29 of 29 assertions. |

Earlier runs on an earlier source state found one warning from the reader catch. That state was replaced by the rerun above.

## What the checks cover

- Physical budget: a platform sidecar of exactly 131,072 bytes loads, and one byte over is refused standalone and combined, with
  its bytes kept. A preferences sidecar behaves the same way.
- Raw browser URL: 16,384 bytes loads and 16,385 is refused, on read and on save. Whitespace counts before the blank fallback.
  Escaped characters count by their decoded bytes.
- Worst approved output: 16,384 control characters stage at exactly 98,304 bytes more than an empty URL, under the budget, and read back
  unchanged.
- Strict grammar: raw controls, invalid UTF-8, lone surrogates and bad escapes are refused in ignored values and later duplicates. A first
  escaped spelling wins. An ignored `1e400` is accepted. Retired platform fields and a 60,000-element unknown array are accepted and
  discarded.
- Wrong kinds: every known platform and preferences key refuses `[1]` without falling back to the runtime's legacy value.
- Runtime and sidecar parity: the same accepted bytes decode to the same platform value on both paths.
- Migration: an over-limit legacy preference refuses before any write. One unstageable runtime candidate, a finite duration past the
  runtime range (`healthCheckIntervalSeconds: 1e300`), starts no sidecar write and keeps the runtime file. Staging failures are
  reported as their own warnings.
- Saves: an over-limit preferences save creates no directory and leaves the previous bytes. A save writes exactly its staged bytes.
- App presentation: a refused preferences save leaves the runtime save and apply intact, keeps the edit unsaved, and names only the
  file and field. The banner, the events and the diagnostic log never contain the private URL marker. A refused startup sidecar blocks
  saves and keeps both files' bytes.
- Named pipe sidecar: refused without blocking.

## Limits and not run

- `pm-sim all`, `scripts/perf-gate.sh`, the full `.github/workflows/swift.yml` sequence, and the other `scripts/check-*` and
  `scripts/test-*` checks were not run here. The parent owns the full workflow and the release decision.
- No real-machine, owner or release validation is claimed. The async store, physical sidecar replacement, writer adoption and
  startup adoption beyond these reads are not implemented.
- File names still say `Runtime*` where the shared reader, filter and schema now serve sidecars: `ConfigurationFileReader.swift`,
  `ConfigurationFileFilter.swift` and `ConfigurationFileSchema.swift`. The types inside are `ConfigurationFileReader`, `ConfigurationFileGate`,
  `ConfigurationFileFilter` and `ConfigurationFileSchema`. Renaming the files is a mechanical follow-up.
- The 16 KiB URL check and the 128 KiB sidecar budget do not establish memory or RSS bounds. No global memory claim is made.

## Independent review corrections

The first complete 39-check workflow passed on `9591dfe` after the mechanical file
renames and rebase onto PR #229. Static independent Claude review found no blocking
production defect, but found six lost escape fixtures: ASCII input had replaced
escaped JSON strings/keys. The corrected fixtures build their escape bytes
explicitly and assert encoded widths. New witnesses cover a multibyte browser URL
at the exact decoded UTF-8 limit and one over for both read and save, and a later
over-limit duplicate ignored without charging its field budget.

The simulator now checks FIFO creation, preserves its errno on failure, and cleans
its scratch root on throws while reporting cleanup failures. Unexpected witness
errors are reported. Standalone migration warnings reuse the existing formatter.
Whitespace-only URL defaulting is existing behavior preserved by 0026, not a new
normalization or exact-preferences round-trip policy.

The corrected focused wrapper passed 299 tests (30 sidecar boundary tests and two
AppState harness refusal tests), the import/event/decision checks, and all three
focused simulator scenarios (13/17/29 assertions). The complete workflow must still
run on this corrected source; the first run is archived separately. These checks
are not owner/real-machine validation or release readiness.
