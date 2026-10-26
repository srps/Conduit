# Diagnostic marker drain verification (2026-10-26)

Status: deterministic regression reproduced; correction and acceptance verification in progress.
Related work: [#47](https://github.com/srps/Conduit/issues/47), [#186](https://github.com/srps/Conduit/issues/186), and the [protected-artifact design](design-protected-runtime-artifacts.md).

## Failure and witness

The snapshot-alias actual-host test twice reported settled runtime effects, audit drained,
events drained, an extra events wait of `busy`, snapshot refused, snapshot-event unconfirmed,
and one pending events record with zero losses and zero flush timeouts. The harness preserved
its host/root and refused later test roots. Passing repetitions were not evidence of a fix.

The shared waiter returned the first drained outcome before its cancelled timer body ended.
A snapshot refusal queued its diagnostic marker; the phase's one extra events wait then met
the still-held physical timer reservation. Two deterministic tests hold that timer body and
the marker's write through the actual `DiagnosticFlush` composition. Before the correction,
they failed seven assertions: both extra waits were busy and left a record pending; the late
case also left the snapshot marker unconfirmed. The 129 other selected tests passed. This
proves the composition mechanism and matches the host observations; it does not prove the
historical OS scheduling order.

The first attempted witness did not compile because a semaphore wait was used directly in
async code. A second run included two invalid duration assertions that counted the test's own
join delay. The recorded seven-assertion witness measures the phase's duration where it
returns and contains neither of those test defects.

## Bounded correction

The intended correction uses the existing waiter core and reservation identity, with one
logical caller and one outstanding group notify. Only the events writer allows two live timer
bodies, accounting for the phase's first wait and its one extra confirmation. Other writers
keep one. A timeout or cancellation retains its notify and still refuses an overlapping wait.
An old timer cannot settle, cancel or remove a newer reservation. Physical cleanup waits for
all notifications and timer bodies; callbacks and continuation resumes stay outside the lock.

This preserves the six-second absolute phase deadline, per-writer wait cap, phase ordering,
one extra events wait and fail-closed authority retention. It adds no retry loop or deadline.
The internal sleep seam is available through `@testable`; production package constructors
keep their existing interfaces. Simulator coverage uses production interfaces and the real
clock; deterministic timing belongs in the composition tests.

If timer bodies from two earlier calls are both held, a later wait can still report busy.
Queue drained is distinct from successful file output and from physical quiescence. This
work establishes neither forced physical cancellation nor the total shutdown bound in #47.

## Acceptance evidence

Pending source freeze, independent review, regression guard mutations and all workflow gates.
