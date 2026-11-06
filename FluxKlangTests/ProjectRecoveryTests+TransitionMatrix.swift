import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension ProjectRecoveryTests {
    private enum MatrixState: Int, CaseIterable, Equatable {
        case clean
        case dirty
        case saving
        case conflicted
        case failed
    }

    private enum MatrixEvent: Int, CaseIterable, Equatable {
        case edit
        case saveRequested
        case saveCompleted
        case saveFailed
        case externalChange
        case conflictResolved
        case saveConfirmed
        case reload
    }

    private struct MatrixAcceptedResult: Equatable {
        let state: SaveSessionState
        let effects: [SaveEffect]
        let retainedCopies: [MatrixRetainedCopy]
        let unresolvedAttempts: [SaveAttemptID]

        init(
            state: SaveSessionState,
            effects: [SaveEffect],
            retainedCopies: [MatrixRetainedCopy] = [],
            unresolvedAttempts: [SaveAttemptID] = []
        ) {
            self.state = state
            self.effects = effects
            self.retainedCopies = retainedCopies
            self.unresolvedAttempts = unresolvedAttempts
        }
    }

    private struct MatrixRetainedCopy: Equatable {
        let role: SaveCopyRole
        let version: SaveContentVersion
        let label: String
        let releaseAfter: SaveContentVersion?
        let pinned: Bool
    }

    private struct MatrixExpectation {
        let state: MatrixState
        let event: MatrixEvent
        let result: MatrixAcceptedResult
    }

    private struct MatrixValues {
        let base: SaveContentVersion
        let local: SaveContentVersion
        let edited: SaveContentVersion
        let remote: SaveContentVersion
        let nextRemote: SaveContentVersion
        let fault: SaveFault
        let firstAttempt: SaveAttemptID
        let retryAttempt: SaveAttemptID
    }

    private static let matrixRefusals: [[SaveSessionRefusal?]] = [
        [nil, .noChangesToSave, .noPendingSave, .noPendingSave, nil, .noConflictToResolve, .noPendingSave, nil],
        [nil, nil, .noPendingSave, .noPendingSave, nil, .noConflictToResolve, .noPendingSave,
         .reloadWouldDiscardLocal],
        [.savePending, .saveAlreadyPending, nil, nil, .savePending, .savePending, nil, .savePending],
        [.unresolvedConflict, .unresolvedConflict, .noPendingSave, .noPendingSave, nil, nil, .noPendingSave,
         .reloadWouldDiscardLocal],
        [.savePending, nil, nil, nil, .savePending, .savePending, nil, .savePending]
    ]

    private static func matrixVersion(_ digest: String) throws -> SaveContentVersion {
        try SaveContentVersion.make(digest: digest)
    }

    private static func matrixFault(_ detail: String) throws -> SaveFault {
        try SaveFault.make(category: .unknown, detail: detail)
    }

    private static func matrixForeignAttempt() throws -> SaveAttemptID {
        let base = try matrixVersion("foreign-base")
        let local = try matrixVersion("foreign-local")
        var foreign = SaveSession.make(initialVersion: base)
        _ = try foreign.reduce(.edit(local: local))
        let first = try foreign.reduce(.saveRequested)
        guard case .beginWrite(_, let firstID) = first.first else {
            Issue.record("Expected first foreign attempt")
            throw SaveSessionRefusal.noPendingSave
        }
        _ = try foreign.reduce(.saveFailed(attempt: firstID, fault: matrixFault("matrix")))
        let retry = try foreign.reduce(.saveRequested)
        guard case .beginWrite(_, let retryID) = retry.first else {
            Issue.record("Expected retry foreign attempt")
            throw SaveSessionRefusal.noPendingSave
        }
        return retryID
    }

    private static func matrixFixture(
        _ target: MatrixState
    ) throws -> (session: SaveSession, attempt: SaveAttemptID?) {
        let base = try matrixVersion("matrix-base")
        let local = try matrixVersion("matrix-local")
        let fault = try matrixFault("matrix")
        var session = SaveSession.make(initialVersion: base)
        var attempt: SaveAttemptID?
        if target != .clean {
            _ = try session.reduce(.edit(local: local))
        }
        switch target {
        case .clean, .dirty:
            break
        case .saving, .failed:
            let effects = try session.reduce(.saveRequested)
            guard case .beginWrite(_, let current) = effects.first else {
                throw SaveSessionRefusal.noPendingSave
            }
            attempt = current
            if target == .failed {
                _ = try session.reduce(.saveFailed(attempt: current, fault: fault))
            }
        case .conflicted:
            _ = try session.reduce(.externalChange(remote: matrixVersion("matrix-remote")))
        }
        return (session, attempt)
    }

    private static func matrixEvent(
        _ kind: MatrixEvent,
        state: MatrixState,
        attempt: SaveAttemptID,
        values: MatrixValues
    ) -> SaveSessionEvent {
        switch kind {
        case .edit: return .edit(local: values.edited)
        case .saveRequested: return .saveRequested
        case .saveCompleted: return .saveCompleted(attempt: attempt, version: values.local)
        case .saveFailed: return .saveFailed(attempt: attempt, fault: values.fault)
        case .externalChange:
            let incoming = state == .conflicted ? values.nextRemote : values.remote
            return .externalChange(remote: incoming)
        case .conflictResolved: return .conflictResolved(choice: .keepLocal)
        case .saveConfirmed:
            return .saveConfirmedAfterInterruption(attempt: attempt, version: values.local)
        case .reload: return .reload(version: values.remote)
        }
    }

    private static func matrixCleanDirtyResults(_ values: MatrixValues) -> [MatrixExpectation] {
        [
            MatrixExpectation(
                state: .clean,
                event: .edit,
                result: MatrixAcceptedResult(
                    state: .dirty(base: values.base, local: values.edited), effects: []
                )
            ),
            MatrixExpectation(
                state: .clean,
                event: .externalChange,
                result: MatrixAcceptedResult(state: .clean(version: values.remote), effects: [])
            ),
            MatrixExpectation(
                state: .clean,
                event: .reload,
                result: MatrixAcceptedResult(state: .clean(version: values.remote), effects: [])
            ),
            MatrixExpectation(
                state: .dirty,
                event: .edit,
                result: MatrixAcceptedResult(
                    state: .dirty(base: values.base, local: values.edited),
                    effects: [.retainCopy(
                        role: .local, version: values.local, label: "edited-local-matrix-local"
                    )],
                    retainedCopies: [MatrixRetainedCopy(
                        role: .local,
                        version: values.local,
                        label: "edited-local-matrix-local",
                        releaseAfter: values.edited,
                        pinned: false
                    )]
                )
            ),
            MatrixExpectation(
                state: .dirty,
                event: .saveRequested,
                result: MatrixAcceptedResult(
                    state: .saving(
                        base: values.base, local: values.local, attempt: values.firstAttempt
                    ),
                    effects: [.beginWrite(version: values.local, attempt: values.firstAttempt)],
                    unresolvedAttempts: [values.firstAttempt]
                )
            ),
            MatrixExpectation(
                state: .dirty,
                event: .externalChange,
                result: MatrixAcceptedResult(
                    state: .conflicted(base: values.base, local: values.local, remote: values.remote),
                    effects: [
                        .retainCopy(
                            role: .local, version: values.local, label: "conflict-local-matrix-local"
                        ),
                        .retainCopy(
                            role: .remote, version: values.remote, label: "conflict-remote-matrix-remote"
                        ),
                        .presentConflict(base: values.base, local: values.local, remote: values.remote)
                    ],
                    retainedCopies: [
                        MatrixRetainedCopy(
                            role: .local,
                            version: values.local,
                            label: "conflict-local-matrix-local",
                            releaseAfter: nil,
                            pinned: false
                        ),
                        MatrixRetainedCopy(
                            role: .remote,
                            version: values.remote,
                            label: "conflict-remote-matrix-remote",
                            releaseAfter: nil,
                            pinned: false
                        )
                    ]
                )
            )
        ]
    }

    private static func matrixSavingResults(_ values: MatrixValues) -> [MatrixExpectation] {
        [
            MatrixExpectation(
                state: .saving,
                event: .saveCompleted,
                result: MatrixAcceptedResult(state: .clean(version: values.local), effects: [])
            ),
            MatrixExpectation(
                state: .saving,
                event: .saveFailed,
                result: MatrixAcceptedResult(
                    state: .failed(
                        base: values.base,
                        local: values.local,
                        attempt: values.firstAttempt,
                        fault: values.fault
                    ),
                    effects: [.reportFault(values.fault)],
                    unresolvedAttempts: [values.firstAttempt]
                )
            ),
            MatrixExpectation(
                state: .saving,
                event: .saveConfirmed,
                result: MatrixAcceptedResult(state: .clean(version: values.local), effects: [])
            )
        ]
    }

    private static func matrixConflictResults(_ values: MatrixValues) -> [MatrixExpectation] {
        [
            MatrixExpectation(
                state: .conflicted,
                event: .externalChange,
                result: MatrixAcceptedResult(
                    state: .conflicted(
                        base: values.base, local: values.local, remote: values.nextRemote
                    ),
                    effects: [
                        .retainCopy(
                            role: .remote,
                            version: values.nextRemote,
                            label: "conflict-remote-matrix-next-remote"
                        ),
                        .presentConflict(
                            base: values.base, local: values.local, remote: values.nextRemote
                        )
                    ],
                    retainedCopies: [
                        MatrixRetainedCopy(
                            role: .local,
                            version: values.local,
                            label: "conflict-local-matrix-local",
                            releaseAfter: nil,
                            pinned: false
                        ),
                        MatrixRetainedCopy(
                            role: .remote,
                            version: values.remote,
                            label: "conflict-remote-matrix-remote",
                            releaseAfter: nil,
                            pinned: false
                        ),
                        MatrixRetainedCopy(
                            role: .remote,
                            version: values.nextRemote,
                            label: "conflict-remote-matrix-next-remote",
                            releaseAfter: nil,
                            pinned: false
                        )
                    ]
                )
            ),
            MatrixExpectation(
                state: .conflicted,
                event: .conflictResolved,
                result: MatrixAcceptedResult(
                    state: .dirty(base: values.remote, local: values.local),
                    effects: [.conflictResolutionApplied(choice: .keepLocal, requiresReview: true)],
                    retainedCopies: [
                        MatrixRetainedCopy(
                            role: .local,
                            version: values.local,
                            label: "conflict-local-matrix-local",
                            releaseAfter: values.local,
                            pinned: false
                        ),
                        MatrixRetainedCopy(
                            role: .remote,
                            version: values.remote,
                            label: "conflict-remote-matrix-remote",
                            releaseAfter: values.local,
                            pinned: false
                        )
                    ]
                )
            )
        ]
    }

    private static func matrixFailedResults(_ values: MatrixValues) -> [MatrixExpectation] {
        [
            MatrixExpectation(
                state: .failed,
                event: .saveRequested,
                result: MatrixAcceptedResult(
                    state: .saving(
                        base: values.base, local: values.local, attempt: values.retryAttempt
                    ),
                    effects: [.beginWrite(version: values.local, attempt: values.retryAttempt)],
                    unresolvedAttempts: [values.firstAttempt, values.retryAttempt]
                )
            ),
            MatrixExpectation(
                state: .failed,
                event: .saveCompleted,
                result: MatrixAcceptedResult(state: .clean(version: values.local), effects: [])
            ),
            MatrixExpectation(
                state: .failed,
                event: .saveFailed,
                result: MatrixAcceptedResult(
                    state: .failed(
                        base: values.base,
                        local: values.local,
                        attempt: values.firstAttempt,
                        fault: values.fault
                    ),
                    effects: [.reportFault(values.fault)],
                    unresolvedAttempts: [values.firstAttempt]
                )
            ),
            MatrixExpectation(
                state: .failed,
                event: .saveConfirmed,
                result: MatrixAcceptedResult(state: .clean(version: values.local), effects: [])
            )
        ]
    }

    private static func matrixAcceptedResults(_ values: MatrixValues) -> [MatrixExpectation] {
        matrixCleanDirtyResults(values) +
            matrixSavingResults(values) +
            matrixConflictResults(values) +
            matrixFailedResults(values)
    }

    private static func assertMatrixOutcome(
        original: SaveSession,
        expectedRefusal: SaveSessionRefusal?,
        accepted: MatrixAcceptedResult?,
        event: SaveSessionEvent
    ) throws {
        var session = original
        if let expectedRefusal {
            #expect(accepted == nil)
            #expect(throws: expectedRefusal) { try session.reduce(event) }
            #expect(session == original)
            return
        }
        guard let accepted else {
            Issue.record("Missing accepted outcome")
            return
        }
        let effects = try session.reduce(event)
        #expect(effects == accepted.effects)
        #expect(session.state == accepted.state)
        let copies = session.retainedCopies.map {
            MatrixRetainedCopy(
                role: $0.role,
                version: $0.version,
                label: $0.label,
                releaseAfter: $0.releaseAfter,
                pinned: $0.pinned
            )
        }
        #expect(copies == accepted.retainedCopies)
        #expect(session.unresolvedAttempts == accepted.unresolvedAttempts)
    }

    private static func matrixRefusal(
        _ state: MatrixState,
        _ event: MatrixEvent
    ) -> SaveSessionRefusal? {
        matrixRefusals[state.rawValue][event.rawValue]
    }

    @Test func allFortyStateEventPairsHaveDefinedOutcomes() throws {
        let base = try Self.matrixVersion("matrix-base")
        let local = try Self.matrixVersion("matrix-local")
        let edited = try Self.matrixVersion("matrix-edited")
        let remote = try Self.matrixVersion("matrix-remote")
        let nextRemote = try Self.matrixVersion("matrix-next-remote")
        let fault = try Self.matrixFault("matrix-event")
        let unrelatedAttempt = try Self.matrixForeignAttempt()
        let firstAttempt = try #require(try Self.matrixFixture(.saving).attempt)
        let values = MatrixValues(
            base: base,
            local: local,
            edited: edited,
            remote: remote,
            nextRemote: nextRemote,
            fault: fault,
            firstAttempt: firstAttempt,
            retryAttempt: unrelatedAttempt
        )
        let acceptedResults = Self.matrixAcceptedResults(values)
        #expect(acceptedResults.count == 15)

        for stateKind in MatrixState.allCases {
            let fixture = try Self.matrixFixture(stateKind)
            let attempt = fixture.attempt ?? values.retryAttempt
            for eventKind in MatrixEvent.allCases {
                let event = Self.matrixEvent(
                    eventKind, state: stateKind, attempt: attempt, values: values
                )
                let expected = Self.matrixRefusal(stateKind, eventKind)
                let accepted = acceptedResults.first {
                    $0.state == stateKind && $0.event == eventKind
                }?.result
                try Self.assertMatrixOutcome(
                    original: fixture.session,
                    expectedRefusal: expected,
                    accepted: accepted,
                    event: event
                )
            }
        }
    }
}
