# Independent review: owner native acceptance of signed Conduit 0.6.1

Reviewer: Claude (Opus 5.5), read-only.

**What I read:**
- the root `AGENTS.md`;
- the durable `native-061-check.py` (1,098 lines), `harness-hashes.json` and `manifest.json`;
- all four files under `reports/`, plus `post-native-live-check.json`;
- `offline-061-review-r2.md`;
- the `PlatformStateJournal`, `SystemProxyManager` and `LocationSettingsRecovery` sources in the worktree (the same tree as tag f809bb9).

**Read-only extras:**
- I made narrow read-only greps of the owner's `events.ndjson`. I pulled only event names, timestamps, and the `lifecycle.module_settled` and `auth.privilege_request` detail tokens. No hosts, URLs or identities went into this file.
- I listed `~/Library/Logs/DiagnosticReports` and `/Library/Logs/DiagnosticReports` for `Conduit*`.

**What I did not do:**
- I ran nothing: no interpreter, hash, git, app, helper or network. I did not recompute any SHA-256.
- I did not verify the CI, asset, signature, appcast or install facts in the brief. They are the parent's.
- This file is my only write.

## Verdict: ACCEPT, for normal-path native acceptance of 0.6.1 within the scope below. No blocking finding. No repeat run needed.

The latest report `native-checks-20261029T220602Z.json` supports every claim in the brief, with the precision notes below.

