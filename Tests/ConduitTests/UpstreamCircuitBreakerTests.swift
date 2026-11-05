// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import ProxyKernel

/// Locks in the contract of the formalized `UpstreamCircuitBreaker` state
/// machine extracted from `ConnectionPool`.
///
/// The breaker is a pure value type: every transition is the deterministic
/// result of `(current state, recordSuccess|recordFailure|tryHalfOpen|reset,
/// now, threshold, windowSeconds, baseOpenInterval, maxOpenInterval)`. No
/// hidden time, no global state, no IO. Tests pin the externally-observable
/// contract — the same contract the existing `ConnectionPool` upstream-state
/// table enforced before extraction, now formalized as named transitions
/// emitted on each state change.
final class UpstreamCircuitBreakerTests: XCTestCase {

    // MARK: - Initial state

    func testInitialStateIsClosedNoFailures() {
        let breaker = UpstreamCircuitBreaker()
        XCTAssertEqual(breaker.state, .closed)
        XCTAssertEqual(breaker.consecutiveFailures, 0)
        XCTAssertNil(breaker.openUntil)
    }

    // MARK: - Closed → Open transition

    func testClosedTripsToOpenAfterThresholdConsecutiveFailures() {
        var breaker = UpstreamCircuitBreaker()
        let now = Date()
        var transitions: [UpstreamCircuitBreaker.Transition] = []

        // Fail enough times AND beyond the window to satisfy both the
        // consecutive-failure threshold AND the time-window guard
        // (synchronized burst protection).
        for i in 0..<5 {
            let t = breaker.recordFailure(
                now: now.addingTimeInterval(Double(i) * 3),  // 0,3,6,9,12 s spread → past 10 s window
                threshold: 5,
                windowSeconds: 10,
                baseOpenInterval: 30,
                maxOpenInterval: 300
            )
            if let t { transitions.append(t) }
        }

        XCTAssertEqual(breaker.state, .open)
        XCTAssertEqual(transitions.count, 1, "Exactly one .opened transition emitted on the threshold-trip")
        if case let .opened(reason, consecutiveFailures, openInterval) = transitions[0] {
            XCTAssertEqual(reason, .thresholdReached)
            XCTAssertEqual(consecutiveFailures, 5)
            XCTAssertEqual(openInterval, 30)
        } else {
            XCTFail("Expected .opened transition, got \(transitions[0])")
        }
    }

    func testSynchronizedBurstWithinWindowDoesNotTripBreaker() {
        // Invariant: 5 in-flight requests all fail at the same instant
        // must NOT trip the breaker — that's a transient-path signal, not
        // upstream rot. Without the time-window guard, every VPN flap with
        // ≥ 5 in-flight would synthesize a circuit trip.
        var breaker = UpstreamCircuitBreaker()
        let now = Date()
        var transitions: [UpstreamCircuitBreaker.Transition] = []

        for _ in 0..<5 {
            let t = breaker.recordFailure(
                now: now,  // all at the same instant
                threshold: 5,
                windowSeconds: 10,
                baseOpenInterval: 30,
                maxOpenInterval: 300
            )
            if let t { transitions.append(t) }
        }

        XCTAssertEqual(breaker.state, .closed,
                       "Burst within window must not trip breaker (synchronized-burst protection)")
        XCTAssertTrue(transitions.isEmpty, "No transitions emitted while breaker stays closed")
    }

    func testWindowGuardDisabledByZeroSeconds() {
        // windowSeconds = 0 disables the guard, restoring legacy
        // burst-trip behaviour for setups that prefer it.
        var breaker = UpstreamCircuitBreaker()
        let now = Date()
        var transitions: [UpstreamCircuitBreaker.Transition] = []

        for _ in 0..<5 {
            let t = breaker.recordFailure(
                now: now,
                threshold: 5,
                windowSeconds: 0,
                baseOpenInterval: 30,
                maxOpenInterval: 300
            )
            if let t { transitions.append(t) }
        }

        XCTAssertEqual(breaker.state, .open, "windowSeconds=0 restores legacy behaviour")
        XCTAssertEqual(transitions.count, 1)
    }

    // MARK: - Success resets failure count

