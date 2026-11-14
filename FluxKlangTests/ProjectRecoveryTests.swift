import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

@Suite(.productionAccessAudit)
struct ProjectRecoveryTests {
    private static func version(_ digest: String) throws -> SaveContentVersion {
        try SaveContentVersion.make(digest: digest)
    }

    private static func fault(
        _ category: SaveFaultCategory = .unknown,
        detail: String? = nil
    ) throws -> SaveFault {
        try SaveFault.make(category: category, detail: detail)
    }

    private static func foreignAttempt() throws -> SaveAttemptID {
        let base = try version("foreign-base")
        let local = try version("foreign-local")
        var foreign = SaveSession.make(initialVersion: base)
        _ = try foreign.reduce(.edit(local: local))
        let first = try foreign.reduce(.saveRequested)
        guard case .beginWrite(_, let firstID) = first.first else {
            Issue.record("Expected first foreign attempt")
            throw SaveSessionRefusal.noPendingSave
        }
        _ = try foreign.reduce(.saveFailed(attempt: firstID, fault: Self.fault()))
        let retry = try foreign.reduce(.saveRequested)
        guard case .beginWrite(_, let retryID) = retry.first else {
            Issue.record("Expected retry foreign attempt")
            throw SaveSessionRefusal.noPendingSave
        }
        return retryID
    }