- **Report facts:** schema 1, mode `interactive`, 23 pass, 4 observed, 0 fail/unproven/attention, `errors: []`. Started 22:06:02Z, finished 22:07:23Z. The only skip is the documented `quit.product_only_duration`.
- **Checker hash:** `verifier_sha256` (the checker's self-hash of the file that ran) is `a07bafc6…6fd9`. That equals `harness-hashes.json` and the value in the brief. I reviewed this durable copy against R2's acceptance; I did not recompute the hash.

## Claims checked against the report and checker logic

| Brief claim | Report evidence | Checker semantics (line) | Holds |
| --- | --- | --- | --- |
| Stop closed the listener, same PID | `stop.stopped_listener_closed` pass 4.72 s; `stop.same_process_retained` pass | fresh `stopped` snapshot, no lsof listener, connect `ECONNREFUSED` (`:491-496`); `pid_path(pid)==exe` (`:608`) | yes |
| Start, same PID, explicit module settled | `start.serving_same_process` pass 5.51 s; `start.proxy_module_settled` started=1, other=0 | `need_pid=pid` (`:615`); `module=proxy source=explicit outcome=started` since the prompt, and any other explicit settle fails (`:618-621`) | yes |
| Config/platform/preferences unchanged | `{stop,start,after_quit,reopen}.files_unchanged` all three `unchanged` | HMAC against this run's own freeze (see N2) | yes, scoped |
| Quit: process and listener gone, nothing forced | `quit.process_exited_listener_closed` pass, upper bound 5.92 s including reaction | only polls `ps`/`lsof`; the only `kill` is the tool's own timed-out child (`:352`) | yes; not a product-only duration |
| Journal released | `stop` and `after_quit` `.journal_records_released`: all non-marker records 0 (settle 0.61 s and 0.01 s) | journal only (`:529-538`) | yes; no physical or global-PAC proof |
| Reopen: new PID, manual Start, HTTPS | `reopen.process_opened` 6.09 s, `reopen.serving` `already_serving:false`, boundary `before_open_prompt`, 4.43 s, `reopen.new_process` pass, curl exit 0 / HTTP 200 / CONNECT 200 | `avoid_pid` plus a new-PID check; the wait follows the Start prompt (`:581-585`) | yes |
| Reopen Kerberos/helper | Kerberos 5/0; helper 21 succeeded / 0 failed / 0 problem; `complete:true`, 145 rows, 0 undecodable | absence counts only with a complete window (`:241`) | yes; strong, isolated evidence |
| Baseline 280 Kerberos / 58 helper | `phase_boundary: launch_epoch` (`--since` ≈ 21:59:28Z), complete, 0 failures | an aggregate since the install boundary | yes, as an aggregate only (see N1) |
| Connections live rows | `owner_attestations.baseline_connections_live_rows: "yes"` | owner attestation (`:596-598`) | yes, attested and not tool-verified |
| DNS/VPN/last-auth | `dns: running`, `vpn: connected`, `last_auth: kerberos`, `last_auth_fresh: true` at both baseline and reopen | enum observations only | yes; not DNS-query or split-DNS proof |
| Left serving | `final.serving` pass | `serving(…, 0.0)` (`:647`) | yes |

The two earlier artifacts stay non-passing and must not be upgraded:

- **`native-report-ad9154f3f9cc1beb.json`:** `owner_declined`, with only the `declined.serving` observation.
- **`native-checks-20261029T220549Z.json`:** error `interactive_KeyboardInterrupt`, with `baseline.manual_start_observed` unproven (`already_serving: true`).

## Non-blocking precision notes for the archive

### N1. An orderly exit happened between the runs, outside every check window. Disclose it.

The interrupted run saw 0.6.1 serving at about 22:06:00Z. In the latest run, `baseline.process_opened` shows no exact-path process when the run began, so the first 0.6.1 process exited between the two runs.

My read-only look at `events.ndjson` explains the exit. All timestamps below are Unix epoch, converted to UTC:

- **About 22:06:14.5Z: a complete, orderly teardown.**
  - Events: `stop-tcp-relay` 1, `compare-network-settings` 8 with 8 `platform.location_restore`, and `remove-dns` 7.
  - Every request has `outcome=succeeded`.
  - It fell after the latest run started (22:06:02Z) and before its Open prompt, while the `RUN` prompt was waiting.
- **No crash evidence.**
  - There is no `Conduit*` crash report in either DiagnosticReports directory.
  - There is no `lifecycle.termination_drain_expired` event in the window.
  - A teardown like this is consistent with the app's own Quit path. The tool did not record how the owner quit, so the archive should attribute it to the owner (ideally by attestation), not to tool evidence.
- **This exactly accounts for the baseline aggregate: 58 = 21 + 16 + 21.**
  - 21: the first session's helper requests, as counted by the interrupted run.
  - 16: this pre-run teardown.
  - 21: the latest baseline's relaunch and Start (8 compare, 7 apply-dns, 5 remove-dns, 1 start-tcp-relay). That is the same shape as reopen's 21.

So the brief is right not to attribute the baseline counts to the latest Start or the HTTPS probe. The archive should say the 58 includes one unobserved orderly Quit-teardown, with zero failures.

**My read of the event stream for the instrumented cycle.** These are my own read-only observations, not checker evidence. They are consistent with the report:

| Time (UTC) | Step | Events |
| --- | --- | --- |
| 22:06:34.7 | Baseline Start | 8× `location_apply`; proxy explicit `started` group=1 at 22:06:35.8 |
| 22:06:58.2 | Stop | 8× `location_restore` |
| 22:07:04.2 | Start | 8× `location_apply`; proxy explicit `started` group=3 (same process); DNS `already_active` |
| 22:07:10.5 | Quit | 8× `location_restore` |
| 22:07:17.5 | Reopen | `location_observed`, then 3× `launch_recovery_nothing_to_do` |
| 22:07:21.6 | Start | 8× `location_apply`; proxy explicit `started` group=1 (new process) at 22:07:22.5 |

- **Cross-cycle checks:**
  - The same 3× `launch_recovery_nothing_to_do` follows the 22:06:14 exit.
  - A grep for event names containing fail, error, degraded, contended, retry, expired, refused, stale, not_responding, unreadable or drift between 21:59:20Z and 22:08:19Z matched nothing.
- **This is still journal-level evidence.** "Nothing to do" is not per-service physical restoration and not proof that global PAC is absent.

### N2. "Unchanged" here means unchanged relative to this run's own baseline freeze.

The `*.files_unchanged` checks compare against an in-memory HMAC freeze taken after the baseline Start and Connections question (`:599`). The key is ephemeral. They prove the three files did not change across Stop, Start, Quit and reopen in this run.

"Unchanged since before install" rests on the parent's separate check (`post-native-live-check.json`: `settings_unchanged_since_before_install: true`), not on this report. The archive should cite each claim to its source.

### N3. Don't cite journal markers as live ownership.

While serving, `baseline.journal` shows `systemProxy` and `resolverFile` markers as `released`, alongside 8 and 7 records. This is expected:

- In the production `LocationSettingsRecovery` path, `apply` never calls `markApplied`. Ownership is carried by the records (`hasRecords`), and `clear` writes `markReleased` only when no records remain (`LocationSettingsRecovery.swift:383-387`).
- The marker therefore keeps the previous teardown's value. This is not a defect.
- The archive should use the record counts, not the marker labels.

### N4. What "manual Start" means here.

For baseline and reopen, the tool proves two things:

- no serving listener at the phase boundary;
- serving by the new PID only after the Start prompt (`already_serving:false`).

Those phases do not check `module_settled`. The explicit-source settle events at 22:06:35.8 and 22:07:22.5 come from my own read and corroborate a user Start rather than autostart. They are not part of the checker's evidence.

### N5. The HTTPS probe ran under the owner's CA trust environment.

`trust_env_retained: 2` means two of `SSL_CERT_FILE`, `SSL_CERT_DIR` and `CURL_CA_BUNDLE` were passed to curl. The pass is one `HEAD https://example.com/` through the loopback proxy, with no direct fallback. It is not a broad traffic test.

### N6. Leave the post-run live check out of this evidence.

`post-native-live-check.json` (22:11:26Z: running, 53 connections, signature valid) is the parent's own check. I did not review its method, so it should not be cited as part of this checker's evidence.

## Scope the acceptance must keep (unchanged from the brief and R2)

**Accepted:**
- normal-path, owner-driven Start, Stop, Start, Quit, reopen and Start of the installed signed 0.6.1;
- same-PID stop and start;
- unforced exit;
- listener lifecycle;
- journal record release;
- Kerberos and helper success with no failures in complete windows;
- one HTTPS CONNECT through the proxy;
- files stable within the run.

**Not covered:**
- per-service physical restoration or global PAC absence. This was last physically verified for 0.6.0 on 97a5b43; do not claim it again for 0.6.1;
- DNS queries or split-DNS;
- autostart;
- product-only Quit duration;
- slow-helper deadline expiry, power loss, heavy load;
- helper reinstall (none happened).

**Concurrency:** the full unsuppressed TSan run is still failing on the Swift-only continuation report tracked in #118. The scoped 264, 32 and 76 TSan passes are samples, not an aggregate or a blanket clean result. None of this is suppressed or bypassed. It is outside what this native smoke can prove and does not block this scoped acceptance.

**Release state:** the release is still an unpublished draft (the latest public release is 0.5.8). Nothing in this review authorizes publication or a new ADR policy. Per `AGENTS.md`, the 0039 record gets validation-status and evidence updates only.

## Blocking findings

None.