    func testSuccessResetsConsecutiveFailures() {
        var breaker = UpstreamCircuitBreaker()
        let now = Date()
        for _ in 0..<3 {
            _ = breaker.recordFailure(now: now, threshold: 5, windowSeconds: 0, baseOpenInterval: 30, maxOpenInterval: 300)
        }
        XCTAssertEqual(breaker.consecutiveFailures, 3)

        let transition = breaker.recordSuccess(latencyMS: 42)
        XCTAssertNil(transition, "Success in closed state emits no transition")
        XCTAssertEqual(breaker.consecutiveFailures, 0)
        XCTAssertEqual(breaker.state, .closed)
    }

    // MARK: - Open → HalfOpen transition

    func testOpenStaysOpenBeforeBackoffElapses() {
        var breaker = UpstreamCircuitBreaker()
        let now = Date()
        for i in 0..<5 {
            _ = breaker.recordFailure(now: now.addingTimeInterval(Double(i) * 3), threshold: 5, windowSeconds: 10, baseOpenInterval: 30, maxOpenInterval: 300)
        }
        XCTAssertEqual(breaker.state, .open)

        // Try to half-open before backoff has elapsed.
        let beforeBackoff = now.addingTimeInterval(15 + 5)  // last failure was at 12 s, openUntil at 12+30 = 42 s
        let transition = breaker.tryHalfOpen(now: beforeBackoff)
        XCTAssertNil(transition)
        XCTAssertEqual(breaker.state, .open, "Must stay open until openUntil elapses")
    }

    func testOpenTransitionsToHalfOpenAfterBackoffElapses() {
        var breaker = UpstreamCircuitBreaker()
        let openedAt = Date()
        for i in 0..<5 {
            _ = breaker.recordFailure(now: openedAt.addingTimeInterval(Double(i) * 3), threshold: 5, windowSeconds: 10, baseOpenInterval: 30, maxOpenInterval: 300)
        }
        // openUntil = 12 + 30 = 42 s after openedAt
        let pastBackoff = openedAt.addingTimeInterval(43)
        let transition = breaker.tryHalfOpen(now: pastBackoff)
        XCTAssertNotNil(transition)
        if case let .halfOpened(elapsedSeconds) = transition! {
            XCTAssertGreaterThanOrEqual(elapsedSeconds, 30)
        } else {
            XCTFail("Expected .halfOpened, got \(transition!)")
        }
        XCTAssertEqual(breaker.state, .halfOpen)
        XCTAssertTrue(breaker.halfOpenProbeInFlight)
    }

    func testHalfOpenProbeInFlightBlocksConcurrentHalfOpenAttempts() {
        var breaker = UpstreamCircuitBreaker()
        let openedAt = Date()
        for i in 0..<5 {
            _ = breaker.recordFailure(now: openedAt.addingTimeInterval(Double(i) * 3), threshold: 5, windowSeconds: 10, baseOpenInterval: 30, maxOpenInterval: 300)
        }
        let pastBackoff = openedAt.addingTimeInterval(43)
        _ = breaker.tryHalfOpen(now: pastBackoff)  // arms the probe
        let secondAttempt = breaker.tryHalfOpen(now: pastBackoff.addingTimeInterval(0.1))
        XCTAssertNil(secondAttempt, "Second tryHalfOpen with probe in flight returns nil (no transition)")
    }

    // MARK: - HalfOpen behaviour

    func testHalfOpenSuccessClosesBreakerAndResetsBackoff() {
        var breaker = UpstreamCircuitBreaker()
        let openedAt = Date()
        for i in 0..<5 {
            _ = breaker.recordFailure(now: openedAt.addingTimeInterval(Double(i) * 3), threshold: 5, windowSeconds: 10, baseOpenInterval: 30, maxOpenInterval: 300)
        }
        _ = breaker.tryHalfOpen(now: openedAt.addingTimeInterval(43))

        let transition = breaker.recordSuccess(latencyMS: 50)
        XCTAssertNotNil(transition)
        if case .closed = transition! {
            // ok
        } else {
            XCTFail("Expected .closed transition, got \(transition!)")
        }
        XCTAssertEqual(breaker.state, .closed)
        XCTAssertEqual(breaker.consecutiveFailures, 0)
        XCTAssertEqual(breaker.nextOpenInterval, 30, "Backoff resets to base on probe success")
    }

