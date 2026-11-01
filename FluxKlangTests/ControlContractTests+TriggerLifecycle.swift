import Testing
@testable import FluxKlang

extension ControlContractTests {
    struct TriggerLifecycle {
        private let trigger = TriggerID(validated: "trigger.first")
        private let other = TriggerID(validated: "trigger.other")

        private func fired(_ id: TriggerID) -> TriggerOutcome {
            TriggerOutcome(trigger: id, result: .fired, assignedFrame: 12, frame: 12, musicalMap: .initial)
        }

        private func diagnostics(_ id: TriggerID) -> [TriggerOutcome] {
            [TriggerOutcome(trigger: id, result: .dropped, reason: .invalidTiming),
             TriggerOutcome(trigger: id, result: .dropped, reason: .outsideLoop, musicalMap: .initial)]
                + [Int64.min, -1, 0, 12, Int64.max].map {
                    TriggerOutcome(trigger: id, result: .dropped, reason: .outsideLoop,
                                   assignedFrame: $0, musicalMap: .initial)
                }
        }

        @Test func diagnosticShapesPreserveOriginalTargetReferences() throws {
            for outcome in diagnostics(trigger) {
                var session = try TriggerSession(outcomeCapacity: 1)
                let token = session.currentToken
                let handle = try session.reserve(id: trigger, session: token)
                try session.completeDiagnostic(handle, outcome: outcome)
                #expect(session.currentToken == token)
                #expect(session.pendingCount == 0 && session.reservedOutcomeCount == 1)
                let queued = session.drain()
                #expect(queued.map(\.handle) == [handle] && queued.map(\.outcome) == [outcome])
                #expect(session.reservedOutcomeCount == 0 && session.drain().isEmpty)
            }
        }

        @Test func diagnosticsRemainInvalidCanonicalMediaWithoutConsumingReservations() throws {
            for outcome in diagnostics(trigger) {
                var session = try TriggerSession(outcomeCapacity: 1)
                let token = session.currentToken
                let handle = try session.reserve(id: trigger, session: token)
                #expect(throws: TriggerOutcomeValidationError.invalidShape) { try outcome.validateMediaShape() }
                #expect(throws: TriggerSessionError.invalidCompletion) {
                    try session.complete(handle, outcome: outcome)
                }
                #expect(session.currentToken == token && session.pendingCount == 1)
                #expect(session.reservedOutcomeCount == 1 && session.drain().isEmpty)
                try session.completeDiagnostic(handle, outcome: outcome)
                #expect(session.drain().first?.outcome == outcome)
            }
        }

