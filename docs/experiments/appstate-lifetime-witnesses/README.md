# App client lifetime regression witnesses

Hosted Swift at cc300 crashed with a destroyed unowned reference after a PAC test.
[The bounded incident evidence](hosted-failure.json) identifies the exact failed
head/job; it does not identify which callback fired. Six AppState callbacks had
assumed that editor/observer tasks could not outlive their UI owner. A late frame
or page error could also return after observation stopped.

The correction uses weak UI callbacks, optional owner inputs that close through
the existing session when absent, and post-await observer stop fences. Already
frozen requests keep their original settlement; no default draft/intent or new
authority is manufactured. No public hook, cancellation protocol or registry is
added.

[Four semantic guards](results.json) are caught by assertions: late frame,
late page error, a strong UI-owner cycle and an ownerless session left open.
A fifth, separately labeled reproduction restores only onSnapshot's unowned
capture: the actual app-release test deterministically produces the same Swift
unowned-reference fatal diagnostic. This is an expected runtime-trap reproduction,
not a generic crash-based semantic kill. Baseline and exact-restored tests pass
after every group. [Exact substitutions](mutations.json) retain the scope.

[Five fresh processes](fresh-processes.json) each pass 17 lifetime/observer/editor/
PAC tests after restoration and the test-only Swift 6.2 compatibility spelling.
The first command may include rebuilding; process durations are not latency
budgets. A log-marker count is not a unique test-method count.

The full workflow, fresh measurements, hosted CI and native acceptance for the
fixed code remain separately recorded. Earlier green results did not invalidate
the hosted failure, and this witness does not identify the precise historical
callback schedule or prove real-machine behavior.
