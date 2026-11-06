import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension ProjectRecoveryTests {
    private struct ConflictedSession {
        let session: SaveSession
        let base: SaveContentVersion
        let local: SaveContentVersion
        let remote: SaveContentVersion
    }

    private struct CopySnapshot: Equatable {
        let role: SaveCopyRole
        let version: SaveContentVersion
        let label: String
        let releaseAfter: SaveContentVersion?
        let pinned: Bool
    }

    private static func recoveryConflictVersion(_ value: String) throws -> SaveContentVersion {
        try SaveContentVersion.make(digest: value)
    }

    private static func conflictedSession() throws -> ConflictedSession {
        let base = try recoveryConflictVersion("conflict-base")
        let local = try recoveryConflictVersion("conflict-local")
        let remote = try recoveryConflictVersion("conflict-remote")
        var session = SaveSession.make(initialVersion: base)
        _ = try session.reduce(.edit(local: local))
        let effects = try session.reduce(.externalChange(remote: remote))
        #expect(effects == [
            .retainCopy(role: .local, version: local, label: "conflict-local-conflict-local"),
            .retainCopy(role: .remote, version: remote, label: "conflict-remote-conflict-remote"),
            .presentConflict(base: base, local: local, remote: remote)
        ])
        return ConflictedSession(session: session, base: base, local: local, remote: remote)
    }

    private static func copySnapshots(_ session: SaveSession) -> [CopySnapshot] {
        session.retainedCopies.map {
            CopySnapshot(
                role: $0.role,
                version: $0.version,
                label: $0.label,
                releaseAfter: $0.releaseAfter,
                pinned: $0.pinned
            )
        }
    }

    private static func seededDirtyEvent(_ word: UInt64, _ selected: SaveContentVersion) -> SaveSessionEvent {
        switch word % 3 {
        case 0: return .externalChange(remote: selected)
        case 1: return .saveRequested
        default: return .edit(local: selected)
        }
    }

    private static func seededConflictEvent(
        _ word: UInt64,
        _ selected: SaveContentVersion
    ) -> SaveSessionEvent {
        switch word % 4 {
        case 0: return .externalChange(remote: selected)
        case 1: return .conflictResolved(choice: .keepLocal)
        case 2: return .conflictResolved(choice: .keepRemote)
        default: return .conflictResolved(choice: .keepBoth)
        }
    }

    private static func seededFailedEvent(
        _ word: UInt64,
        _ local: SaveContentVersion,
        _ attempt: SaveAttemptID,
        _ attempts: [SaveAttemptID],
        _ fault: SaveFault
    ) -> SaveSessionEvent {
        switch word % 3 {
        case 0: return .saveRequested
        case 1: return .saveFailed(attempt: attempt, fault: fault)
        default:
            return .saveConfirmedAfterInterruption(
                attempt: attempts.first ?? attempt,
                version: local
            )
        }
    }

    private static func seededEvent(
        _ state: SaveSessionState,
        _ word: UInt64,
        _ selected: SaveContentVersion,
        _ attempts: [SaveAttemptID],
        _ fault: SaveFault
    ) -> SaveSessionEvent {
        switch state {
        case .clean:
            return word % 3 == 0
                ? .externalChange(remote: selected) : .edit(local: selected)
        case .dirty:
            return seededDirtyEvent(word, selected)
        case .conflicted:
            return seededConflictEvent(word, selected)
        case .saving(_, let local, let attempt):
            return word % 2 == 0
                ? .saveCompleted(attempt: attempt, version: local)
                : .saveFailed(attempt: attempt, fault: fault)
        case .failed(_, let local, let attempt, _):
            return seededFailedEvent(word, local, attempt, attempts, fault)
        }
    }

    @Test func conflictRequiresExplicitChoiceAndCopiesSurviveRepeatedChanges() throws {
        let fixture = try Self.conflictedSession()
        var session = fixture.session
        let base = fixture.base
        let local = fixture.local
        let remote = fixture.remote
        #expect(session.state == .conflicted(base: base, local: local, remote: remote))
        #expect(session.retainedCopies.count == 2)

        let next = try Self.recoveryConflictVersion("conflict-next")
        let beforeResolution = session
        #expect(throws: SaveSessionRefusal.unresolvedConflict) {
            try session.reduce(.saveRequested)
        }
        #expect(session == beforeResolution)
        let effects = try session.reduce(.externalChange(remote: next))
        #expect(effects == [
            .retainCopy(role: .remote, version: next, label: "conflict-remote-conflict-next"),
            .presentConflict(base: base, local: local, remote: next)
        ])
        #expect(session.state == .conflicted(base: base, local: local, remote: next))
        #expect(session.retainedCopies.contains { $0.version == remote && $0.role == .remote })
        #expect(session.retainedCopies.contains { $0.version == next && $0.role == .remote })
    }

    @Test func sameRemoteWhileConflictedIsAnAtomicNoop() throws {
        let fixture = try Self.conflictedSession()
        var session = fixture.session
        let before = session
        #expect(try session.reduce(.externalChange(remote: fixture.remote)).isEmpty)
        #expect(session == before)
    }

    @Test func editBackToBaseRemainsDirtyWithEqualVersions() throws {
        let base = try Self.recoveryConflictVersion("edge-base")
        let local = try Self.recoveryConflictVersion("edge-local")
        var session = SaveSession.make(initialVersion: base)
        _ = try session.reduce(.edit(local: local))
        #expect(try session.reduce(.edit(local: base)) == [
            .retainCopy(role: .local, version: local, label: "edited-local-edge-local")
        ])
        #expect(session.state == .dirty(base: base, local: base))
    }

    @Test func conflictedExternalMatchingBaseOrLocalRemainsConflicted() throws {
        let fixture = try Self.conflictedSession()
        var session = fixture.session
        let baseEffect = try session.reduce(.externalChange(remote: fixture.base))
        #expect(baseEffect == [
            .retainCopy(
                role: .remote,
                version: fixture.base,
                label: "conflict-remote-conflict-base"
            ),
            .presentConflict(base: fixture.base, local: fixture.local, remote: fixture.base)
        ])
        #expect(session.state == .conflicted(
            base: fixture.base, local: fixture.local, remote: fixture.base
        ))

        let localEffect = try session.reduce(.externalChange(remote: fixture.local))
        #expect(localEffect == [
            .retainCopy(
                role: .remote,
                version: fixture.local,
                label: "conflict-remote-conflict-local"
            ),
            .presentConflict(base: fixture.base, local: fixture.local, remote: fixture.local)
        ])
        #expect(session.state == .conflicted(
            base: fixture.base, local: fixture.local, remote: fixture.local
        ))
    }

    @Test func dirtyExternalChangeEqualToBaseIsIgnoredAndEqualToLocalConfirmsIt() throws {
        let base = try Self.recoveryConflictVersion("equal-base")
        let local = try Self.recoveryConflictVersion("equal-local")
        var session = SaveSession.make(initialVersion: base)
        _ = try session.reduce(.edit(local: local))

        #expect(try session.reduce(.externalChange(remote: base)).isEmpty)
        #expect(session.state == .dirty(base: base, local: local))
        #expect(try session.reduce(.externalChange(remote: local)).isEmpty)
        #expect(session.state == .clean(version: local))
    }

    @Test func explicitConflictChoicesKeepRemoteOrRetainItWithoutOverwrite() throws {
        let keepLocalFixture = try Self.conflictedSession()
        var keepLocalSession = keepLocalFixture.session
        #expect(try keepLocalSession.reduce(.conflictResolved(choice: .keepLocal)) == [
            .conflictResolutionApplied(choice: .keepLocal, requiresReview: true)
        ])
        #expect(keepLocalSession.state == .dirty(
            base: keepLocalFixture.remote, local: keepLocalFixture.local
        ))
        #expect(Self.copySnapshots(keepLocalSession) == [
            CopySnapshot(
                role: .local,
                version: keepLocalFixture.local,
                label: "conflict-local-conflict-local",
                releaseAfter: keepLocalFixture.local,
                pinned: false
            ),
            CopySnapshot(
                role: .remote,
                version: keepLocalFixture.remote,
                label: "conflict-remote-conflict-remote",
                releaseAfter: keepLocalFixture.local,
                pinned: false
            )
        ])

        let keepRemoteFixture = try Self.conflictedSession()
        var keepRemoteSession = keepRemoteFixture.session
        #expect(try keepRemoteSession.reduce(.conflictResolved(choice: .keepRemote)) == [
            .conflictResolutionApplied(choice: .keepRemote, requiresReview: true),
            .releaseCopy(
                role: .local,
                version: keepRemoteFixture.local,
                label: "conflict-local-conflict-local"
            ),
            .releaseCopy(
                role: .remote,
                version: keepRemoteFixture.remote,
                label: "conflict-remote-conflict-remote"
            )
        ])
        #expect(keepRemoteSession.state == .clean(version: keepRemoteFixture.remote))
        #expect(Self.copySnapshots(keepRemoteSession).isEmpty)

        let keepBothFixture = try Self.conflictedSession()
        var keepBothSession = keepBothFixture.session
        #expect(try keepBothSession.reduce(.conflictResolved(choice: .keepBoth)) == [
            .retainCopy(
                role: .remote,
                version: keepBothFixture.remote,
                label: "keep-both-remote-conflict-remote"
            ),
            .conflictResolutionApplied(choice: .keepBoth, requiresReview: true),
            .releaseCopy(
                role: .remote,
                version: keepBothFixture.remote,
                label: "conflict-remote-conflict-remote"
            )
        ])
        #expect(keepBothSession.state == .dirty(
            base: keepBothFixture.remote, local: keepBothFixture.local
        ))
        #expect(Self.copySnapshots(keepBothSession) == [
            CopySnapshot(
                role: .local,
                version: keepBothFixture.local,
                label: "conflict-local-conflict-local",
                releaseAfter: keepBothFixture.local,
                pinned: false
            ),
            CopySnapshot(
                role: .remote,
                version: keepBothFixture.remote,
                label: "keep-both-remote-conflict-remote",
                releaseAfter: nil,
                pinned: true
            )
        ])
    }

    @Test func keepBothCopyRemainsPinnedAfterLocalSave() throws {
        let fixture = try Self.conflictedSession()
        var session = fixture.session
        let local = fixture.local
        let remote = fixture.remote
        _ = try session.reduce(.conflictResolved(choice: .keepBoth))
        let begin = try session.reduce(.saveRequested)
        guard case .beginWrite(let version, let attempt) = begin.first else {
            Issue.record("Expected save of the selected local version")
            return
        }
        #expect(version == local)
        let completion = try session.reduce(.saveCompleted(attempt: attempt, version: local))
        #expect(session.state == .clean(version: local))
        #expect(completion == [
            .releaseCopy(role: .local, version: local, label: "conflict-local-conflict-local")
        ])
        #expect(session.retainedCopies.contains {
            $0.role == .remote && $0.version == remote && $0.pinned
        })
    }

    @Test func keepLocalReleasesTheRemoteCopyOnlyAfterSaveConfirmation() throws {
        let fixture = try Self.conflictedSession()
        var session = fixture.session
        let local = fixture.local
        let remote = fixture.remote
        _ = try session.reduce(.conflictResolved(choice: .keepLocal))
        #expect(session.retainedCopies.contains {
            $0.role == .remote && $0.version == remote && $0.releaseAfter == local
        })
        let begin = try session.reduce(.saveRequested)
        guard case .beginWrite(_, let attempt) = begin.first else {
            Issue.record("Expected save of selected local version")
            return
        }
        #expect(session.retainedCopies.contains { $0.version == remote })
        let completion = try session.reduce(.saveCompleted(attempt: attempt, version: local))
        #expect(completion == [
            .releaseCopy(role: .local, version: local, label: "conflict-local-conflict-local"),
            .releaseCopy(role: .remote, version: remote, label: "conflict-remote-conflict-remote")
        ])
        #expect(session.retainedCopies.isEmpty)
    }

    @Test func retainedCopyCapAcceptsEightAndRefusesTenthEventAtomically() throws {
        let base = try Self.recoveryConflictVersion("cap-base")
        var conflictSession = SaveSession.make(initialVersion: base)
        var conflictLocal = base
        for ordinal in 1...8 {
            conflictLocal = try Self.recoveryConflictVersion("conflict-cap-local-\(ordinal)")
            _ = try conflictSession.reduce(.edit(local: conflictLocal))
        }
        #expect(conflictSession.retainedCopies.count == 7)
        let beforeConflict = conflictSession
        let conflictRemote = try Self.recoveryConflictVersion("conflict-cap-remote")
        #expect(throws: SaveSessionRefusal.retainedCopyLimitExceeded) {
            try conflictSession.reduce(.externalChange(remote: conflictRemote))
        }
        #expect(conflictSession == beforeConflict)

        var session = SaveSession.make(initialVersion: base)
        var local = base
        for ordinal in 1...9 {
            local = try Self.recoveryConflictVersion("cap-local-\(ordinal)")
            _ = try session.reduce(.edit(local: local))
            #expect(session.retainedCopies.count == ordinal - 1)
        }
        #expect(session.retainedCopies.count == 8)

        let tenthLocal = try Self.recoveryConflictVersion("cap-local-10")
        let beforeTenthEvent = session
        #expect(throws: SaveSessionRefusal.retainedCopyLimitExceeded) {
            try session.reduce(.edit(local: tenthLocal))
        }
        #expect(session == beforeTenthEvent)

        let remote = try Self.recoveryConflictVersion("cap-remote")
        let before = session
        #expect(throws: SaveSessionRefusal.retainedCopyLimitExceeded) {
            try session.reduce(.externalChange(remote: remote))
        }
        #expect(session == before)
    }

    @Test func seededEventSequencesPreserveRetainedVersionsAndBounds() throws {
        let versions = try (0..<8).map { try Self.recoveryConflictVersion("seed-\($0)") }
        let fault = try SaveFault.make(category: .coordinationDenied)
        var session = SaveSession.make(initialVersion: versions[0])
        var generator = ProjectRecoverySeed(state: 0x9E37_79B9_7F4A_7C15)
        var observedKinds: Set<String> = [session.state.seededKind]
        var conflictedStateSteps = 0

        _ = try session.reduce(.edit(local: versions[1]))
        observedKinds.insert(session.state.seededKind)
        let firstEffects = try session.reduce(.saveRequested)
        guard case .beginWrite(_, let firstAttempt) = firstEffects.first else {
            Issue.record("Expected first seeded attempt")
            return
        }
        observedKinds.insert(session.state.seededKind)
        let beforeSavingRefusal = session
        #expect(throws: SaveSessionRefusal.savePending) {
            try session.reduce(.externalChange(remote: versions[2]))
        }
        #expect(session == beforeSavingRefusal)
        observedKinds.insert(session.state.seededKind)

        _ = try session.reduce(.saveFailed(attempt: firstAttempt, fault: fault))
        observedKinds.insert(session.state.seededKind)
        let retryEffects = try session.reduce(.saveRequested)
        guard case .beginWrite(_, let retryAttempt) = retryEffects.first else {
            Issue.record("Expected seeded retry")
            return
        }
        observedKinds.insert(session.state.seededKind)
        let beforeStaleCompletion = session
        #expect(throws: SaveSessionRefusal.staleCompletion) {
            try session.reduce(.saveCompleted(attempt: firstAttempt, version: versions[1]))
        }
        #expect(session == beforeStaleCompletion)
        observedKinds.insert(session.state.seededKind)

        _ = try session.reduce(.saveCompleted(attempt: retryAttempt, version: versions[1]))
        observedKinds.insert(session.state.seededKind)
        let beforeCleanSave = session
        #expect(throws: SaveSessionRefusal.noChangesToSave) {
            try session.reduce(.saveRequested)
        }
        #expect(session == beforeCleanSave)
        observedKinds.insert(session.state.seededKind)
        _ = try session.reduce(.edit(local: versions[4]))
        observedKinds.insert(session.state.seededKind)
        _ = try session.reduce(.externalChange(remote: versions[5]))
        observedKinds.insert(session.state.seededKind)

        for _ in 0..<160 {
            let versionWord = generator.next()
            let eventWord = generator.next()
            let selected = versions[Int(versionWord % UInt64(versions.count))]
            let event = Self.seededEvent(
                session.state, eventWord, selected, session.unresolvedAttempts, fault
            )
            _ = try session.reduce(event)
            observedKinds.insert(session.state.seededKind)
            #expect(session.retainedCopies.count <= SaveSession.maximumRetainedCopies)
            #expect(session.unresolvedAttempts.count <= SaveSession.maximumUnresolvedAttempts)
            let uniqueKeys = Set(session.retainedCopies.map {
                "\($0.role.rawValue):\($0.version.digest):\($0.label)"
            })
            #expect(uniqueKeys.count == session.retainedCopies.count)
            if case .conflicted(_, let activeLocal, let activeRemote) = session.state {
                conflictedStateSteps += 1
                #expect(session.retainedCopies.contains {
                    $0.role == .local && $0.version == activeLocal
                })
                #expect(session.retainedCopies.contains {
                    $0.role == .remote && $0.version == activeRemote
                })
            }
            if case .clean = session.state {
                #expect(session.retainedCopies.allSatisfy { $0.pinned })
            }
        }
        #expect(observedKinds == Set(["clean", "dirty", "conflicted", "saving", "failed"]))
        #expect(conflictedStateSteps > 0)
    }
}

private extension SaveSessionState {
    var seededKind: String {
        switch self {
        case .clean: return "clean"
        case .dirty: return "dirty"
        case .conflicted: return "conflicted"
        case .saving: return "saving"
        case .failed: return "failed"
        }
    }
}

private struct ProjectRecoverySeed {
    private var state: UInt64

    init(state: UInt64) {
        self.state = state
    }

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state >> 33
    }
}
