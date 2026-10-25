# Verification: GUI startup handoff (2026-10-25)

Branch `codex/gui-startup-handoff`, based on `main` at fc8e420 (PR #236).

## Status

The focused suite, app-entry regression, actual built-entry refusal probes and isolated native callback smoke pass. Full local workflow passes on the startup-only source; combined-source and hosted checks remain pending. This is a startup correction, not shared-host adoption or release readiness.

## Root cause

PR #236 made the process entry `@MainActor static func main() async`. It awaited `PreparedAppLaunch.prepare()` and then called `ConduitApp.main()`.

An `async` `@main` entry runs as a MainActor job, drained from the main dispatch queue. `ConduitApp.main()` is `NSApplicationMain`, which runs a nested run loop inside that job. While the job is executing, the main queue cannot run its next item, and MainActor jobs are enqueued on the main queue. Queued main-queue work and MainActor tasks therefore never run.

Evidence:

- Standalone AppKit probes, identical except for the entry (three-second watchdog, no Conduit state or machine access). Synchronous entry: the main dispatch block, the MainActor task and the background watchdog all fired. Async entry after `Task.yield()`: only the background watchdog fired.
- Native sample of the owned dev process: `NSApplicationMain` ran under ConduitMain's async task.
- The native log-protection smoke opened windows and preserved config bytes, but its background refusal never reached stderr. That feature lives in another checkout, and this note does not verify it here.

## Fix

Synchronous entry, one private bootstrap slot.

- `Sources/Conduit/App/ConduitMain.swift` (new file, the only `@main`): `static func main()` is synchronous and `@MainActor`. It runs the dev worker refusal, the update and Kerberos workers, then `PreparedAppLaunch.prepare()`, then `ConduitApp.main()`. The order is the same as before.
- `Sources/Conduit/App/PreparedAppLaunch.swift`: `prepare()` is synchronous. It starts a `Task.detached` that runs the existing `StateRootBootstrap.acquire` through the existing `PlatformWork` queue. The main thread waits on a file-private `BootstrapResultSlot` (a semaphore and a lock, one fill, one take), then pins the single result or exits with its refusal. Parsing, refusal exits and the single pin are unchanged.
- The bootstrap's file system and lease effects still run on `PlatformWork`. The main thread blocks only before any UI exists, and nothing else is queued to it while it waits. The wait is unbounded, as the async `await` was. No timeout or policy was added.
- `ConduitApp.swift`: the old entry enum is removed, and nothing else in it changed.

## Alternatives rejected

- Keep the async entry and dispatch the GUI to the main queue, or wrap it in a Task. Still a main-queue item, so the same starvation.
- Run AppKit on another thread. AppKit requires the main thread.
- Pump the RunLoop while waiting for the bootstrap. Would let main-queue or MainActor work run before the authority is pinned.
- Bootstrap synchronously on the main thread. Puts file system and lease effects on the UI thread.
- Start the UI before the authority is taken. `AppState.forLaunch()` runs during `ConduitApp`'s init, so this needs lazy state and a policy change.
- Change the daemon. `ConduitDaemon` parks in a continuation with no nested run loop, so its main-queue signal sources still fire. Not changed.

## Regression

`scripts/test-app-entry.py`, run as a CI step after "Run tests" in `.github/workflows/swift.yml`.

- Compiles the unchanged `Sources/Conduit/App/ConduitMain.swift` with `swiftc -swift-version 6 -parse-as-library -sdk <macOS SDK>`, beside stand-in modules in `scripts/app-entry-fixtures/` for `ProxyAuth`, `PlatformMac`, `DevLaunch`, `PreparedAppLaunch` and `ConduitApp.main`. The stand-ins touch no AppKit, state root, helper or Keychain.
- Child-process checks: production order (prepare, then present, then both main callbacks); kerberos and updater workers run before preparation and exit with their status; dev worker refusal before any worker or preparation; refused root exits before present.
- Negative controls, compiled from a mutated copy in a scratch directory: `async-entry` (the entry becomes `async` and yields first) and `dispatch-to-main` (the `ConduitApp.main()` call is queued with `DispatchQueue.main.async`, then `dispatchMain()`). Each must fail with "present callbacks missing".
- Bounds: each child has a 20 s timeout and each compile a 300 s timeout. The fixtures print a fixed, finite number of lines; the captured output is not capped.

## First SDK failure (fixed in the script, not the product)

The wrapper's first run compiled the product (`swift build` passed in 6.96 s). The regression script then failed compiling the first stand-in: `unable to load standard library for target arm64-apple-macosx26.0`. The script ran `swiftc` without `-sdk`. The fix resolves `swiftc` with `xcrun --find swiftc` and the SDK with `xcrun --sdk macosx --show-sdk-path`, passes `-sdk` to every compile, and stops with the diagnostic if a lookup fails. The old bare-`swiftc` fallback is gone. `DEVELOPER_DIR` comes from the wrapper.

## Passing scope

- Wrapper `verify-gui-handoff.sh` on the rerun: PASS. It runs `swift build`, `scripts/test-app-entry.py`, the focused `swift test --filter 'RuntimeStartup|StateWriter|StateRoot|StateDirectoryLease|RuntimeEnvironment|DevLaunch|AppStateHarness|DaemonRuntimeHost'`, then the kernel-import, event-catalogue and decision-record checks. The wrapper runs under `set -e`, so PASS means each step exited 0.
- Focused suite: 291 tests, zero failures (reported by the parent from the wrapper's `tests.log`; `tests.log` itself was not re-read for this note).
- `app-entry.log`, read directly: the five positive checks and both negative controls PASS.

## Remaining limits

- The full local workflow passes below; the new CI step is not yet exercised on a hosted runner.
- The subprocess regression uses stand-ins for the bootstrap; separate actual built-entry probes below cover the real preparation path.
- Native proof below covers a debug FakeMachine composition on this machine, not installed production behavior or all AppKit callbacks.
- The stand-in tests use a three-second deadline. A very slow runner could make a positive check fail; that would show as a timing failure, not a silent pass.
- The existing pre-UI filesystem wait has no new deadline or physical-I/O bound. No new runtime queue or cancellation behavior is selected.
- Accepted decisions 0017 and 0028 retain partial implementation status: full store/workflow writer coverage and mixed-version handoff remain open.


## Independent source review and actual process evidence

A separate official Claude Code session authenticated through claude.ai Max reviewed the frozen source read-only and found no blocking findings. It traced the bootstrap effects and found no main-queue dependency, checked one-shot result/lease lifetime, worker ordering, the moved entry and both negative controls. It did not execute tests. Its report is `gui-startup-handoff-peer-response.md` under the scratch evidence directory. Non-blocking observations: the semaphore also orders the result, though the explicit lock is retained for clear field confinement; each compile has its own ceiling while the CI step's 15-minute ceiling is the aggregate outer limit. The aggregate CI deadline can report a step timeout before every individual ceiling is exhausted. No stronger script-wide timing claim is made.

The parent inspected the actual focused test output: **291 tests, zero failures**. Frozen relevant-source SHA256: `e20ab18dfd789f438e934373338ef746477a52ba3120e887f20d755f94fa3ca2`.

The built Conduit and ConduitDaemon passed all four real scratch-entry probes: daemon busy and dev-app busy exit75, custom writable name and split writable root exit78. Original configuration bytes were preserved and no unexpected migration, diagnostic, preferences or recovery files appeared. This exercises the real bootstrap, not the script stand-in. Binary identities and detailed outcomes: `/private/tmp/pm-startup-proof-ulrnsrt1/result.json`.

The parent built the separate ad-hoc `Conduit Dev.app` and launched it with `open -n` on `/private/tmp/pm-gui-handoff-r3292jqb`, with a valid scratch config and a directory at `proxy.log`. The existing asynchronous writer's open failure had to return through `Task { @MainActor }` before stderr could report it. The actual app reported FakeMachine, presented the preview/DNS windows, delivered **File logging is not recording**, and processed a subsequent network-path callback. Config SHA256 remained `1e834dbe0d098d039a5679d76feb6fbe0c4692b577a0928c697eb4da5aa62049`; the log directory remained intact. The bundle executable SHA256 was `aee8d158f8421c96db2cfe7bd3bed0a9864f9ca76a414e549689ecc03ceba675` and stayed unchanged. A process sample places NSApplicationMain beneath the synchronous ConduitMain entry, outside an async-main task.

The initial 20-second observation ended before startup logs appeared; the owned process remained live and was observed further without restart. The later callbacks came from that same PID68749. Both observations are retained in `gui-handoff-native-first-observation.json` and `gui-handoff-native.json`; raw output and the sample are alongside them. Only the verified dev bundle was then asked to quit, and its exit was confirmed. Serving PID35326, start time and executable path remained unchanged. This native probe uses the pre-log-protection writer and is not a combined #238 collision acceptance proof.


## Full local workflow on the startup-only source

All **40 checks** passed on unchanged relevant-source SHA256 `e20ab18dfd789f438e934373338ef746477a52ba3120e887f20d755f94fa3ca2`: **3,233 tests, two skips, zero failures; all 98 simulator records passed**, plus the new subprocess app-entry regression, packaging/signing stand-ins, updater checks and existing proxy performance gate. The runner exited0 and confirmed identical initial/final fingerprints. Logs and commands: `/private/tmp/conduit-runtime-stage1-20261024/gui-handoff-full-gates/results.json`. This source was based on fc8e420; combined verification after merged log protection is a separate checkpoint. The doc-only evidence updates do not change that fingerprint. Hosted PR checks remain pending.
