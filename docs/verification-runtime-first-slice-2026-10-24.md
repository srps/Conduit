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
passed after review. Final full-gate evidence follows after committing this slice;
the earlier checkpoint is not claimed to validate the later test-script bytes.

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
No notification permission was changed. The UI-inspection tool returned much
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