    func testHalfOpenFailureReopensBreakerWithExponentialBackoff() {
        var breaker = UpstreamCircuitBreaker()
        let openedAt = Date()
        for i in 0..<5 {
            _ = breaker.recordFailure(now: openedAt.addingTimeInterval(Double(i) * 3), threshold: 5, windowSeconds: 10, baseOpenInterval: 30, maxOpenInterval: 300)
        }
        _ = breaker.tryHalfOpen(now: openedAt.addingTimeInterval(43))

        // A failure during half-open re-opens immediately, regardless of window.
        let probeFailureTime = openedAt.addingTimeInterval(44)
        let transition = breaker.recordFailure(now: probeFailureTime, threshold: 5, windowSeconds: 10, baseOpenInterval: 30, maxOpenInterval: 300)
        XCTAssertNotNil(transition)
        if case let .opened(reason, _, openInterval) = transition! {
            XCTAssertEqual(reason, .probeFailed,
                           "Half-open re-trip carries .probeFailed reason, not .thresholdReached")
            XCTAssertEqual(openInterval, 60, "Exponential backoff: base*2 = 60")
        } else {
            XCTFail("Expected .opened(.probeFailed, _, 60), got \(transition!)")
        }
        XCTAssertEqual(breaker.state, .open)
    }

    func testExponentialBackoffCapsAtMax() {
        var breaker = UpstreamCircuitBreaker()
        // Drive five trip-then-half-open-then-fail cycles to exhaust the backoff growth.
        var t = Date()
        let baseOpenInterval: TimeInterval = 30
        let maxOpenInterval: TimeInterval = 300
        for cycle in 0..<5 {
            // Trip
            for i in 0..<5 {
                _ = breaker.recordFailure(now: t.addingTimeInterval(Double(i) * 3), threshold: 5, windowSeconds: 10, baseOpenInterval: baseOpenInterval, maxOpenInterval: maxOpenInterval)
            }
            t = t.addingTimeInterval(15)
            // Wait past the backoff and half-open
            t = t.addingTimeInterval(maxOpenInterval + 1)
            _ = breaker.tryHalfOpen(now: t)
            // Probe fails → re-open
            _ = breaker.recordFailure(now: t.addingTimeInterval(0.1), threshold: 5, windowSeconds: 10, baseOpenInterval: baseOpenInterval, maxOpenInterval: maxOpenInterval)
            XCTAssertEqual(breaker.state, .open, "After cycle \(cycle), breaker should be open")
            XCTAssertLessThanOrEqual(breaker.nextOpenInterval, maxOpenInterval,
                                      "Backoff caps at maxOpenInterval, got \(breaker.nextOpenInterval) on cycle \(cycle)")
            t = t.addingTimeInterval(1)
        }

        XCTAssertEqual(breaker.nextOpenInterval, maxOpenInterval, "Backoff converges to max")
    }

    // MARK: - .open is a real no-op

    func testRecordFailureWhileOpenDoesNotMutateConsecutiveFailures() {
        // The documented `.open` no-op was leaking
        // state — `consecutiveFailures` ticked up and `firstFailureAt` was
        // anchored before the state guard. Pin the contract so the
        // snapshot-exposed counter doesn't drift while the breaker is
        // saying "don't use this upstream".
        var breaker = UpstreamCircuitBreaker()
        let openedAt = Date()
        for i in 0..<5 {
            _ = breaker.recordFailure(
                now: openedAt.addingTimeInterval(Double(i) * 3),
                threshold: 5,
                windowSeconds: 10,
                baseOpenInterval: 30,
                maxOpenInterval: 300
            )
        }
        XCTAssertEqual(breaker.state, .open, "Setup: breaker must be open after 5 spaced failures")
        XCTAssertEqual(breaker.consecutiveFailures, 0, "Setup: trip resets the counter")
        XCTAssertNil(breaker.firstFailureAt, "Setup: trip clears the anchor")

        // Now hammer recordFailure while open. The breaker is documented as
        // a no-op for this case — the counter must not budge.
        for i in 0..<10 {
            let transition = breaker.recordFailure(
                now: openedAt.addingTimeInterval(15 + Double(i)),
                threshold: 5,
                windowSeconds: 10,
                baseOpenInterval: 30,
                maxOpenInterval: 300
            )
            XCTAssertNil(transition, "No transition emitted for recordFailure on open breaker")
        }

        XCTAssertEqual(breaker.state, .open, "State unchanged")
        XCTAssertEqual(breaker.consecutiveFailures, 0,
                       "consecutiveFailures must not tick up while breaker is open")
        XCTAssertNil(breaker.firstFailureAt,
                     "firstFailureAt must not be re-anchored while breaker is open")
    }

