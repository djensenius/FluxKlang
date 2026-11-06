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
