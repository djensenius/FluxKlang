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

    @Test func abandoningTheFailedAttemptFreesAFullAttemptListForARetry() throws {
        let base = try Self.recoveryFaultVersion("abandon-full-base")
        let earlier = try Self.recoveryFaultVersion("abandon-full-earlier")
        let local = try Self.recoveryFaultVersion("abandon-full-local")
        let fault = try SaveFault.make(category: .diskFull)
        var session = SaveSession.make(initialVersion: base)
        _ = try session.reduce(.edit(local: earlier))
        _ = try session.reduce(.edit(local: local))
        var last: SaveAttemptID?
        for _ in 1...SaveSession.maximumUnresolvedAttempts {
            let attempt = try Self.abandonStartAttempt(&session)
            _ = try session.reduce(.saveFailed(attempt: attempt, fault: fault))
            last = attempt
        }
        let current = try #require(last)
        try Self.abandonRefuses(&session, .saveRequested, .attemptLimitExceeded)
        let copiesBefore = session.retainedCopies
        #expect(copiesBefore.count == 1)
        let effects = try session.reduce(.saveAbandoned(attempt: current))
        #expect(effects.isEmpty)
        #expect(session.state == .dirty(base: base, local: local))
        #expect(session.unresolvedAttempts.isEmpty)
        #expect(session.retainedCopies == copiesBefore)
        let retry = try session.reduce(.saveRequested)
        guard case .beginWrite(let version, let retryAttempt) = retry.first else {
            Issue.record("Expected a fresh write after the abandon")
            return
        }
        #expect(version == local)
        #expect(retryAttempt.rawValue == 9)
        #expect(session.unresolvedAttempts.count == 1)
        _ = try session.reduce(.saveCompleted(attempt: retryAttempt, version: local))
        #expect(session.state == .clean(version: local))
    }

    @Test func abandonIsRefusedOutsideTheCurrentFailedAttemptAndLeavesTheSessionUnchanged() throws {
        for row in try Self.abandonRefusalRows() {
            var session = row.session
            let before = session
            #expect(throws: row.refusal, Comment(rawValue: row.name)) {
                try session.reduce(.saveAbandoned(attempt: row.attempt))
            }
            #expect(session == before, Comment(rawValue: row.name))
        }
    }

    @Test func confirmingAnAbandonedAttemptIsStaleAndALandedWriteConvergesByExternalChange() throws {
        let base = try Self.recoveryFaultVersion("abandon-confirm-base")
        let earlier = try Self.recoveryFaultVersion("abandon-confirm-earlier")
        let local = try Self.recoveryFaultVersion("abandon-confirm-local")
        let fault = try SaveFault.make(category: .permissionDenied)
        var session = SaveSession.make(initialVersion: base)
        _ = try session.reduce(.edit(local: local))
        let abandoned = try Self.abandonStartAttempt(&session)
        _ = try session.reduce(.saveFailed(attempt: abandoned, fault: fault))
        _ = try session.reduce(.saveAbandoned(attempt: abandoned))
        let confirm = SaveSessionEvent.saveConfirmedAfterInterruption(attempt: abandoned, version: local)
        try Self.abandonRefuses(&session, confirm, .noPendingSave)
        let retry = try Self.abandonStartAttempt(&session)
        try Self.abandonRefuses(&session, confirm, .staleCompletion)
        try Self.abandonRefuses(&session, .saveCompleted(attempt: abandoned, version: local), .staleCompletion)
        _ = try session.reduce(.saveCompleted(attempt: retry, version: local))
        #expect(session.state == .clean(version: local))
        var landed = SaveSession.make(initialVersion: base)
        _ = try landed.reduce(.edit(local: earlier))
        _ = try landed.reduce(.edit(local: local))
        #expect(landed.retainedCopies.count == 1)
        let landedAttempt = try Self.abandonStartAttempt(&landed)
        _ = try landed.reduce(.saveFailed(attempt: landedAttempt, fault: fault))
        _ = try landed.reduce(.saveAbandoned(attempt: landedAttempt))
        let releases = try landed.reduce(.externalChange(remote: local))
        #expect(landed.state == .clean(version: local))
        #expect(releases.count == 1)
        #expect(landed.retainedCopies.isEmpty)
        #expect(landed.unresolvedAttempts.isEmpty)
    }

    @Test func afterAbandoningTheDocumentIsEditableNotReloadableAndConflictsWithAnotherRemote() throws {
        let base = try Self.recoveryFaultVersion("abandon-after-base")
        let local = try Self.recoveryFaultVersion("abandon-after-local")
        let next = try Self.recoveryFaultVersion("abandon-after-next")
        let other = try Self.recoveryFaultVersion("abandon-after-other")
        let fault = try SaveFault.make(category: .coordinationDenied)
        var editable = SaveSession.make(initialVersion: base)
        _ = try editable.reduce(.edit(local: local))
        let editableAttempt = try Self.abandonStartAttempt(&editable)
        _ = try editable.reduce(.saveFailed(attempt: editableAttempt, fault: fault))
        try Self.abandonRefuses(&editable, .edit(local: next), .savePending)
        _ = try editable.reduce(.saveAbandoned(attempt: editableAttempt))
        _ = try editable.reduce(.edit(local: next))
        #expect(editable.state == .dirty(base: base, local: next))
        #expect(editable.retainedCopies.count == 1)
        try Self.abandonRefuses(&editable, .reload(version: other), .reloadWouldDiscardLocal)
        var conflicting = SaveSession.make(initialVersion: base)
        _ = try conflicting.reduce(.edit(local: local))
        let conflictAttempt = try Self.abandonStartAttempt(&conflicting)
        _ = try conflicting.reduce(.saveFailed(attempt: conflictAttempt, fault: fault))
        try Self.abandonRefuses(&conflicting, .externalChange(remote: other), .savePending)
        _ = try conflicting.reduce(.saveAbandoned(attempt: conflictAttempt))
        let effects = try conflicting.reduce(.externalChange(remote: other))
        #expect(conflicting.state == .conflicted(base: base, local: local, remote: other))
        #expect(conflicting.retainedCopies.count == 2)
        let lastEffect = try #require(effects.last)
        #expect(lastEffect == .presentConflict(base: base, local: local, remote: other))
    }
}