    // MARK: - reset()

    func testResetClosesBreakerAndClearsBackoff() {
        var breaker = UpstreamCircuitBreaker()
        let now = Date()
        for i in 0..<5 {
            _ = breaker.recordFailure(now: now.addingTimeInterval(Double(i) * 3), threshold: 5, windowSeconds: 10, baseOpenInterval: 30, maxOpenInterval: 300)
        }
        // Re-trip via half-open to grow the backoff so we can verify reset clears it.
        _ = breaker.tryHalfOpen(now: now.addingTimeInterval(43))
        _ = breaker.recordFailure(now: now.addingTimeInterval(44), threshold: 5, windowSeconds: 10, baseOpenInterval: 30, maxOpenInterval: 300)
        XCTAssertEqual(breaker.nextOpenInterval, 60)

        let transition = breaker.reset(reason: .vpnFlapRecovered, baseOpenInterval: 30)
        XCTAssertNotNil(transition)
        if case let .closed(reason) = transition! {
            XCTAssertEqual(reason, .reset(.vpnFlapRecovered))
        } else {
            XCTFail("Expected .closed(.reset(.vpnFlapRecovered)), got \(transition!)")
        }
        XCTAssertEqual(breaker.state, .closed)
        XCTAssertEqual(breaker.consecutiveFailures, 0)
        XCTAssertEqual(breaker.nextOpenInterval, 30, "Reset restores base backoff")
        XCTAssertNil(breaker.openUntil)
    }

    func testResetOnAlreadyClosedBreakerEmitsNoTransition() {
        var breaker = UpstreamCircuitBreaker()
        let transition = breaker.reset(reason: .vpnFlapRecovered, baseOpenInterval: 30)
        XCTAssertNil(transition, "No-op reset emits no transition")
    }

    // MARK: - EWMA latency

    func testRecordSuccessUpdatesEWMALatency() {
        var breaker = UpstreamCircuitBreaker()
        _ = breaker.recordSuccess(latencyMS: 100)
        XCTAssertEqual(breaker.ewmaLatencyMS, 100)

        // alpha=0.3: ewma = 0.3*200 + 0.7*100 = 60+70 = 130
        _ = breaker.recordSuccess(latencyMS: 200)
        XCTAssertEqual(breaker.ewmaLatencyMS!, 130, accuracy: 0.001)
    }

    // MARK: - Silence

    private func decisivelySilent() -> UpstreamCircuitBreaker {
        var breaker = UpstreamCircuitBreaker()
        _ = breaker.recordUnanswered()
        _ = breaker.recordUnanswered()
        return breaker
    }

    func testOneSilenceAsksNothingAndTheSecondAsksTheUpstreamOnce() {
        var breaker = UpstreamCircuitBreaker()

        let first = breaker.recordUnanswered()
        XCTAssertFalse(first.verdict.isDecisive)
        XCTAssertEqual(first.step, .held)

        let second = breaker.recordUnanswered()
        XCTAssertTrue(second.verdict.isDecisive)
        XCTAssertEqual(second.step, .check)
        XCTAssertEqual(breaker.silence, .checking(superseded: false))
        XCTAssertEqual(breaker.recordUnanswered().step, .held, "one check per upstream at a time")
        XCTAssertFalse(breaker.ranksBehind(at: Date()), "a silence alone ranks nothing")
        XCTAssertEqual(breaker.state, .closed)
        XCTAssertEqual(breaker.consecutiveFailures, 0, "a silence strikes nothing")
    }

    func testTheFirstSilenceAfterAConclusiveFailureAsksTheUpstream() {
        var breaker = UpstreamCircuitBreaker()
        breaker.recordFailure(now: Date(), threshold: 5, windowSeconds: 0, baseOpenInterval: 30, maxOpenInterval: 300)

        XCTAssertEqual(breaker.recordUnanswered().step, .check)
    }

