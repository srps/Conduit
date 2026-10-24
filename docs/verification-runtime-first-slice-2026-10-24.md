# Runtime program: first implementation checkpoint, 2026-10-24

Scope: #23 isolated development bundle, accepted decisions 0013–0016 and the final
architecture inventory. RuntimeHost/client implementation and actor migration
have not started. No production version bump, install or helper change occurred.

Claude Code implemented the bundle/launch/test slice and corrections; Codex
reviewed the code, isolated the macOS path-spelling failure and reviewed fixture
containment. Every Claude run verified `loggedIn`, `authMethod=claude.ai`,
`apiProvider=firstParty`, `subscriptionType=max`, with API/provider overrides and
hooks disabled. No API key was used.

## Automated evidence

The targeted parser/composition and AppState harness run passed 118 tests. The
first full checkpoint passed all 39 checks corresponding to every executable
step of `.github/workflows/swift.yml`, including 2,343 Swift tests (two skipped,
zero failures), signed/unsigned updater fixtures, `pm-sim all`, security/protocol
regressions and `perf-gate.sh`. That checkpoint's relevant-source SHA-256 was
`8f615b9684d42ef7ae9784e877796b014420599e78bf7f7d545942fd3e1b4596`, unchanged
through that run. HEAD 75461e0 was the planning baseline with the implementation
uncommitted; the source fingerprint, not that baseline commit alone, identifies
the code checked.

Review then hardened the packaging fixture: checked substitutions redirect both
INSTALL_DIR and the absolute LaunchServices registrar into scratch before any
case runs. A copied guard is deliberately disabled, and the resulting install
must stay in scratch and hit only the registration stub. The hardened fixture
passed after review. Claude then reran all 39 gates on committed checkpoint
`a5123126e6951a0f604b2bbf1175f7ef804e38b0`: all passed, with 2,343 tests
(two skips, zero failures), all 85 `pm-sim all` results passing, and the performance
gate passing. Relevant-source SHA-256 remained
`f5a0ff50107ee93c1599387e71f841575255a3bbc3d8a15b47972d795c07ba8c` from start
to completion. Actual dev-bundle packaging/inspection also passed again.

The fingerprint covers sorted nonignored tracked/untracked paths and bytes under
Sources, Tests, scripts, .github and Resources, plus Package.swift,
Package.resolved, bundle-app.sh and VERSION. Binaries came from SwiftPM's reported
`--show-bin-path`, not an assumed old output directory. The latest full local logs and
structured results are retained under
`/private/tmp/conduit-architecture-20261024/dev-full-gates/`.

After that full run, the only code-file edit was adding the SPDX comment to the
new shell test; its syntax and behavioral packaging/containment test were rerun.
Documentation/evidence updates passed the decision gates again. Swift/runtime
source and compiled behavior stayed unchanged; the source hash above identifies
the full-run checkpoint rather than silently claiming later bytes were tested.

Actual packaging ran `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer zsh
./bundle-app.sh --dev`. Inspection confirmed the distinct display, app/helper/
updater identifiers, ad-hoc signatures and absence of a production update feed.
Malformed worker requests, chosen to stay side-effect-free even if identity
selection regressed, returned the dev-specific refusal before worker execution.

## Native development-bundle check

With corporate VPN off, opened the actual Conduit Dev.app using `open -n -a` and
only `--dev-state-dir` pointing to a fresh `/private/tmp/cd-dev-…` directory. No
`--dev` argument was passed. The native accessibility state identified the app as
Conduit Dev and its Popover preview showed Proxy, DNS and Tunnels stopped plus the
FakeMachine/scratch-state notice. The scratch log confirmed that composition.
Quit through that dev instance's Quit action and verified its process exited.
The production Conduit executable path and PID were identical before and after.
No notification permission prompt was accepted. The UI-inspection tool returned much
later than expected; that delay is not runtime performance evidence.

## Limits and next work

This validates development-bundle selection and isolation, not production daemon
ownership, corporate authentication, VPN transitions, or installed helper/update
behavior. Notification authorization, path and wake observation remain real OS
adapters. The focused dev-composition test exercises fake helper installation;
it does not independently exercise every credential or updater action.

No sanitizer conclusion or new suppression is claimed. #118 teardown/reproducer
investigation precedes substantial actor migration. Stage 1 next inventories
presentation fields and composition seams, then delivers typed client/codec/
subscription and lifecycle-event/model slices under decisions 0013–0015. Config
field classification/coupling, overlapping-writer ownership, listener handoff and
measured resource/shutdown limits remain explicit affected-slice gates.

## Review follow-up: aliases below the scratch root

Independent review found that checking the chosen state directory alone did not
protect against an existing child symlink. For example, a scratch `config.json`
could link outside the scratch directory even though its parent passed the
production-overlap check. Claude added refusal for each known runtime file and
the fake home/resolver roots, and repeated that check before composition creates
directories or seeds configuration. Aliases that resolve within the scratch root
remain supported. This is a point-in-time check of known components, not a tree
scan or protection against a concurrent symlink replacement.

The regression tests first failed for all 11 aliased components and a dangling
child. After the fix, all 19 DevLaunchOptions tests and the packaging fixture
passed. Codex then reran every executable workflow gate: all 39 passed, including
2,348 Swift tests (two skips, zero failures), all 85 simulator results and the
performance gate. The relevant-source SHA-256 was
`73f7caa622cd0387631df2533ed58204d4f6bf5907289991406ebbf26ba8979f` throughout.
HEAD was `7d1d2985b495413605559e50ee57d1dd7e5135fe` with the two implementation/test
files uncommitted; this fingerprint identifies the tested source. The logs at
the path above now describe this follow-up run.

A separate suspected case-variant bypass did not reproduce for existing paths:
Darwin `realpath` returned the stored spelling on this machine. No unconditional
lowercasing was added. A filesystem-sensitive regression permits distinct paths
on a case-sensitive volume and rejects an alias when the volume resolves it to
the protected directory. Nonexistent protected paths with different case, and
nested aliases below the fake roots, are outside this check's evidence.

The earlier native launch evidence predates this follow-up. The added refusal is
covered by parser and direct-composition tests; no new production or VPN behavior
is claimed, and no serving process was quit or replaced.
