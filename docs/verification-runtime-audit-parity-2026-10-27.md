# Shared-host connection-audit parity

Status: local implementation checkpoint, 2026-10-27. This is a prerequisite for
the selected single AppState activation (0031), not that activation or a release.
Claude Code implemented and independently reviewed the slice through the owner's
authenticated claude.ai Max subscription. API/provider overrides were cleared;
no API fallback was used. The serving 0.5.8 app and installed helper were untouched.

## One audit owner

RuntimeHost now constructs its one audit sink from the verified startup config
and passes it to its existing orchestrator. Disabled remains discarding. Enabled
uses the configured path, or audit.ndjson under the state root, and the existing
size bound. The existing connection-audit destination guard protects config,
sidecars, journal and the live writer lease, including aliases. The sink shares
the host's existing logger and event log; refusal events reach file and client
observation through the existing feed. The shared diagnostic phase already
awaits this sink. No extra writer, callback or loader is added.

This preserves the app's startup behavior: reload does not rebuild the audit sink.
No live reconfiguration, new path expansion or retention policy is introduced.
AppState keeps its old construction until the single switch deletes that path.

## Verification

Seven actual-host tests use explicit fakes, framed Start/Stop and loopback requests:
redacted default output, disabled output, explicit external output, configured
byte refusal, and protected lease/config/platform aliases. They preserve protected
bytes/inodes, prove the refusal reaches the stream and file, and keep serving
through Stop. The simulator reuses its existing origin/client fixtures and proves
a served DIRECT request yields one redacted audit row.

Both focused checkpoints pass 144 tests with no failures and the two affected
simulator scenarios. The final checkpoint passes 132 actual-host assertions, 10
destination-guard assertions, the 229-name catalogue and diff checks. Earlier
static review found that an unexpected error could skip intended simulator
checks and still pass cleanup. Eight outer catches now explicitly fail while
retaining cleanup. Expected nested refusal paths remain unchanged.

[The forced-read-error witness](experiments/runtime-audit-error-witness/README.md)
executes that corrected error path and exact restoration. Independent final
review accounts for it separately from the happy-path checks. The [complete local workflow](experiments/runtime-audit-workflow/README.md) passes
all 41 checks on stable source `bfe8922152d7121489633b72d63c1e7163047f7c`: 3,692
Swift tests (four skips), all 103 simulator records, perf, packaging, process
regressions and boundary checks. Rebasing onto merged PR256 changes no source/test/script/workflow/resource bytes;
[provenance](experiments/runtime-audit-workflow/rebase-provenance.json) records the
same fingerprint. PR257 merged as `d7d47d4f3e918ed9c96ec3ec9ebfcc55da758813` after
exact-head hosted Swift and CodeQL passed on
`9de34e050b07fd1717eabac7f5132ac446b035e2`. Its three annotations were
infrastructure notices. Independent subscription-backed Claude review was READY;
optional Codex review was still running at merge, and Devin skipped, so neither
provides completed review evidence.

The preceding [native-client slice](https://github.com/srps/Conduit/pull/256) merged
as `462dd4b41dc229bb39a55d0d4519efc30ab7d7b2` after exact-head Swift and CodeQL
passed. Its three annotations were runner-capacity/OS-label notices. Automated
Codex reviews did not complete and Devin skipped; independent subscription-backed
Claude reviews supply the separate source-review evidence.

## Remaining scope

At this checkpoint the app had not adopted the host. The subsequent AppState
activation is under verification, and the owner selected ten seconds total for
app Quit in 0039; audit parity changes neither the selected Stop/Quit policy nor its total.
The AppState deletion, coherent production composition, RuntimeActor move and
native/real-machine acceptance remain. No installed-machine audit or RAM bound
is inferred from these fake/scratch checks.
