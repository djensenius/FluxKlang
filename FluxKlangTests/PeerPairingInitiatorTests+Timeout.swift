import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension PeerPairingInitiatorTests {
    /// In-flight stages with the one step each accepts (the approval needs a revealed nonce).
    private var stepsOfTheDeadline: [(Stage, Step)] {
        [(.committed, .sent), (.awaitingHostNonce, .host(Self.nonce(60))), (.showing, .confirm(true)),
         (.showing, .confirm(false)), (.awaitingDecision, .outcome(false)), (.awaitingDecision, .outcome(true))]
    }

    @Test("Every step is in time at 59.999 seconds and timed out at exactly 60, measured from the supplied instants")
    func timeoutEveryStepIsInTimeAt59999MillisecondsAndTimedOutAtExactly60Seconds() throws {
        #expect(PeerPairingInitiator.decisionWindow == .seconds(60))
        for (stage, step) in stepsOfTheDeadline {
            var inTime = try initiator(at: stage, revealed: true)
            #expect(refusal(of: step, on: &inTime, at: start + .milliseconds(59_999)) == nil, "\(stage) \(step.kind)")
            #expect(inTime.status != .timedOut, "\(stage) \(step.kind)")
            for late in [Duration.seconds(60), .milliseconds(60_001), .seconds(3_600)] {
                var expired = try initiator(at: stage, revealed: true)
                #expect(refusal(of: step, on: &expired, at: start + late) == .timedOut, "\(stage) \(step.kind)")
                #expect(expired.status == .timedOut && expired.revealToSend(now: start) == nil)
                #expect(refusal(of: step, on: &expired, at: start) == .unexpectedStep, "terminal after timeout")
            }
        }
    }

    @Test("Tick keeps an attempt at 59.999 seconds and times it out at exactly 60")
    func timeoutTickKeepsTheAttemptAt59999MillisecondsAndEndsItAt60Seconds() throws {
        for stage in [Stage.committed, .awaitingHostNonce, .showing, .awaitingDecision] {
            var inTime = try initiator(at: stage)
            let before = inTime
            #expect(inTime.tick(now: start + .milliseconds(59_999)) == before.status, "\(stage)")
            #expect(inTime == before, "\(stage)")
            var expired = try initiator(at: stage)
            #expect(expired.tick(now: start + .seconds(60)) == .timedOut, "\(stage)")
            #expect(expired.status == .timedOut && expired.revealToSend(now: start) == nil)
        }
    }

    @Test("The deadline counts from the start of the attempt: later steps do not extend it")
    func timeoutIsCountedFromTheStartOfTheAttemptNotFromLaterSteps() throws {
        var initiator = PeerPairingInitiator()
        _ = try initiator.startAttempt(spec(), nonce: Self.nonce(1), now: start)
        try initiator.requestSent(now: start + .seconds(30))
        _ = try initiator.receiveHostNonce(Self.nonce(2), now: start + .milliseconds(59_999))
        #expect(refusal(of: .confirm(true), on: &initiator, at: start + .seconds(60)) == .timedOut)
        #expect(initiator.status == .timedOut)
    }

    @Test("An expired deadline resolves to timed out before an out-of-phase step is looked at")
    func timeoutExpiredAndOutOfPhaseStepResolvesToTimedOutFirst() throws {
        let allowed: [Stage: String] = [.committed: "sent", .awaitingHostNonce: "host", .showing: "confirm",
                                        .awaitingDecision: "outcome"]
        for (stage, kind) in allowed {
            for step in allSteps() where step.kind != kind && step.kind != "start" {
                var initiator = try self.initiator(at: stage)
                let late = start + PeerPairingInitiator.decisionWindow
                #expect(refusal(of: step, on: &initiator, at: late) == .timedOut, "\(stage) \(step.kind)")
                #expect(initiator.status == .timedOut, "\(stage) \(step.kind)")
            }
        }
    }

    @Test("A finished attempt is never timed out and keeps refusing as unexpected")
    func timeoutNeverChangesAFinishedAttempt() throws {
        for stage in [Stage.idle, .paired, .denied, .timedOut] {
            var initiator = try self.initiator(at: stage)
            let before = initiator
            #expect(initiator.tick(now: start + .seconds(3_600)) == before.status, "\(stage)")
            #expect(initiator == before, "\(stage)")
            #expect(refusal(of: .sent, on: &initiator, at: start + .seconds(3_600)) == .unexpectedStep, "\(stage)")
            #expect(initiator == before, "\(stage)")
        }
    }

    @Test("The nonce is revealed at 59.999 seconds and never at or after the deadline")
    func timeoutRevealAtTheDeadlineIsNilAndEndsTheAttempt() throws {
        var inTime = try initiator(at: .showing)
        #expect(inTime.revealToSend(now: start + .milliseconds(59_999)) == Self.nonce(1))
        var expired = try initiator(at: .showing)
        #expect(expired.revealToSend(now: start + .seconds(60)) == nil)
        #expect(expired.status == .timedOut)
    }

    @Test("A start while an attempt runs is busy even past its deadline, and works after a tick ends it")
    func timeoutStartDoesNotTickAnExpiredAttemptButATickFreesTheInitiator() throws {
        var initiator = try self.initiator(at: .awaitingHostNonce)
        let before = initiator
        let late = start + .seconds(61)
        #expect(refusal(of: .start(spec(), Self.nonce(77)), on: &initiator, at: late) == .busy)
        #expect(initiator == before)
        #expect(initiator.tick(now: late) == .timedOut)
        #expect(refusal(of: .start(spec(), Self.nonce(77)), on: &initiator, at: late) == nil)
        #expect(initiator.status == .committed)
        #expect(initiator.tick(now: late + .milliseconds(59_999)) == .committed)
        #expect(initiator.tick(now: late + .seconds(60)) == .timedOut)
    }
}
