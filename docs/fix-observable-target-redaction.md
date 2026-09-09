# Observable request target privacy (S06)

Request queries and fragments can carry short secrets that token-pattern redaction does not recognize. HTTP routing previously interpolated raw targets into ordinary logs and active connection records, so raw snapshots could expose them even when audit targets were masked.

`SensitiveValueSanitizer.observableTarget` now defines the observation-only representation. It removes the first query/fragment suffix before parsing, retaining a redaction marker and preserving encoded path delimiters. HTTP log/error formatting and active-connection construction use it; audit target sanitization delegates to it. Generic log/event sanitization also filters embedded absolute URL suffixes, including malformed candidates. Control diagnostics follows the same URL contract and masks origin-form destination/target/URI fields in generic historical exports. No wire request or routing input is replaced with an observation value.

The live regression fails on the pre-fix parent with `URL secret reached an observation` while the request is active, and passes after the fix.

Validation uses only synthetic tokens and ephemeral loopback listeners:

- `pm-sim observable-target-redaction` checks observation values, recording logs, events, audit targets, encoded connection records, malformed URLs, and idempotence.
- `scripts/test-observable-target-redaction.py` runs the real headless runtime. Both absolute and origin-form requests preserve the exact query at the origin. Active snapshots, stdout/stderr, and existing event/audit files omit the tokens across successful requests, body-limit rejection, and refused direct connections.
- `ObservableTargetRedactionTests` covers kernel/control sanitizer parity, userinfo, fragments, malformed URLs, encoded path delimiters, generic diagnostic exports, and JSON records. XCTest runs in Xcode CI; local builds use the previously documented CLT/macOS 26.5 SDK workaround.

This does not promise redaction of arbitrary short path-segment secrets or purge historical logs. The duplicate sanitizer implementations and observation DTO mutation/decoding boundaries are recorded in [refactor notes](refactor-notes-2026-09-09.md).
