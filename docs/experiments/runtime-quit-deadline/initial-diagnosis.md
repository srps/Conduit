## Diagnosis of the d038 CI failure: a real-time budget assumption in the test, not an owner-progress or settlement-contract bug

I haven't edited anything: no Source, tests or docs. The only open question is which piece of I/O was slow, and two cheap log greps (below) can settle that.

### What the failure means
- The subscription is refused, so `RuntimeClientQuit.quit` can't watch a stream. It reads the Quit once, 200 ms before its deadline, and then holds the caller until the deadline (`RuntimeClientQuit.swift:262-269`).
- This test sets the total to **3 s**, so that single read happens about **2.8 s** after the routine starts.
- Getting `.unsettled` (with the caller held to the deadline) means one thing: the host's Quit work had not finished at that moment. A host that had run out its own deadline would have reported `cleanupIncomplete`, but the host's deadline is roughly the client's deadline, so that verdict always lands after the client's last read. The client correctly reports "unknown" instead of guessing.
- The timing fits:
  - On a pass, this test lasts about setup + 2.8 s.
  - On a fail, it lasts setup + 3.0 s.
  - 4.124 s therefore means roughly 1.1 s of setup and wind-down on the runner.

### What the host does in those 2.8 s
From `RuntimeHostLifecycle.swift:1005-1022`, after the test releases the held read:
1. The parked earlier update finishes as superseded.
2. The configuration and platform save runs: read, verify, write, read back.
3. The preferences save does the same.
4. The store work is joined.
5. The logger drain runs, capped at min(2 s, Quit deadline).
6. The diagnostic artifact flush runs for audit, events and snapshot: up to 2 s per writer, 6 s in total.

None of these waits for a deadline when everything succeeds:
- The flush window closes as soon as both declared saves end (`RuntimeQuitFlush.finish`, `RuntimePrivateEditor.swift:664,678`).
- The preferences save was admitted. Otherwise line 1445 would have failed, and only line 1447 failed.

So I see no causal stall in the source. Locally the work ends in milliseconds. The test does assert something stronger, though: that teardown, two saves (writes with read-back) and a diagnostic flush finish within about 2.8 s of wall time on a hosted runner. That's three seconds against the shipping 10 s (`AppTiming.quitTotal`), and less than the host's own designed diagnostic waits (2 s for the logger plus up to 6 s for artifacts).

One stall the source can't rule out: the two idle live subscriptions the test holds (`app` and `window`) never get read. I found nothing showing that their back-pressure can block the owner, but I didn't trace the service's per-subscriber buffer all the way through.

### Side finding, not the cause
- The host Quit's artifact flush gets a fresh 6 s phase (`RuntimeHost.swift:999`, `DiagnosticFlushPhase()`). It is **not** cut to the Quit deadline the way the logger drain is.
- The in-process app's 10 s total still holds, because the client routine returns at the deadline regardless.
- But the verification doc's wording, "Logger drain precedes one artifact flush within the original total Quit deadline", reads stronger than the code. This doesn't change the diagnosis.
- I'm flagging it for review only. It isn't a proposed Source change.

### Evidence I'd ask you to collect first (greps only, no dump)
1. In this run's log, and in the hosted 7d run `40702811562`, the "passed/failed (N seconds)" lines for `testTheClientQuit*`. The setup share (duration minus about 2.8 s) shows how much slower this runner was. Also compare the suite times (427 s here).
2. In this run's log, if host lines reach stdout: `Observability flush not fully confirmed`, `log_flush_unconfirmed`, `cleanup_incomplete`, `save_unverified`. A hit names the slow step. No hits means the only explanation is general runner slowness.
3. Optional: run this one test in a loop on a local machine under CPU and disk stress, to see whether it fails the same way.

### Proposal (test-only, after you've reviewed the above)
- If the evidence points to runner I/O or scheduling with no stall line: in this test and its sibling `testTheClientQuitFlushesItsDeclaredSaveWhenItsStreamEndsEarly`, which has the same exposure at `:1479`, replace the arbitrary `.seconds(3)` with the shipping 10 s total.
  - Keep every assertion: `.settled`, `completed(.quit)`, teardown ended, and both files persisted.
  - The cost is about 7 s of wall time per test (≈14 s total), because the no-stream path always waits until 200 ms before its deadline.
  - My reasoning: the test is meant to cover the no-stream contract, not to time I/O to the second, and 3 s sits below the host's own designed diagnostic waits. I recognise this is the "lengthen the deadline" lever, so whether to accept it is your decision.
- If a stall line or the subscriber question turns out to be implicated: I'd stop and bring you a causal reproduction before touching any timing.

`testTheClientQuitKeepsItsCallerToTheTotalDeadlineWhileAnUnobservedTeardownIsHeld` (2 s) doesn't depend on completion speed and needs no change.