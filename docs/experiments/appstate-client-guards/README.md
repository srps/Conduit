# AppState client guard witnesses

Ten one-off mutations of the frozen activation source each failed on a semantic
XCTest assertion. Every group first passed its actual tests, temporarily changed
one production guard, then restored the exact original bytes and reran the tests
successfully. Compile errors, crashes and timeouts do not count as a caught guard.

[Results](results.json) retain the exact commands, source hashes, first failing
assertions, process exits and durations. `test_case_log_markers` counts started/
passed XCTest log markers, not unique methods; it only guards against a filter
matching no test. The named filters and assertion identities establish the scope. [Mutation specifications](mutations.json)
name each file, exact substitution and focused test filter. The ordinary tests
remain the maintained CI checks; this experiment adds no production hook, test
framework or new runtime path.

The independent editor model catches five authority/chain guards, including the
own-Stop race at depth six. Additional checks catch stranded state after a refused
admission, the real editor session's once-only draft resubmission, pending lookups
miscounted as failures, loss of Quit's frozen exact save precondition, and failure
to rebase the host-owned DNS bit in the app draft.

Two initial runner attempts are explicitly invalidated: the local macOS sandbox
refused process-group signaling after an assertion. Both restored source and
relinked passing tests. The corrected run signals only exact PIDs belonging to
the fresh test session it created. It stops after the first meaningful assertion
to bound output; the recorded nonzero exit is not itself the evidence.

This proves the named tests detect these ten substitutions, not every schedule.
The app's lost-command glue and notification-only supersession branch still lack
app-level fault/notification seams; the ledger's unknown-write policy is covered
by its independent model. Native UI, real helper/VPN/auth behavior, process memory
and release readiness remain separate acceptance obligations.

To repeat a substitution, use an isolated checkout with no competing edit/build,
verify the recorded source hash, run the named test filter, apply only that exact
substitution and require its semantic assertion, restore exact bytes in a finally
block, then rebuild and rerun the same filter. Never leave mutated build objects
as the final verification state.
