import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension PluginHostNegotiationTests {
    private static func ledger(_ attempts: Int = 3) throws -> ReprepareLedger {
        ReprepareLedger(budget: try ReprepareBudget(maximumAttempts: attempts))
    }

    /// A ledger driven into `.preparing` at attempt 1 by a format change.
    private static func preparingLedger(_ attempts: Int = 3) throws -> ReprepareLedger {
        try ledger(attempts).observing(.format).ledger
    }

    /// A budget-1 ledger that has run out: silenced with attempts == 1.
    private static func silencedLedger() throws -> ReprepareLedger {
        try preparingLedger(1).observing(.format).ledger
    }

    private static let forcing: [RenderLiveChange] = [.maximumFrames, .busLayout, .format, .sampleRate]

    /// Completes the outstanding preparation of `ledger` with its own token.
    private static func record(_ ledger: ReprepareLedger, _ succeeded: Bool) throws -> ReprepareTransition {
        let token = try #require(ledger.pendingToken)
        return try ledger.recordingPreparation(token, succeeded: succeeded)
    }

    @Test("reprepare budget accepts 1 and 8 and refuses 0, 9 and -1")
    func reprepareBudgetBounds() throws {
        #expect(try ReprepareBudget(maximumAttempts: 1).maximumAttempts == 1)
        #expect(try ReprepareBudget(maximumAttempts: 8).maximumAttempts == 8)
        for bad in [0, 9, -1, Int.max, Int.min] {
            #expect(throws: ReprepareFault.invalidBudget(bad)) { try ReprepareBudget(maximumAttempts: bad) }
        }
        #expect(ReprepareBudget.standard.maximumAttempts == 3)
        #expect(try ReprepareBudget(maximumAttempts: 3) == ReprepareBudget.standard)
    }

    @Test("reprepare statuses and changes have exact cases and raw values")
    func reprepareStatusAndChangeCases() {
        #expect(ReprepareStatus.allCases == [.rendering, .preparing, .silenced])
        #expect(ReprepareStatus.allCases.map(\.rawValue) == ["rendering", "preparing", "silenced"])
        #expect(RenderLiveChange.allCases == [.maximumFrames, .busLayout, .format, .sampleRate, .latency])
        let names = ["maximumFrames", "busLayout", "format", "sampleRate", "latency"]
        #expect(RenderLiveChange.allCases.map(\.rawValue) == names)
    }

    @Test("reprepare a new ledger is rendering with zero attempts")
    func reprepareNewLedgerStartsRendering() throws {
        let fresh = ReprepareLedger(budget: .standard)
        #expect(fresh.status == .rendering)
        #expect(fresh.attempts == 0)
        #expect(fresh.budget == ReprepareBudget.standard)
    }

    @Test("reprepare full walk with budget 3 reprepares at attempts 1, 2 and 3 and then silences")
    func reprepareFullWalkWithBudgetThree() throws {
        let first = try Self.ledger(3).observing(.format)
        #expect(first.decision == .reprepare(attempt: 1))
        #expect(first.ledger.status == .preparing)
        #expect(first.ledger.attempts == 1)
        let second = try Self.record(first.ledger, false)
        #expect(second.decision == .reprepare(attempt: 2))
        #expect(second.ledger.attempts == 2)
        let third = try Self.record(second.ledger, false)
        #expect(third.decision == .reprepare(attempt: 3))
        #expect(third.ledger.attempts == 3)
        #expect(third.ledger.status == .preparing)
        let last = try Self.record(third.ledger, false)
        #expect(last.decision == .silence(.budgetExhausted(attempts: 3, maximum: 3)))
        #expect(last.ledger.status == .silenced)
        #expect(last.ledger.attempts == 3)
    }

    @Test("reprepare latency changes only invalidate delay plans in every status and keep the ledger")
    func reprepareLatencyInEveryStatus() throws {
        let ledgers = [try Self.ledger(), try Self.preparingLedger(), try Self.silencedLedger()]
        #expect(ledgers.map(\.status) == [.rendering, .preparing, .silenced])
        for ledger in ledgers {
            let transition = ledger.observing(.latency)
            #expect(transition.decision == .invalidateDelayPlans)
            #expect(transition.ledger == ledger)
        }
    }

    @Test("reprepare each of the four forcing changes from rendering asks for attempt 1")
    func reprepareForcingChangesFromRendering() throws {
        let expected: [RenderLiveChange: ReprepareDecision] = [
            .maximumFrames: .reprepare(attempt: 1), .busLayout: .reprepare(attempt: 1),
            .format: .reprepare(attempt: 1), .sampleRate: .reprepare(attempt: 1),
            .latency: .invalidateDelayPlans
        ]
        for change in RenderLiveChange.allCases {
            let transition = try Self.ledger().observing(change)
            #expect(transition.decision == expected[change])
            let forces = change != .latency
            #expect(transition.ledger.status == (forces ? .preparing : .rendering))
            #expect(transition.ledger.attempts == (forces ? 1 : 0))
        }
        #expect(Self.forcing.count == RenderLiveChange.allCases.count - 1)
    }

    @Test("reprepare a change observed while preparing supersedes the prepare and consumes an attempt")
    func reprepareChangeWhilePreparingConsumesAnAttempt() throws {
        var ledger = try Self.preparingLedger()
        let expected: [ReprepareDecision] = [
            .reprepare(attempt: 2), .reprepare(attempt: 3),
            .silence(.budgetExhausted(attempts: 3, maximum: 3)), .remainSilent
        ]
        for (change, decision) in zip(Self.forcing, expected) {
            let transition = ledger.observing(change)
            #expect(transition.decision == decision)
            ledger = transition.ledger
        }
        #expect(ledger.status == .silenced)
        #expect(ledger.attempts == 3)
    }

    @Test("reprepare at attempts equal to the budget the next change silences and one fewer still prepares")
    func reprepareAttemptsBoundary() throws {
        for maximum in [1, 2, 3, 8] {
            var ledger = try Self.ledger(maximum)
            for expectedAttempt in 1...maximum {
                let transition = ledger.observing(.busLayout)
                #expect(transition.decision == .reprepare(attempt: expectedAttempt))
                ledger = transition.ledger
            }
            #expect(ledger.attempts == maximum)
            #expect(ledger.status == .preparing)
            let exhausted = ledger.observing(.busLayout)
            #expect(exhausted.decision == .silence(.budgetExhausted(attempts: maximum, maximum: maximum)))
            #expect(exhausted.ledger.status == .silenced)
            #expect(exhausted.ledger.attempts == maximum)
        }
    }

    @Test("reprepare a silenced ledger is terminal and every change leaves it unchanged")
    func reprepareSilencedIsTerminal() throws {
        let silenced = try Self.silencedLedger()
        #expect(silenced.status == .silenced)
        for change in Self.forcing {
            let transition = silenced.observing(change)
            #expect(transition.decision == .remainSilent)
            #expect(transition.ledger == silenced)
        }
        let earlier = try #require(Self.preparingLedger(1).pendingToken)
        #expect(throws: ReprepareFault.notPreparing(.silenced)) {
            try silenced.recordingPreparation(earlier, succeeded: true)
        }
        #expect(throws: ReprepareFault.notPreparing(.silenced)) {
            try silenced.recordingPreparation(earlier, succeeded: false)
        }
    }

    @Test("reprepare recording a preparation while rendering is refused with the current status")
    func reprepareRecordingWhileRenderingIsRefused() throws {
        let rendering = try Self.ledger()
        let before = rendering
        let earlier = try #require(Self.preparingLedger().pendingToken)
        for succeeded in [true, false] {
            #expect(throws: ReprepareFault.notPreparing(.rendering)) {
                try rendering.recordingPreparation(earlier, succeeded: succeeded)
            }
        }
        #expect(rendering == before)
    }

    @Test("reprepare success resets the attempts and a later change starts again at attempt 1")
    func reprepareSuccessResetsAttempts() throws {
        let failed = try Self.record(Self.preparingLedger(), false)
        #expect(failed.ledger.attempts == 2)
        let resumed = try Self.record(failed.ledger, true)
        #expect(resumed.decision == .resume)
        #expect(resumed.ledger.status == .rendering)
        #expect(resumed.ledger.attempts == 0)
        #expect(resumed.ledger.budget == failed.ledger.budget)
        let again = resumed.ledger.observing(.sampleRate)
        #expect(again.decision == .reprepare(attempt: 1))
    }

    @Test("reprepare budget 1 allows one attempt and the first failure silences")
    func reprepareBudgetOneExhaustsOnTheFirstFailure() throws {
        let preparing = try Self.preparingLedger(1)
        #expect(preparing.attempts == 1)
        let failed = try Self.record(preparing, false)
        #expect(failed.decision == .silence(.budgetExhausted(attempts: 1, maximum: 1)))
        #expect(failed.ledger.status == .silenced)
        #expect(try Self.record(Self.preparingLedger(1), true).decision == .resume)
    }

    @Test("reprepare end to end: stale resources silence, the ledger reprepares and the guard dispatches again")
    func reprepareEndToEndRecovery() throws {
        let negotiated = try Self.negotiatedMaximum()
        var fake = FakeHostedProcessor(capabilities: try Self.makeCaps(), layout: try Self.makeLayout(), script: [])
        let live = try CapabilityGeneration.initial.advancing(.resources)
        let stale = DispatchGuard.decide(Self.request(64, stamp: live), negotiated: negotiated, live: live)
        #expect(stale == .silence(.staleResources))
        fake.dispatch(stale, negotiated: negotiated)
        let transition = try Self.ledger().observing(.format)
        #expect(transition.decision == .reprepare(attempt: 1))
        let renegotiated = try fake.negotiate(Self.makeSpec(frames: 1_024, format: .float64), generation: live)
        #expect(renegotiated.generation == live)
        #expect(renegotiated.spec.format == .float64)
        let resumed = try Self.record(transition.ledger, true)
        #expect(resumed.decision == .resume)
        let decision = DispatchGuard.decide(Self.request(1_024, stamp: live), negotiated: renegotiated, live: live)
        #expect(decision == .dispatch(frames: 1_024))
        fake.dispatch(decision, negotiated: renegotiated)
        #expect(fake.dispatchedFrames == [1_024])
        #expect(fake.silencedCalls == 1)
        #expect(fake.outOfBoundsAttempts == 0)
    }

    @Test("reprepare end to end: repeated failures end in terminal silence counted by the fake")
    func reprepareEndToEndFailureEndsInSilence() throws {
        let negotiated = try Self.negotiatedMaximum()
        var fake = FakeHostedProcessor(capabilities: try Self.makeCaps(), layout: try Self.makeLayout(), script: [])
        let live = try CapabilityGeneration.initial.advancing(.resources)
        var transition = try Self.ledger().observing(.busLayout)
        var decisions: [ReprepareDecision] = [transition.decision]
        while transition.ledger.status == .preparing {
            let decision = DispatchGuard.decide(Self.request(64), negotiated: negotiated, live: live)
            fake.dispatch(decision, negotiated: negotiated)
            transition = try Self.record(transition.ledger, false)
            decisions.append(transition.decision)
        }
        #expect(decisions == [
            .reprepare(attempt: 1), .reprepare(attempt: 2), .reprepare(attempt: 3),
            .silence(.budgetExhausted(attempts: 3, maximum: 3))
        ])
        #expect(fake.silencedCalls == 3)
        #expect(fake.dispatchedFrames.isEmpty)
        #expect(transition.ledger.observing(.busLayout).decision == .remainSilent)
    }

    @Test("reprepare a late success of a superseded attempt is refused and attempt two then completes normally")
    func reprepareLateSuccessAfterSupersessionIsRefused() throws {
        let first = try Self.ledger(3).observing(.format)
        let second = first.ledger.observing(.busLayout)
        let early = try #require(first.ledger.pendingToken)
        let current = try #require(second.ledger.pendingToken)
        #expect(early != current)
        #expect(second.decision == .reprepare(attempt: 2))
        let before = second.ledger
        #expect(throws: ReprepareFault.superseded(presented: early, current: current)) {
            try before.recordingPreparation(early, succeeded: true)
        }
        #expect(before == second.ledger)
        #expect(before.status == .preparing)
        #expect(before.attempts == 2)
        let resumed = try before.recordingPreparation(current, succeeded: true)
        #expect(resumed.decision == .resume)
        #expect(resumed.ledger.status == .rendering)
        #expect(resumed.ledger.attempts == 0)
        #expect(resumed.ledger.pendingToken == nil)
    }

    @Test("reprepare a late failure of a superseded attempt is refused and does not consume the current budget")
    func reprepareLateFailureAfterSupersessionDoesNotConsumeTheBudget() throws {
        let first = try Self.ledger(3).observing(.format)
        let second = first.ledger.observing(.busLayout)
        let early = try #require(first.ledger.pendingToken)
        let current = try #require(second.ledger.pendingToken)
        #expect(throws: ReprepareFault.superseded(presented: early, current: current)) {
            try second.ledger.recordingPreparation(early, succeeded: false)
        }
        #expect(second.ledger.attempts == 2)
        let third = try second.ledger.recordingPreparation(current, succeeded: false)
        #expect(third.decision == .reprepare(attempt: 3))
        #expect(third.ledger.attempts == 3)
        let lastToken = try #require(third.ledger.pendingToken)
        for stale in [early, current] {
            #expect(throws: ReprepareFault.superseded(presented: stale, current: lastToken)) {
                try third.ledger.recordingPreparation(stale, succeeded: false)
            }
        }
        let last = try third.ledger.recordingPreparation(lastToken, succeeded: false)
        #expect(last.decision == .silence(.budgetExhausted(attempts: 3, maximum: 3)))
    }

    @Test("reprepare replaying a completed token is refused while rendering and after a newer attempt starts")
    func reprepareReplayOfACompletedTokenIsRefused() throws {
        let started = try Self.ledger(3).observing(.format)
        let used = try #require(started.ledger.pendingToken)
        let resumed = try started.ledger.recordingPreparation(used, succeeded: true)
        #expect(throws: ReprepareFault.notPreparing(.rendering)) {
            try resumed.ledger.recordingPreparation(used, succeeded: true)
        }
        let again = resumed.ledger.observing(.sampleRate)
        let newer = try #require(again.ledger.pendingToken)
        #expect(newer != used)
        #expect(throws: ReprepareFault.superseded(presented: used, current: newer)) {
            try again.ledger.recordingPreparation(used, succeeded: true)
        }
        #expect(again.ledger.status == .preparing)
        #expect(again.ledger.attempts == 1)
    }

    @Test("reprepare a token issued before a success reset is refused afterwards")
    func reprepareTokenFromBeforeAResetIsRefused() throws {
        let first = try Self.ledger(3).observing(.format)
        let second = try Self.record(first.ledger, false)
        let tokenOne = try #require(first.ledger.pendingToken)
        let tokenTwo = try #require(second.ledger.pendingToken)
        let reset = try Self.record(second.ledger, true)
        #expect(reset.ledger.attempts == 0)
        let fresh = reset.ledger.observing(.format)
        let tokenThree = try #require(fresh.ledger.pendingToken)
        #expect(fresh.ledger.attempts == 1)
        #expect(fresh.ledger.issued == 3)
        for stale in [tokenOne, tokenTwo] {
            #expect(throws: ReprepareFault.superseded(presented: stale, current: tokenThree)) {
                try fresh.ledger.recordingPreparation(stale, succeeded: true)
            }
        }
        #expect(try Self.record(fresh.ledger, true).decision == .resume)
    }

    @Test("reprepare superseded results leave a ledger at the budget limit and one change later it silences")
    func reprepareSupersededAttemptsAtTheBudgetBoundary() throws {
        for maximum in [1, 2, 3, 8] {
            var ledger = try Self.ledger(maximum)
            var tokens: [ReprepareToken] = []
            for expectedAttempt in 1...maximum {
                let transition = ledger.observing(.busLayout)
                #expect(transition.decision == .reprepare(attempt: expectedAttempt))
                ledger = transition.ledger
                tokens.append(try #require(ledger.pendingToken))
            }
            let latest = try #require(tokens.last)
            let before = ledger
            for stale in tokens.dropLast() {
                for succeeded in [true, false] {
                    #expect(throws: ReprepareFault.superseded(presented: stale, current: latest)) {
                        try before.recordingPreparation(stale, succeeded: succeeded)
                    }
                }
            }
            #expect(ledger == before)
            #expect(ledger.attempts == maximum)
            let failed = try before.recordingPreparation(latest, succeeded: false)
            #expect(failed.decision == .silence(.budgetExhausted(attempts: maximum, maximum: maximum)))
            #expect(failed.ledger.pendingToken == nil)
            #expect(failed.ledger.issued == maximum)
        }
    }

    @Test("reprepare tokens never repeat across supersessions, resets and silence")
    func reprepareTokensNeverRepeat() throws {
        var ledger = try Self.ledger(8)
        var tokens: [ReprepareToken] = []
        for round in 1...40 {
            for change in [RenderLiveChange.format, .busLayout] {
                ledger = ledger.observing(change).ledger
                tokens.append(try #require(ledger.pendingToken))
            }
            #expect(ledger.issued == round * 2)
            ledger = try Self.record(ledger, true).ledger
            #expect(ledger.issued == round * 2)
            #expect(ledger.pendingToken == nil)
        }
        #expect(tokens.count == 80)
        #expect(Set(tokens).count == 80)
        let silenced = try Self.silencedLedger()
        #expect(silenced.pendingToken == nil)
        #expect(silenced.issued == 1)
    }

    private struct WalkModel {
        var status = ReprepareStatus.rendering
        var attempts = 0
        let maximum: Int

        mutating func escalate() {
            if attempts >= maximum {
                status = .silenced
            } else {
                status = .preparing
                attempts += 1
            }
        }

        /// Returns false when the operation is refused. Operations 0..<5 are the changes, then success, failure.
        mutating func apply(_ operation: Int) -> Bool {
            let changes = RenderLiveChange.allCases
            if operation < changes.count {
                if changes[operation] != .latency && status != .silenced { escalate() }
                return true
            }
            guard status == .preparing else { return false }
            if operation == changes.count {
                status = .rendering
                attempts = 0
            } else {
                escalate()
            }
            return true
        }
    }

    private struct WalkResult {
        var sequences = 0
        var violations = 0
        var refusals = 0
    }

    private static func step(_ operation: Int, _ ledger: ReprepareLedger) -> ReprepareTransition? {
        let changes = RenderLiveChange.allCases
        if operation < changes.count { return ledger.observing(changes[operation]) }
        guard let token = ledger.pendingToken else { return nil }
        return try? ledger.recordingPreparation(token, succeeded: operation == changes.count)
    }

    private static func walk(maximum: Int) throws -> WalkResult {
        let operations = RenderLiveChange.allCases.count + 2
        var result = WalkResult()
        for length in 1...6 {
            var total = 1
            for _ in 0..<length { total *= operations }
            for code in 0..<total {
                var ledger = try Self.ledger(maximum)
                var model = WalkModel(maximum: maximum)
                var remaining = code
                var wasSilenced = false
                for _ in 0..<length {
                    let operation = remaining % operations
                    remaining /= operations
                    let accepted = model.apply(operation)
                    let transition = step(operation, ledger)
                    guard let transition else {
                        result.refusals += 1
                        result.violations += accepted ? 1 : 0
                        continue
                    }
                    ledger = transition.ledger
                    var bad = !accepted || ledger.status != model.status || ledger.attempts != model.attempts
                    bad = bad || ledger.attempts > maximum || (wasSilenced && ledger.status != .silenced)
                    if case .reprepare(let attempt) = transition.decision { bad = bad || attempt != ledger.attempts }
                    result.violations += bad ? 1 : 0
                    wasSilenced = ledger.status == .silenced
                }
                result.sequences += 1
            }
        }
        return result
    }

    @Test("reprepare every sequence of up to six changes and results keeps the attempts bounded and silence terminal")
    func reprepareExhaustiveWalkKeepsTheInvariants() throws {
        for maximum in [1, 2, 3, 8] {
            let result = try Self.walk(maximum: maximum)
            #expect(result.sequences == 137_256)
            #expect(result.violations == 0)
            #expect(result.refusals > 0)
        }
    }
}