    func testAnAnsweredCheckKeepsTheUpstreamAndStartsANewStreak() {
        var breaker = decisivelySilent()

        XCTAssertEqual(breaker.finishSilenceCheck(.answered(status: 403, latencyMS: 12), now: Date(), interval: 30), .kept)

        XCTAssertEqual(breaker.silence, .none)
        XCTAssertNil(breaker.ewmaLatencyMS, "the probe is the proxy's own answer, not an exchange, so it scores no latency")
        XCTAssertEqual(breaker.probeSupport, .answers)
        XCTAssertFalse(breaker.recordUnanswered().verdict.isDecisive, "the answer started a new streak")
    }

    func testAClosedCheckKeepsTheUpstreamAndLearnsNothing() {
        var breaker = decisivelySilent()

        XCTAssertEqual(breaker.finishSilenceCheck(.closed, now: Date(), interval: 30), .kept)

        XCTAssertFalse(breaker.ranksBehind(at: Date()), "a peer that closed acted, so it is not silent")
        XCTAssertEqual(breaker.probeSupport, .unknown)
        XCTAssertEqual(breaker.recordUnanswered().step, .check, "the silences still stand, so the next one asks again")
    }

    func testASilentCheckOnAnUpstreamThatIgnoresTheProbeRanksNothing() {
        var breaker = UpstreamCircuitBreaker()
        XCTAssertTrue(breaker.beginDiscovery())
        breaker.recordDiscovery(.silent)
        XCTAssertEqual(breaker.probeSupport, .ignores)
        _ = breaker.recordUnanswered()
        XCTAssertEqual(breaker.recordUnanswered().step, .check, "an ignoring upstream is still asked: a refused probe stays a measurement")

        XCTAssertEqual(breaker.finishSilenceCheck(.silent, now: Date(), interval: 30), .keptProbeIgnored)
        XCTAssertFalse(breaker.ranksBehind(at: Date()), "its silence says nothing about it")

        _ = breaker.recordUnanswered()
        XCTAssertEqual(breaker.finishSilenceCheck(.refused, now: Date(), interval: 30), .rankedBehind)
    }

    func testDiscoveryRunsOncePerEndpointAndLearnsOnlyFromAnAnswerOrASilence() {
        var breaker = UpstreamCircuitBreaker()
        XCTAssertTrue(breaker.beginDiscovery())
        XCTAssertFalse(breaker.beginDiscovery(), "one discovery at a time")
        breaker.recordDiscovery(.refused)
        XCTAssertEqual(breaker.probeSupport, .unknown, "a refused connect teaches nothing about the probe")
        XCTAssertTrue(breaker.beginDiscovery())
        breaker.recordDiscovery(.unasked)
        XCTAssertTrue(breaker.beginDiscovery())

        breaker.recordDiscovery(.answered(status: 501, latencyMS: 3))
        XCTAssertEqual(breaker.probeSupport, .answers)
        XCTAssertFalse(breaker.beginDiscovery(), "learnt once per endpoint")
        breaker.recordDiscovery(.silent)
        XCTAssertEqual(breaker.probeSupport, .answers, "a result outside a discovery changes nothing")

        breaker.forgetEndpoint()
        XCTAssertEqual(breaker.probeSupport, .unknown)
        XCTAssertTrue(breaker.beginDiscovery())
        breaker.recordDiscovery(.closed)
        XCTAssertEqual(breaker.probeSupport, .ignores, "alive a moment ago and closed on the probe: it does not answer it")
    }

    func testAHealthCheckBeginsASilenceCheckWithoutAStreakAndAnAnswerSupersedesIt() {
        var breaker = UpstreamCircuitBreaker()
        XCTAssertTrue(breaker.beginSilenceCheck())
        XCTAssertFalse(breaker.beginSilenceCheck(), "one check per upstream at a time")
        XCTAssertEqual(breaker.recordUnanswered().step, .held)

        breaker.recordSuccess(latencyMS: 8)
        XCTAssertEqual(breaker.silence, .checking(superseded: true))
        XCTAssertEqual(breaker.finishSilenceCheck(.silent, now: Date(), interval: 30), .superseded)
        XCTAssertFalse(breaker.ranksBehind(at: Date()))

        var ranked = UpstreamCircuitBreaker()
        XCTAssertTrue(ranked.beginSilenceCheck())
        XCTAssertEqual(ranked.finishSilenceCheck(.silent, now: Date(), interval: 30), .rankedBehind,
                       "a health check's first silence is decided by the probe alone, with no streak")
        XCTAssertFalse(ranked.beginSilenceCheck(), "a ranked upstream is not asked again")
    }

