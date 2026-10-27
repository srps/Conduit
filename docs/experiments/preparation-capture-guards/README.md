# Preparation-time capture guards

Executed against local checkpoint `291267029bc0d09117fe03e77923cee9411db643`,
before the subsequent module-host integration. These are three independent
production-source edits, one at a time. Each failed its named assertion without a
crash. Exact original bytes were restored, and the affected tests then passed.
[`results.json`](results.json) records the source identity, mutant hashes and
restored hashes. It contains no configuration values or account/session data.

| Disabled production guard | Intended witness |
| --- | --- |
| Store receipt version comparison | `ConfigurationCaptureModelTests.testBoundedCaptureHistoriesAgreeWithAnIndependentReference` |
| Refusing new DNS disable obligations after Quit | `RuntimeModuleIntentTests.testALateDNSStopAfterQuitCreatesAndDropsNoSave` |
| The actual captured write claim | `ConfigurationWorkflowPhaseTests.testAStopAdmittedBeforeTheClaimRevokesTheWriteAndNothingApplies` |

The last experiment checks the claim actually used by `prepareStart`, rather than
the obsolete helper its older admission oracle called. The real physical-phase
test detects bypassed revocation; no additional production testing API is needed.
The capture reference model independently covers 93 histories and 165 transitions,
including six changed-then-restored observations.

## Replay

Use an isolated, clean checkout at the recorded source commit, with Xcode and the
package dependencies available. Run `python3 replay.py /absolute/path/to/checkout`.
The archived driver uses the recorded edits and test filters, parameterizes the
workspace/output paths, refuses another commit or a dirty checkout, and restores
source in `finally`. Outputs go to a fresh temporary directory. The recorded runs
used the original workspace-bound drivers; this portable wrapper is not a separate
measurement.

Does not prove: all schedules, physical DNS/tunnel ordering, private-channel
responsiveness, the later combined host, AppState adoption or release readiness.
The full Swift suite at this capture checkpoint separately passed 3,488 tests with
four skips. Final integration still requires fresh review and every workflow gate.