        @Test func malformedDiagnosticsPreserveAllSessionState() throws {
            let key = GenerationKey(.context, GenerationSubject(validated: "context.main"))
            let valid = diagnostics(trigger)
            var invalid = [
                fired(trigger),
                TriggerOutcome(trigger: trigger, result: .cancelled, stale: .generation(key)),
                TriggerOutcome(trigger: trigger, result: .dropped, reason: .late, assignedFrame: 12)
            ]
            for outcome in invalid { try outcome.validateMediaShape() }
            for base in [valid[0], valid[1]] {
                for result in OutcomeResult.allCases where result != .dropped {
                    var changed = base
                    changed.result = result
                    invalid.append(changed)
                }
                for reason: DropReason? in [nil, .late, .notReady] {
                    var changed = base
                    changed.reason = reason
                    invalid.append(changed)
                }
                var changed = base
                changed.stale = .generation(key)
                invalid.append(changed)
                changed = base
                changed.frame = 0
                invalid.append(changed)
                for offset: Int64 in [-1, 1] {
                    changed = base
                    changed.startOffsetFrames = offset
                    invalid.append(changed)
                }
            }
            invalid += [
                TriggerOutcome(trigger: trigger, result: .dropped, reason: .invalidTiming, assignedFrame: 0),
                TriggerOutcome(trigger: trigger, result: .dropped, reason: .invalidTiming, musicalMap: .initial),
                TriggerOutcome(trigger: trigger, result: .dropped, reason: .outsideLoop),
                TriggerOutcome(trigger: trigger, result: .dropped, reason: .outsideLoop, assignedFrame: -1)
            ]
            for outcome in invalid {
                var session = try TriggerSession(outcomeCapacity: 2)
                let token = session.currentToken
                let queued = try session.reserve(id: other, session: token)
                try session.complete(queued, outcome: fired(other))
                let handle = try session.reserve(id: trigger, session: token)
                #expect(throws: TriggerSessionError.invalidCompletion) {
                    try session.completeDiagnostic(handle, outcome: outcome)
                }
                #expect(session.currentToken == token && session.pendingCount == 1)
                #expect(session.reservedOutcomeCount == 2)
                #expect(throws: TriggerSessionError.duplicateID) { try session.reserve(id: trigger, session: token) }
                #expect(throws: TriggerSessionError.outcomeCapacity) {
                    try session.reserve(id: TriggerID(validated: "trigger.extra"), session: token)
                }
                try session.completeDiagnostic(handle, outcome: valid[0])
                let drained = session.drain()
                #expect(drained.map(\.handle) == [queued, handle])
                #expect(drained.map(\.outcome) == [fired(other), valid[0]])
                _ = try session.reserve(id: TriggerID(validated: "trigger.extra"), session: token)
            }
        }

        @Test func diagnosticCompletionUsesSharedIdentityErrorPrecedence() throws {
            var session = try TriggerSession(outcomeCapacity: 2)
            let original = session.currentToken
            let old = try session.reserve(id: trigger, session: original)
            try session.completeDiagnostic(old, outcome: diagnostics(trigger)[0])
            _ = session.drain()
            let token = try session.rotateSession(expected: original)
            let live = try session.reserve(id: trigger, session: token)
            let completed = try session.reserve(id: other, session: token)
            try session.completeDiagnostic(completed, outcome: diagnostics(other)[0])
            var foreign = try TriggerSession(outcomeCapacity: 1)
            let foreignHandle = try foreign.reserve(id: trigger, session: foreign.currentToken)
            for diagnostic in [false, true] {
                for outcome in [fired(other), diagnostics(other)[0], TriggerOutcome(trigger: other, result: .fired)] {
                    #expect(throws: TriggerSessionError.mismatchedCompletion) {
                        if diagnostic { try session.completeDiagnostic(live, outcome: outcome) } else {
                            try session.complete(live, outcome: outcome)
                        }
                    }
                    for handle in [old, foreignHandle, completed] {
                        let error: TriggerSessionError = handle == completed ? .notPending : .staleSession
                        let mismatched = TriggerOutcome(trigger: trigger, result: .fired)
                        for payload in [outcome, mismatched] {
                            #expect(throws: error) {
                                if diagnostic { try session.completeDiagnostic(handle, outcome: payload) } else {
                                    try session.complete(handle, outcome: payload)
                                }
                            }
                            #expect(session.currentToken == token && session.pendingCount == 1)
                            #expect(session.reservedOutcomeCount == 2)
                        }
                    }
                }
            }
            try session.completeDiagnostic(live, outcome: diagnostics(trigger)[0])
            let drained = session.drain()
            #expect(drained.map(\.handle) == [completed, live])
            #expect(drained.map(\.outcome) == [diagnostics(other)[0], diagnostics(trigger)[0]])
        }

        @Test func canonicalAndDiagnosticCompletionAreMutuallyExactlyOnce() throws {
            for diagnosticFirst in [false, true] {
                var session = try TriggerSession(outcomeCapacity: 1)
                let token = session.currentToken
                let handle = try session.reserve(id: trigger, session: token)
                let diagnostic = diagnostics(trigger)[0]
                let accepted = diagnosticFirst ? diagnostic : fired(trigger)
                if diagnosticFirst { try session.completeDiagnostic(handle, outcome: accepted) } else {
                    try session.complete(handle, outcome: accepted)
                }
                for drained in [false, true] {
                    if drained {
                        let queued = session.drain()
                        #expect(queued.map(\.handle) == [handle] && queued.map(\.outcome) == [accepted])
                    }
                    #expect(throws: TriggerSessionError.notPending) {
                        try session.complete(handle, outcome: fired(trigger))
                    }
                    #expect(throws: TriggerSessionError.notPending) {
                        try session.completeDiagnostic(handle, outcome: diagnostic)
                    }
                    #expect(session.currentToken == token && session.pendingCount == 0)
                    #expect(session.reservedOutcomeCount == (drained ? 0 : 1))
                }
                #expect(session.drain().isEmpty)
            }
        }

        @Test func mixedCompletionsShareCapacityOrderingRotationAndSeenIDs() throws {
            var session = try TriggerSession(outcomeCapacity: 2)
            let token = session.currentToken
            let first = try session.reserve(id: trigger, session: token)
            let second = try session.reserve(id: other, session: token)
            let extra = TriggerID(validated: "trigger.extra")
            let diagnostic = diagnostics(other)[1]
            #expect(throws: TriggerSessionError.notQuiescent) { try session.rotateSession(expected: token) }
            try session.completeDiagnostic(second, outcome: diagnostic)
            #expect(session.pendingCount == 1 && session.reservedOutcomeCount == 2)
            #expect(throws: TriggerSessionError.notQuiescent) { try session.rotateSession(expected: token) }
            #expect(throws: TriggerSessionError.outcomeCapacity) { try session.reserve(id: extra, session: token) }
            try session.complete(first, outcome: fired(trigger))
            #expect(session.pendingCount == 0 && session.reservedOutcomeCount == 2)
            #expect(throws: TriggerSessionError.notQuiescent) { try session.rotateSession(expected: token) }
            #expect(throws: TriggerSessionError.outcomeCapacity) { try session.reserve(id: extra, session: token) }
            #expect(session.currentToken == token)
            let drained = session.drain()
            #expect(drained.map(\.handle) == [second, first])
            #expect(drained.map(\.outcome) == [diagnostic, fired(trigger)])
            #expect(session.reservedOutcomeCount == 0 && session.drain().isEmpty)
            for id in [trigger, other] {
                #expect(throws: TriggerSessionError.duplicateID) { try session.reserve(id: id, session: token) }
            }
            let third = try session.reserve(id: extra, session: token)
            #expect(throws: TriggerSessionError.notQuiescent) { try session.rotateSession(expected: token) }
            try session.completeDiagnostic(third, outcome: diagnostics(extra)[0])
            #expect(throws: TriggerSessionError.notQuiescent) { try session.rotateSession(expected: token) }
            #expect(session.drain().map(\.handle) == [third])
            let next = try session.rotateSession(expected: token)
            #expect(next != token)
            for id in [trigger, other, extra] {
                let reused = try session.reserve(id: id, session: next)
                try session.completeDiagnostic(reused, outcome: diagnostics(id)[0])
                #expect(session.drain().map(\.handle) == [reused])
            }
        }

        @Test func exhaustedIdentityBudgetRequiresExplicitRotationEvenAfterEveryDrain() throws {
            var session = try TriggerSession(outcomeCapacity: 1)
            let original = session.currentToken
            var retained: SessionOutcome?
            for index in 0..<65_536 {
                let id = try TriggerID("trigger.\(index)")
                let handle = try session.reserve(id: id, session: original)
                try session.complete(handle, outcome: fired(id))
                let outcomes = session.drain()
                #expect(outcomes.count == 1 && outcomes.first?.handle == handle)
                retained = outcomes.first
            }
            #expect(session.pendingCount == 0 && session.reservedOutcomeCount == 0)
            #expect(throws: TriggerSessionError.sessionExhausted) {
                try session.reserve(id: other, session: original)
            }
            let old = try #require(retained)
            #expect(throws: TriggerSessionError.duplicateID) {
                try session.reserve(id: old.handle.trigger, session: original)
            }
            #expect(session.currentToken == original && session.reservedOutcomeCount == 0)
            let next = try session.rotateSession(expected: original)
            #expect(next != original)
            let reused = try session.reserve(id: old.handle.trigger, session: next)
            try session.complete(reused, outcome: old.outcome)
            let new = try #require(session.drain().first)
            #expect(new.outcome == old.outcome && new.handle.trigger == old.handle.trigger)
            #expect(new.handle != old.handle && old.handle.session == original && new.handle.session == next)
            // Exhaustion refusal did not consume the extra identity.
            _ = try session.reserve(id: other, session: next)
        }

        @Test func staleAndForeignOperationsCannotAffectReusedPendingIdentity() throws {
            var session = try TriggerSession(outcomeCapacity: 2)
            let original = session.currentToken
            let old = try session.reserve(id: trigger, session: original)
            try session.complete(old, outcome: fired(trigger))
            _ = session.drain()
            let current = try session.rotateSession(expected: original)
            let live = try session.reserve(id: trigger, session: current)
            var foreign = try TriggerSession(outcomeCapacity: 2)
            let foreignHandle = try foreign.reserve(id: trigger, session: foreign.currentToken)
            for stale in [old, foreignHandle] {
                #expect(throws: TriggerSessionError.staleSession) {
                    try session.preflight(id: other, session: stale.session)
                }
                #expect(throws: TriggerSessionError.staleSession) {
                    try session.reserve(id: other, session: stale.session)
                }
                #expect(throws: TriggerSessionError.staleSession) {
                    try session.complete(stale, outcome: fired(trigger))
                }
                #expect(throws: TriggerSessionError.staleSession) {
                    try session.rotateSession(expected: stale.session)
                }
                #expect(session.currentToken == current)
                #expect(session.pendingCount == 1 && session.reservedOutcomeCount == 1)
                #expect(session.drain().isEmpty)
            }
            try session.complete(live, outcome: fired(trigger))
            #expect(session.drain().map(\.handle) == [live])
            _ = try session.reserve(id: other, session: current)
        }

        @Test func pendingAndUndrainedOutcomesBothBlockRotation() throws {
            var session = try TriggerSession(outcomeCapacity: 65_536)
            let token = session.currentToken
            let first = try session.reserve(id: trigger, session: token)
            let second = try session.reserve(id: other, session: token)
            #expect(throws: TriggerSessionError.notQuiescent) { try session.rotateSession(expected: token) }
            try session.complete(second, outcome: fired(other))
            #expect(throws: TriggerSessionError.notQuiescent) { try session.rotateSession(expected: token) }
            try session.complete(first, outcome: fired(trigger))
            #expect(session.pendingCount == 0 && session.reservedOutcomeCount == 2)
            #expect(throws: TriggerSessionError.notQuiescent) { try session.rotateSession(expected: token) }
            #expect(session.currentToken == token)
            let outcomes = session.drain()
            #expect(outcomes.map(\.handle) == [second, first])
            #expect(outcomes.map(\.outcome) == [fired(other), fired(trigger)])
            #expect(session.reservedOutcomeCount == 0 && session.drain().isEmpty)
            #expect(throws: TriggerSessionError.duplicateID) { try session.reserve(id: trigger, session: token) }
            #expect(try session.rotateSession(expected: token) != token)
        }

        @Test func capacityAndPreflightRefusalsConsumeNeitherIdentityNorReservation() throws {
            for capacity in [Int.min, 0, 65_537, Int.max] {
                #expect(throws: TriggerSessionError.invalidOutcomeCapacity) {
                    try TriggerSession(outcomeCapacity: capacity)
                }
            }
            var session = try TriggerSession(outcomeCapacity: 1)
            let token = session.currentToken
            try session.preflight(id: trigger, session: token)
            try session.preflight(id: other, session: token)
            #expect(session.pendingCount == 0 && session.reservedOutcomeCount == 0)
            let first = try session.reserve(id: trigger, session: token)
            for completed in [false, true] {
                if completed { try session.complete(first, outcome: fired(trigger)) }
                #expect(throws: TriggerSessionError.duplicateID) {
                    try session.reserve(id: trigger, session: token)
                }
                #expect(throws: TriggerSessionError.outcomeCapacity) {
                    try session.preflight(id: other, session: token)
                }
                #expect(throws: TriggerSessionError.outcomeCapacity) {
                    try session.reserve(id: other, session: token)
                }
                #expect(session.pendingCount == (completed ? 0 : 1) && session.reservedOutcomeCount == 1)
            }
            #expect(session.drain().map(\.handle) == [first])
            let second = try session.reserve(id: other, session: token)
            try session.complete(second, outcome: fired(other))
            #expect(session.drain().map(\.handle) == [second])
        }

        @Test func completionValidatesIdentityAndCanonicalShapeBeforeTransferringOwnership() throws {
            var session = try TriggerSession(outcomeCapacity: 1)
            let token = session.currentToken
            let handle = try session.reserve(id: trigger, session: token)
            #expect(throws: TriggerSessionError.mismatchedCompletion) {
                try session.complete(handle, outcome: fired(other))
            }
            let invalid = [
                TriggerOutcome(trigger: trigger, result: .fired),
                TriggerOutcome(trigger: trigger, result: .cancelled),
                TriggerOutcome(trigger: trigger, result: .joined,
                               assignedFrame: 10, frame: 20, startOffsetFrames: 9)
            ]
            for outcome in invalid {
                #expect(throws: TriggerSessionError.invalidCompletion) {
                    try session.complete(handle, outcome: outcome)
                }
                #expect(session.pendingCount == 1 && session.reservedOutcomeCount == 1)
                #expect(session.currentToken == token && session.drain().isEmpty)
            }
            let accepted = TriggerOutcome(trigger: trigger, result: .joined, assignedFrame: -10, frame: 20,
                                          startOffsetFrames: 30, musicalMap: try Generation(7))
            try session.complete(handle, outcome: accepted)
            #expect(throws: TriggerSessionError.notPending) { try session.complete(handle, outcome: accepted) }
            #expect(session.pendingCount == 0 && session.reservedOutcomeCount == 1)
            let outcome = try #require(session.drain().first)
            #expect(outcome.handle == handle && outcome.outcome == accepted)
            #expect(throws: TriggerSessionError.notPending) { try session.complete(handle, outcome: accepted) }
            #expect(session.reservedOutcomeCount == 0 && session.drain().isEmpty)
            #expect(throws: TriggerSessionError.duplicateID) { try session.reserve(id: trigger, session: token) }
        }

        @Test func generationChangesAndStaleOutcomesDoNotResetIdentityHistory() throws {
            let clock = ClockID(validated: "clock.sample")
            let context = GenerationKey(.context, GenerationSubject(validated: "context.main"))
            var ledger = try GenerationLedger(primaryClock: clock, musicalClock: nil, nominalRate: 48_000,
                                              declaring: [context])
            var session = try TriggerSession(outcomeCapacity: 1)
            let token = session.currentToken
            let handle = try session.reserve(id: trigger, session: token)
            try ledger.bump(context, reason: .contextChange)
            let stale = TriggerOutcome(trigger: trigger, result: .rejectedStale, stale: .generation(context))
            try session.complete(handle, outcome: stale)
            #expect(session.drain().first?.outcome == stale)
            try ledger.bump(ledger.primaryClock, reason: .deviceRestart)
            #expect(throws: TriggerSessionError.duplicateID) { try session.reserve(id: trigger, session: token) }
            #expect(session.currentToken == token && session.reservedOutcomeCount == 0)
            // The session has no ledger, generation-change callback or implicit reset API.
            let next = try session.rotateSession(expected: token)
            _ = try session.reserve(id: trigger, session: next)
        }
    }
}
