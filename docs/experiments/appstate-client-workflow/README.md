# AppState activation workflow evidence

All 41 workflow checks have passing final results on unchanged relevant-source
fingerprint `c79e243f274ebfd408effae8c39bc62a8acf9c8e8419ae398796ef23bf5596ce`.
The base run completed every step and exited 1 only for two Markdown decision
format errors: evidence placement and an explicit "Does not prove" line.
[The original results](initial-results.json) are unchanged and retained.

After correcting only those documents, both decision gates passed; the bounded
correction driver verified all 41 base steps completed, no other failures existed,
and production, Tests, scripts, workflow and resource bytes still matched. It
then exited 0 with the [complete final proof](results.json). This is a base run
plus two document rechecks, not a claim that the original run exited 0.

The Swift suite passed 3,696 tests with four existing skips and no failures. All 103
simulator records passed. The performance gate, import/process and catalogue
mutation checks, signing/packaging/updater tests and standalone DNS/status/routing
regressions passed. No resource measurement ran concurrently. Fresh Release and
app-consumer observations, native AppKit acceptance and exact-head hosted CI
remain separate gates.