    @Test func versionDigestBoundsUseUTF8Bytes() throws {
        #expect(try Self.version(String(repeating: "a", count: 128)).digest.utf8.count == 128)
        #expect(throws: SaveSessionRefusal.invalidVersionDigestLength(129)) {
            try Self.version(String(repeating: "a", count: 129))
        }
        #expect(throws: SaveSessionRefusal.invalidVersionDigestLength(0)) {
            try Self.version("")
        }
        #expect(try Self.version("é").digest.utf8.count == 2)
        #expect(try Self.version("é") != Self.version("e\u{301}"))
        #expect(try Self.version(String(repeating: "é", count: 64)).digest.utf8.count == 128)
        #expect(throws: SaveSessionRefusal.invalidVersionDigestLength(130)) {
            try Self.version(String(repeating: "é", count: 65))
        }
    }

    @Test func editSaveFaultRetryAndInterruptedConfirmation() throws {
        let base = try Self.version("base")
        let local = try Self.version("local")
        var session = SaveSession.make(initialVersion: base)

        #expect(try session.reduce(.edit(local: local)).isEmpty)
        #expect(session.state == .dirty(base: base, local: local))

        let firstEffects = try session.reduce(.saveRequested)
        guard case .beginWrite(let firstVersion, let firstAttempt) = firstEffects.first else {
            Issue.record("Expected first write effect")
            return
        }
        #expect(firstVersion == local)
        let fault = try Self.fault(.diskFull, detail: "volume full")
        #expect(try session.reduce(.saveFailed(attempt: firstAttempt, fault: fault)) == [.reportFault(fault)])
        #expect(session.state == .failed(base: base, local: local, attempt: firstAttempt, fault: fault))
        #expect(session.unresolvedAttempts == [firstAttempt])

        let retryEffects = try session.reduce(.saveRequested)
        guard case .beginWrite(let retryVersion, let secondAttempt) = retryEffects.first else {
            Issue.record("Expected retry write effect")
            return
        }
        #expect(retryVersion == local)
        #expect(secondAttempt != firstAttempt)
        let beforeStale = session
        #expect(throws: SaveSessionRefusal.staleCompletion) {
            try session.reduce(.saveCompleted(attempt: firstAttempt, version: local))
        }
        #expect(session == beforeStale)

        #expect(throws: SaveSessionRefusal.newerAttemptInFlight) {
            try session.reduce(
                .saveConfirmedAfterInterruption(attempt: firstAttempt, version: local)
            )
        }
        #expect(session == beforeStale)

        #expect(try session.reduce(.saveFailed(attempt: secondAttempt, fault: fault)) == [.reportFault(fault)])
        #expect(try session.reduce(
            .saveConfirmedAfterInterruption(attempt: firstAttempt, version: local)
        ).isEmpty)
        #expect(session.state == .clean(version: local))
        #expect(session.unresolvedAttempts.isEmpty)
    }

    @Test func newerEditMovesPriorCopyReleaseConditionToLatestVersion() throws {
        let base = try Self.version("edit-base")
        let first = try Self.version("edit-one")
        let second = try Self.version("edit-two")
        let latest = try Self.version("edit-three")
        var session = SaveSession.make(initialVersion: base)
        _ = try session.reduce(.edit(local: first))
        _ = try session.reduce(.edit(local: second))
        #expect(try session.reduce(.edit(local: latest)) == [
            .retainCopy(role: .local, version: second, label: "edited-local-edit-two")
        ])
        #expect(session.retainedCopies.count == 2)
        #expect(session.retainedCopies.allSatisfy { $0.releaseAfter == latest })

        let begin = try session.reduce(.saveRequested)
        guard case .beginWrite(let savedVersion, let attempt) = begin.first else {
            Issue.record("Expected save of latest edit")
            return
        }
        #expect(savedVersion == latest)
        #expect(try session.reduce(.saveCompleted(attempt: attempt, version: latest)) == [
            .releaseCopy(role: .local, version: first, label: "edited-local-edit-one"),
            .releaseCopy(role: .local, version: second, label: "edited-local-edit-two")
        ])
        #expect(session.retainedCopies.isEmpty)
    }

    @Test func cleanStateDefinesNonDestructiveEventsAndRefusals() throws {
        let base = try Self.version("base")
        let remote = try Self.version("remote")
        let local = try Self.version("local")
        let fault = try Self.fault()
        var session = SaveSession.make(initialVersion: base)

        let staleAttempt = try Self.foreignAttempt()
        let refusedEvents: [(SaveSessionEvent, SaveSessionRefusal)] = [
            (.saveRequested, .noChangesToSave),
            (.saveCompleted(attempt: staleAttempt, version: base), .noPendingSave),
            (.saveFailed(attempt: staleAttempt, fault: fault), .noPendingSave),
            (.conflictResolved(choice: .keepLocal), .noConflictToResolve),
            (.saveConfirmedAfterInterruption(attempt: staleAttempt, version: base), .noPendingSave)
        ]
        #expect(try session.reduce(.edit(local: base)).isEmpty)
        #expect(session.state == .clean(version: base))
        for (event, refusal) in refusedEvents {
            let before = session
            #expect(throws: refusal) { try session.reduce(event) }
            #expect(session == before)
        }
        #expect(try session.reduce(.externalChange(remote: remote)).isEmpty)
        #expect(session.state == .clean(version: remote))
        #expect(try session.reduce(.reload(version: local)).isEmpty)
        #expect(session.state == .clean(version: local))
    }

    @Test func dirtyReloadAndConflictResolutionRefusalsPreserveState() throws {
        let base = try Self.version("base")
        let local = try Self.version("local")
        let remote = try Self.version("remote")
        let fault = try Self.fault()
        let staleAttempt = try Self.foreignAttempt()
        var session = SaveSession.make(initialVersion: base)
        _ = try session.reduce(.edit(local: local))

        for event in [
            SaveSessionEvent.reload(version: remote),
            .saveCompleted(attempt: staleAttempt, version: local),
            .saveFailed(attempt: staleAttempt, fault: fault),
            .saveConfirmedAfterInterruption(attempt: staleAttempt, version: local),
            .conflictResolved(choice: .keepRemote)
        ] {
            let before = session
            let expected: SaveSessionRefusal = event == .reload(version: remote)
                ? .reloadWouldDiscardLocal : event == .conflictResolved(choice: .keepRemote)
                    ? .noConflictToResolve : .noPendingSave
            #expect(throws: expected) { try session.reduce(event) }
            #expect(session == before)
        }
    }

}