    func testARankingThatLapsesWithoutAnAnswerKeepsTheSilenceStanding() {
        var breaker = decisivelySilent()
        let now = Date()
        XCTAssertEqual(breaker.finishSilenceCheck(.silent, now: now, interval: 30), .rankedBehind)
        XCTAssertTrue(breaker.silenceStands)

        XCTAssertTrue(breaker.endRankingIfDue(now: now.addingTimeInterval(30)))

        XCTAssertEqual(breaker.silence, .lapsed)
        XCTAssertFalse(breaker.ranksBehind(at: now.addingTimeInterval(30)), "selection competes for it again")
        XCTAssertTrue(breaker.silenceStands, "nothing answered since the probe found it silent")
        XCTAssertTrue(breaker.beginSilenceCheck(), "the data path may ask it again")
        XCTAssertEqual(breaker.finishSilenceCheck(.silent, now: now.addingTimeInterval(31), interval: 30), .rankedBehind)

        breaker.recordSuccess(latencyMS: 4)
        XCTAssertEqual(breaker.silence, .none)
        XCTAssertFalse(breaker.silenceStands, "an answer ends it")

        var lapsed = decisivelySilent()
        XCTAssertEqual(lapsed.finishSilenceCheck(.silent, now: now, interval: 30), .rankedBehind)
        XCTAssertTrue(lapsed.endRankingIfDue(now: now.addingTimeInterval(30)))
        lapsed.reset(reason: .vpnFlapRecovered, baseOpenInterval: 30)
        XCTAssertEqual(lapsed.silence, .none, "a reset ends it too")
    }

    func testAnEndpointChangeForgetsTheOldEndpointsSilenceToo() {
        var ranked = decisivelySilent()
        XCTAssertEqual(ranked.finishSilenceCheck(.silent, now: Date(), interval: 30), .rankedBehind)
        ranked.forgetEndpoint()
        XCTAssertEqual(ranked.silence, .none, "the replacement endpoint starts with no verdict")
        XCTAssertFalse(ranked.recordUnanswered().verdict.isDecisive, "and with no streak")

        var checking = decisivelySilent()
        checking.forgetEndpoint()
        XCTAssertEqual(checking.silence, .checking(superseded: true))
        XCTAssertEqual(checking.finishSilenceCheck(.silent, now: Date(), interval: 30), .superseded, "a check in flight was about the old endpoint")
    }

    func testAHalfOpenSlotFreedByAnAnsweringProxyIsArmedAgainBySelection() {
        var breaker = UpstreamCircuitBreaker()
        let now = Date()
        breaker.recordFailure(now: now, threshold: 1, windowSeconds: 0, baseOpenInterval: 30, maxOpenInterval: 300)
        XCTAssertNotNil(breaker.tryHalfOpen(now: now.addingTimeInterval(30)))
        XCTAssertFalse(breaker.armHalfOpenProbe(), "the slot is taken by the half-open probe")

        XCTAssertTrue(breaker.releaseHalfOpenProbe())

        XCTAssertEqual(breaker.state, .halfOpen, "the proxy answered for itself, but no exchange succeeded, so the breaker does not close")
        XCTAssertFalse(breaker.halfOpenProbeInFlight)
        XCTAssertFalse(breaker.releaseHalfOpenProbe(), "nothing to release twice")
        XCTAssertTrue(breaker.armHalfOpenProbe(), "the next exchange is the probe")
        XCTAssertTrue(breaker.halfOpenProbeInFlight)

        var closed = UpstreamCircuitBreaker()
        XCTAssertFalse(closed.releaseHalfOpenProbe(), "a closed breaker has no slot")
    }

    func testASilentOrRefusedCheckRanksTheUpstreamBehindForTheInterval() {
        for outcome in [UpstreamCircuitBreaker.SilenceCheckOutcome.silent, .refused] {
            var breaker = decisivelySilent()
            let now = Date()

            XCTAssertEqual(breaker.finishSilenceCheck(outcome, now: now, interval: 30), .rankedBehind, outcome.name)

            XCTAssertTrue(breaker.ranksBehind(at: now.addingTimeInterval(29)), outcome.name)
            XCTAssertEqual(breaker.recordUnanswered().step, .held, "a ranked upstream is not asked again: \(outcome.name)")
            XCTAssertFalse(breaker.endRankingIfDue(now: now.addingTimeInterval(29)))
            XCTAssertTrue(breaker.endRankingIfDue(now: now.addingTimeInterval(30)), "it competes again after the interval")
            XCTAssertEqual(breaker.recordUnanswered().step, .check, "the failure still stands, so the next silence asks at once")
        }
    }

