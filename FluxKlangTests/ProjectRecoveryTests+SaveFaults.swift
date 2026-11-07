import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension ProjectRecoveryTests {
    private static func recoveryFaultVersion(_ value: String) throws -> SaveContentVersion {
        try SaveContentVersion.make(digest: value)
    }

    private static func thirdAttemptID() throws -> SaveAttemptID {
        let base = try recoveryFaultVersion("foreign-base")
        let local = try recoveryFaultVersion("foreign-local")
        let fault = try SaveFault.make(category: .unknown)
        var foreign = SaveSession.make(initialVersion: base)
        _ = try foreign.reduce(.edit(local: local))
        var last: SaveAttemptID?
        for _ in 1...3 {
            let effects = try foreign.reduce(.saveRequested)
            guard case .beginWrite(_, let attempt) = effects.first else {
                Issue.record("Expected foreign attempt")
                throw SaveSessionRefusal.noPendingSave
            }
            last = attempt
            _ = try foreign.reduce(.saveFailed(attempt: attempt, fault: fault))
        }
        return try #require(last)
    }

    @Test func faultCategoriesAndDetailBoundary() throws {
        let categories: [SaveFaultCategory] = [.diskFull, .permissionDenied, .coordinationDenied, .unknown]
        for category in categories {
            #expect(try SaveFault.make(category: category).category == category)
        }
        let maximum = String(repeating: "f", count: SaveFault.maximumDetailUTF8Bytes)
        #expect(try SaveFault.make(category: .unknown, detail: maximum).detail?.utf8.count == 256)
        let multibyte = String(repeating: "é", count: 128)
        #expect(try SaveFault.make(category: .unknown, detail: multibyte).detail?.utf8.count == 256)
        #expect(throws: SaveSessionRefusal.invalidFaultDetailLength(258)) {
            try SaveFault.make(category: .unknown, detail: String(repeating: "é", count: 129))
        }
        #expect(throws: SaveSessionRefusal.invalidFaultDetailLength(257)) {
            try SaveFault.make(category: .unknown, detail: maximum + "x")
        }
    }

    @Test func attemptOrdinalIncrementIsCheckedAtItsBoundary() throws {
        #expect(try SaveAttemptID.nextOrdinal(after: UInt64.max - 1) == UInt64.max)
        #expect(throws: SaveSessionRefusal.attemptIdentifierExhausted) {
            try SaveAttemptID.nextOrdinal(after: UInt64.max)
        }
    }

    @Test func reducerRefusesAttemptOrdinalExhaustionAtomically() throws {
        let base = try Self.recoveryFaultVersion("ordinal-base")
        let local = try Self.recoveryFaultVersion("ordinal-local")
        var session = SaveSession.make(initialVersion: base, nextAttemptOrdinal: UInt64.max)
        _ = try session.reduce(.edit(local: local))
        let before = session
        #expect(throws: SaveSessionRefusal.attemptIdentifierExhausted) {
            try session.reduce(.saveRequested)
        }
        #expect(session == before)
    }

    @Test func unresolvedAttemptsAcceptEightAndRefuseNinthAtomically() throws {
        let base = try Self.recoveryFaultVersion("attempt-base")
        let local = try Self.recoveryFaultVersion("attempt-local")
        let fault = try SaveFault.make(category: .coordinationDenied)
        var session = SaveSession.make(initialVersion: base)
        _ = try session.reduce(.edit(local: local))

        var ids: [SaveAttemptID] = []
        for _ in 1...SaveSession.maximumUnresolvedAttempts {
            let effects = try session.reduce(.saveRequested)
            guard case .beginWrite(let version, let attempt) = effects.first else {
                Issue.record("Expected an attempt for the current version")
                return
            }
            #expect(version == local)
            ids.append(attempt)
            _ = try session.reduce(.saveFailed(attempt: attempt, fault: fault))
        }
        #expect(session.unresolvedAttempts == ids)
        #expect(session.unresolvedAttempts.count == 8)
        let last = try #require(ids.last)
        #expect(session.state == .failed(base: base, local: local, attempt: last, fault: fault))

        let beforeNPlusOne = session
        #expect(throws: SaveSessionRefusal.attemptLimitExceeded) {
            try session.reduce(.saveRequested)
        }
        #expect(session == beforeNPlusOne)
    }

    @Test func onlyMatchingCurrentCompletionOrKnownInterruptionConfirms() throws {
        let base = try Self.recoveryFaultVersion("completion-base")
        let local = try Self.recoveryFaultVersion("completion-local")
        let wrongVersion = try Self.recoveryFaultVersion("completion-wrong")
        let fault = try SaveFault.make(category: .unknown)
        var session = SaveSession.make(initialVersion: base)
        _ = try session.reduce(.edit(local: local))
        let first = try session.reduce(.saveRequested)
        guard case .beginWrite(_, let firstAttempt) = first.first else {
            Issue.record("Expected first attempt")
            return
        }
        _ = try session.reduce(.saveFailed(attempt: firstAttempt, fault: fault))
        let retry = try session.reduce(.saveRequested)
        guard case .beginWrite(_, let retryAttempt) = retry.first else {
            Issue.record("Expected retry attempt")
            return
        }

        let beforeStaleFailureWhileSaving = session
        #expect(throws: SaveSessionRefusal.staleCompletion) {
            try session.reduce(.saveFailed(attempt: firstAttempt, fault: fault))
        }
        #expect(session == beforeStaleFailureWhileSaving)

        let beforeWrongVersion = session
        #expect(throws: SaveSessionRefusal.staleCompletion) {
            try session.reduce(.saveCompleted(attempt: retryAttempt, version: wrongVersion))
        }
        #expect(session == beforeWrongVersion)

        let beforeOldCompletion = session
        #expect(throws: SaveSessionRefusal.staleCompletion) {
            try session.reduce(.saveCompleted(attempt: firstAttempt, version: local))
        }
        #expect(session == beforeOldCompletion)

        _ = try session.reduce(.saveFailed(attempt: retryAttempt, fault: fault))
        let beforeStaleFailureWhileFailed = session
        #expect(throws: SaveSessionRefusal.staleCompletion) {
            try session.reduce(.saveFailed(attempt: firstAttempt, fault: fault))
        }
        #expect(session == beforeStaleFailureWhileFailed)

        let beforeUnknownAttempt = session
        let unknownAttempt = try Self.thirdAttemptID()
        #expect(throws: SaveSessionRefusal.staleCompletion) {
            try session.reduce(.saveConfirmedAfterInterruption(
                attempt: unknownAttempt,
                version: local
            ))
        }
        #expect(session == beforeUnknownAttempt)
        #expect(try session.reduce(
            .saveConfirmedAfterInterruption(attempt: firstAttempt, version: local)
        ).isEmpty)
        #expect(session.state == .clean(version: local))
        let beforeDuplicateConfirmation = session
        #expect(throws: SaveSessionRefusal.noPendingSave) {
            try session.reduce(.saveConfirmedAfterInterruption(
                attempt: firstAttempt, version: local
            ))
        }
        #expect(session == beforeDuplicateConfirmation)
    }

    @Test func interruptedConfirmationStalenessPrecedesInFlightClassification() throws {
        let base = try Self.recoveryFaultVersion("stale-order-base")
        let local = try Self.recoveryFaultVersion("stale-order-local")
        let wrongVersion = try Self.recoveryFaultVersion("stale-order-wrong")
        let fault = try SaveFault.make(category: .unknown)
        var session = SaveSession.make(initialVersion: base)
        _ = try session.reduce(.edit(local: local))
        let first = try session.reduce(.saveRequested)
        guard case .beginWrite(_, let firstAttempt) = first.first else {
            Issue.record("Expected first write")
            return
        }
        _ = try session.reduce(.saveFailed(attempt: firstAttempt, fault: fault))
        let retry = try session.reduce(.saveRequested)
        guard case .beginWrite = retry.first else {
            Issue.record("Expected in-flight retry")
            return
        }
        let unknownAttempt = try Self.thirdAttemptID()

        let beforeUnknown = session
        #expect(throws: SaveSessionRefusal.staleCompletion) {
            try session.reduce(.saveConfirmedAfterInterruption(
                attempt: unknownAttempt, version: local
            ))
        }
        #expect(session == beforeUnknown)

        let beforeWrongVersion = session
        #expect(throws: SaveSessionRefusal.staleCompletion) {
            try session.reduce(.saveConfirmedAfterInterruption(
                attempt: firstAttempt, version: wrongVersion
            ))
        }
        #expect(session == beforeWrongVersion)

        var resolvedSession = SaveSession.make(initialVersion: base)
        _ = try resolvedSession.reduce(.edit(local: local))
        let resolvedWrite = try resolvedSession.reduce(.saveRequested)
        guard case .beginWrite(_, let resolvedAttempt) = resolvedWrite.first else {
            Issue.record("Expected resolved attempt")
            return
        }
        _ = try resolvedSession.reduce(.saveCompleted(attempt: resolvedAttempt, version: local))
        _ = try resolvedSession.reduce(.edit(local: wrongVersion))
        _ = try resolvedSession.reduce(.edit(local: local))
        _ = try resolvedSession.reduce(.saveRequested)
        let beforeResolvedAttempt = resolvedSession
        #expect(throws: SaveSessionRefusal.staleCompletion) {
            try resolvedSession.reduce(.saveConfirmedAfterInterruption(
                attempt: resolvedAttempt, version: local
            ))
        }
        #expect(resolvedSession == beforeResolvedAttempt)
    }

    @Test func olderInterruptionConfirmationCannotSupersedeInFlightRetry() throws {
        let base = try Self.recoveryFaultVersion("older-confirm-base")
        let replacedLocal = try Self.recoveryFaultVersion("older-confirm-replaced")
        let local = try Self.recoveryFaultVersion("older-confirm-local")
        let laterLocal = try Self.recoveryFaultVersion("older-confirm-later")
        let fault = try SaveFault.make(category: .unknown)
        var session = SaveSession.make(initialVersion: base)
        _ = try session.reduce(.edit(local: replacedLocal))
        _ = try session.reduce(.edit(local: local))
        #expect(session.retainedCopies.count == 1)

        let first = try session.reduce(.saveRequested)
        guard case .beginWrite(_, let firstAttempt) = first.first else {
            Issue.record("Expected initial write")
            return
        }
        _ = try session.reduce(.saveFailed(attempt: firstAttempt, fault: fault))
        let retry = try session.reduce(.saveRequested)
        guard case .beginWrite(_, let retryAttempt) = retry.first else {
            Issue.record("Expected retry write")
            return
        }

        let beforeConfirmation = session
        #expect(throws: SaveSessionRefusal.newerAttemptInFlight) {
            try session.reduce(.saveConfirmedAfterInterruption(
                attempt: firstAttempt, version: local
            ))
        }
        #expect(session.state == beforeConfirmation.state)
        #expect(session.unresolvedAttempts == beforeConfirmation.unresolvedAttempts)
        #expect(session.retainedCopies == beforeConfirmation.retainedCopies)
        #expect(session == beforeConfirmation)

        let beforeEdit = session
        #expect(throws: SaveSessionRefusal.savePending) {
            try session.reduce(.edit(local: laterLocal))
        }
        #expect(session == beforeEdit)
        _ = try session.reduce(.saveCompleted(attempt: retryAttempt, version: local))
        #expect(session.state == .clean(version: local))

        var failedSession = SaveSession.make(initialVersion: base)
        _ = try failedSession.reduce(.edit(local: local))
        let earlier = try failedSession.reduce(.saveRequested)
        guard case .beginWrite(_, let earlierAttempt) = earlier.first else {
            Issue.record("Expected first failed-state attempt")
            return
        }
        _ = try failedSession.reduce(.saveFailed(attempt: earlierAttempt, fault: fault))
        let newer = try failedSession.reduce(.saveRequested)
        guard case .beginWrite(_, let newerAttempt) = newer.first else {
            Issue.record("Expected second failed-state attempt")
            return
        }
        _ = try failedSession.reduce(.saveFailed(attempt: newerAttempt, fault: fault))
        var confirmationEffects: [SaveEffect] = []
        #expect(throws: Never.self) {
            confirmationEffects = try failedSession.reduce(.saveConfirmedAfterInterruption(
                attempt: earlierAttempt, version: local
            ))
        }
        #expect(confirmationEffects.isEmpty)
        #expect(failedSession.state == .clean(version: local))
    }

    @Test func currentInterruptionConfirmationWhileSavingConfirms() throws {
        let base = try Self.recoveryFaultVersion("current-confirm-base")
        let local = try Self.recoveryFaultVersion("current-confirm-local")
        var session = SaveSession.make(initialVersion: base)
        _ = try session.reduce(.edit(local: local))
        let effects = try session.reduce(.saveRequested)
        guard case .beginWrite(_, let attempt) = effects.first else {
            Issue.record("Expected current write")
            return
        }

        var confirmationEffects: [SaveEffect] = []
        #expect(throws: Never.self) {
            confirmationEffects = try session.reduce(.saveConfirmedAfterInterruption(
                attempt: attempt, version: local
            ))
        }
        #expect(confirmationEffects.isEmpty)
        #expect(session.state == .clean(version: local))
        #expect(session.unresolvedAttempts.isEmpty)
    }

    @Test func aFaultedSaveStaysPendingUntilConfirmed() throws {
        let base = try Self.recoveryFaultVersion("pending-base")
        let local = try Self.recoveryFaultVersion("pending-local")
        let remote = try Self.recoveryFaultVersion("pending-remote")
        let fault = try SaveFault.make(category: .permissionDenied)
        var session = SaveSession.make(initialVersion: base)
        _ = try session.reduce(.edit(local: local))
        let effects = try session.reduce(.saveRequested)
        guard case .beginWrite(_, let attempt) = effects.first else {
            Issue.record("Expected save attempt")
            return
        }
        _ = try session.reduce(.saveFailed(attempt: attempt, fault: fault))

        for event in [
            SaveSessionEvent.edit(local: remote),
            .externalChange(remote: remote),
            .reload(version: remote)
        ] {
            let before = session
            #expect(throws: SaveSessionRefusal.savePending) { try session.reduce(event) }
            #expect(session == before)
        }
        _ = try session.reduce(.saveConfirmedAfterInterruption(attempt: attempt, version: local))
        #expect(session.state == .clean(version: local))
    }
}