private struct AbandonRefusalRow {
    let name: String
    let session: SaveSession
    let attempt: SaveAttemptID
    let refusal: SaveSessionRefusal
}

extension ProjectRecoveryTests {
    fileprivate static func abandonRefuses(
        _ session: inout SaveSession,
        _ event: SaveSessionEvent,
        _ refusal: SaveSessionRefusal
    ) throws {
        let before = session
        #expect(throws: refusal) { try session.reduce(event) }
        #expect(session == before)
    }

    fileprivate static func abandonStartAttempt(_ session: inout SaveSession) throws -> SaveAttemptID {
        let effects = try session.reduce(.saveRequested)
        guard case .beginWrite(_, let attempt) = effects.first else {
            Issue.record("Expected a write attempt")
            throw SaveSessionRefusal.noPendingSave
        }
        return attempt
    }

    fileprivate static func abandonRefusalRows() throws -> [AbandonRefusalRow] {
        let base = try recoveryFaultVersion("abandon-rows-base")
        let local = try recoveryFaultVersion("abandon-rows-local")
        let remote = try recoveryFaultVersion("abandon-rows-remote")
        let fault = try SaveFault.make(category: .unknown)
        let foreign = try thirdAttemptID()
        let clean = SaveSession.make(initialVersion: base)
        var dirty = clean
        _ = try dirty.reduce(.edit(local: local))
        var conflicted = dirty
        _ = try conflicted.reduce(.externalChange(remote: remote))
        var saving = dirty
        let savingAttempt = try abandonStartAttempt(&saving)
        var failed = dirty
        let olderAttempt = try abandonStartAttempt(&failed)
        _ = try failed.reduce(.saveFailed(attempt: olderAttempt, fault: fault))
        let currentAttempt = try abandonStartAttempt(&failed)
        _ = try failed.reduce(.saveFailed(attempt: currentAttempt, fault: fault))
        var repeated = failed
        _ = try repeated.reduce(.saveAbandoned(attempt: currentAttempt))
        return [
            AbandonRefusalRow(name: "clean", session: clean, attempt: foreign, refusal: .noPendingSave),
            AbandonRefusalRow(name: "dirty", session: dirty, attempt: foreign, refusal: .noPendingSave),
            AbandonRefusalRow(name: "conflicted", session: conflicted, attempt: foreign, refusal: .noPendingSave),
            AbandonRefusalRow(name: "saving", session: saving, attempt: savingAttempt, refusal: .savePending),
            AbandonRefusalRow(name: "older id", session: failed, attempt: olderAttempt, refusal: .staleCompletion),
            AbandonRefusalRow(name: "foreign id", session: failed, attempt: foreign, refusal: .staleCompletion),
            AbandonRefusalRow(name: "repeated", session: repeated, attempt: currentAttempt, refusal: .noPendingSave)
        ]
    }
}