    func testAnUnaskedCheckChangesNothingAndTheNextSilenceAsksAgain() {
        var breaker = decisivelySilent()

        XCTAssertEqual(breaker.finishSilenceCheck(.unasked, now: Date(), interval: 30), .kept)

        XCTAssertFalse(breaker.ranksBehind(at: Date()))
        XCTAssertEqual(breaker.recordUnanswered().step, .check)
    }

    func testAnAnswerWhileTheCheckRunsSupersedesASilentCheck() {
        var breaker = decisivelySilent()
        breaker.recordSuccess(latencyMS: 10)
        XCTAssertEqual(breaker.silence, .checking(superseded: true), "the check still runs, and only its outcome frees the slot")
        XCTAssertEqual(breaker.recordUnanswered().step, .held)

        XCTAssertEqual(breaker.finishSilenceCheck(.silent, now: Date(), interval: 30), .superseded)
        XCTAssertFalse(breaker.ranksBehind(at: Date()), "the answer is newer evidence than the check")
    }

    func testAnAnswerWhileTheCheckRunsSupersedesItEvenAfterANewDecisiveSilence() {
        var breaker = decisivelySilent()
        breaker.recordSuccess(latencyMS: 10)
        _ = breaker.recordUnanswered()
        XCTAssertEqual(breaker.recordUnanswered().step, .held, "the first check still runs")

        XCTAssertEqual(breaker.finishSilenceCheck(.silent, now: Date(), interval: 30), .superseded,
                       "the check began before the answer, so it is older evidence")
        XCTAssertFalse(breaker.ranksBehind(at: Date()))
        XCTAssertEqual(breaker.recordUnanswered().step, .check, "the silences after the answer still stand, so the next one asks")
    }

    func testAResetWhileTheCheckRunsSupersedesIt() {
        var breaker = decisivelySilent()
        breaker.reset(reason: .vpnFlapRecovered, baseOpenInterval: 30)
        _ = breaker.recordUnanswered()
        XCTAssertEqual(breaker.recordUnanswered().step, .held, "the first check still runs")

        XCTAssertEqual(breaker.finishSilenceCheck(.silent, now: Date(), interval: 30), .superseded,
                       "the check asked over the path the flap replaced")
        XCTAssertFalse(breaker.ranksBehind(at: Date()))
    }

    func testAnAnswerOrAResetEndsARanking() {
        let now = Date()
        var answered = decisivelySilent()
        _ = answered.finishSilenceCheck(.silent, now: now, interval: 30)
        answered.recordSuccess(latencyMS: 10)
        XCTAssertFalse(answered.ranksBehind(at: now))

        var reset = decisivelySilent()
        _ = reset.finishSilenceCheck(.silent, now: now, interval: 30)
        reset.reset(reason: .vpnFlapRecovered, baseOpenInterval: 30)
        XCTAssertFalse(reset.ranksBehind(at: now))
        XCTAssertEqual(reset.silences, UnansweredStreak())
    }

    func testOpeningTheBreakerEndsARankingAndSupersedesACheck() {
        let now = Date()
        var ranked = decisivelySilent()
        _ = ranked.finishSilenceCheck(.silent, now: now, interval: 30)
        ranked.recordFailure(now: now, threshold: 1, windowSeconds: 0, baseOpenInterval: 30, maxOpenInterval: 300)
        XCTAssertEqual(ranked.state, .open)
        XCTAssertFalse(ranked.ranksBehind(at: now), "selection must see the half-open probe once the backoff ends")

        var checking = decisivelySilent()
        checking.recordFailure(now: now, threshold: 1, windowSeconds: 0, baseOpenInterval: 30, maxOpenInterval: 300)
        XCTAssertEqual(checking.finishSilenceCheck(.answered(status: 200, latencyMS: 5), now: now, interval: 30), .superseded)
        XCTAssertEqual(checking.state, .open, "only the half-open probe closes an open breaker")
        XCTAssertEqual(checking.silence, .none)
    }
}
