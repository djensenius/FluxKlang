/// A caller-owned copy that must not be discarded until its release condition is met.
struct SaveRetainedCopy: Equatable, Sendable {
    let role: SaveCopyRole
    let version: SaveContentVersion
    private var storedLabel: SaveCopyLabel
    private var storedReleaseAfter: SaveContentVersion?
    private var storedPinned: Bool

    var label: SaveCopyLabel { storedLabel }
    var releaseAfter: SaveContentVersion? { storedReleaseAfter }
    var pinned: Bool { storedPinned }

    fileprivate init(
        role: SaveCopyRole,
        version: SaveContentVersion,
        label: SaveCopyLabel,
        releaseAfter: SaveContentVersion?,
        pinned: Bool
    ) {
        self.role = role
        self.version = version
        storedLabel = label
        storedReleaseAfter = releaseAfter
        storedPinned = pinned
    }

    fileprivate mutating func update(releaseAfter: SaveContentVersion?, pinned: Bool) {
        if storedReleaseAfter == nil {
            storedReleaseAfter = releaseAfter
        }
        storedPinned = storedPinned || pinned
    }

    fileprivate mutating func supersede(after previous: SaveContentVersion, by next: SaveContentVersion) {
        if storedReleaseAfter == previous {
            storedReleaseAfter = next
        }
    }

    fileprivate mutating func rename(
        to label: SaveCopyLabel,
        releaseAfter: SaveContentVersion?,
        pinned: Bool
    ) {
        storedLabel = label
        storedReleaseAfter = releaseAfter
        storedPinned = pinned
    }

    func hasIdentity(role: SaveCopyRole, version: SaveContentVersion, label: SaveCopyLabel) -> Bool {
        self.role == role && self.version == version && storedLabel == label
    }
}

private struct SaveCopyRename {
    let role: SaveCopyRole
    let version: SaveContentVersion
    let oldLabel: SaveCopyLabel
    let newLabel: SaveCopyLabel
    let releaseAfter: SaveContentVersion?
    let pinned: Bool
}

private struct SaveCopyEffects {
    let retains: [SaveEffect]
    let releases: [SaveEffect]
}

/// An identity assigned monotonically by one session to a write attempt.
struct SaveAttemptID: Equatable, Hashable, Sendable {
    let rawValue: UInt64

    fileprivate init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    static func nextOrdinal(after value: UInt64) throws(SaveSessionRefusal) -> UInt64 {
        let (next, overflow) = value.addingReportingOverflow(1)
        guard !overflow else { throw .attemptIdentifierExhausted }
        return next
    }
}

/// The reducer's mutually exclusive save/conflict state.
enum SaveSessionState: Equatable, Sendable {
    case clean(version: SaveContentVersion)
    case dirty(base: SaveContentVersion, local: SaveContentVersion)
    case saving(base: SaveContentVersion, local: SaveContentVersion, attempt: SaveAttemptID)
    case conflicted(base: SaveContentVersion, local: SaveContentVersion, remote: SaveContentVersion)
    case failed(base: SaveContentVersion, local: SaveContentVersion, attempt: SaveAttemptID, fault: SaveFault)
}

/// A bounded pure reducer over injected content versions; it performs no file I/O.
///
/// The caller must serialize writes and may report `saveFailed` or start a retry only
/// after that attempt can no longer land. Dropping older unresolved attempts after a
/// current completion relies on that obligation; later landing of an older write is
/// outside the reducer's knowledge.
struct SaveSession: Equatable, Sendable {
    static let maximumRetainedCopies = 8
    static let maximumUnresolvedAttempts = 8

    private(set) var state: SaveSessionState
    private(set) var retainedCopies: [SaveRetainedCopy]
    private(set) var unresolvedAttempts: [SaveAttemptID]
    private var nextAttemptOrdinal: UInt64

    private init(initialVersion: SaveContentVersion, nextAttemptOrdinal: UInt64) {
        state = .clean(version: initialVersion)
        retainedCopies = []
        unresolvedAttempts = []
        self.nextAttemptOrdinal = nextAttemptOrdinal
    }

    static func make(initialVersion: SaveContentVersion) -> SaveSession {
        SaveSession(initialVersion: initialVersion, nextAttemptOrdinal: 1)
    }

    static func make(
        initialVersion: SaveContentVersion,
        nextAttemptOrdinal: UInt64
    ) -> SaveSession {
        SaveSession(initialVersion: initialVersion, nextAttemptOrdinal: nextAttemptOrdinal)
    }

    /// Applies an event atomically and returns effects in stable order.
    mutating func reduce(_ event: SaveSessionEvent) throws(SaveSessionRefusal) -> [SaveEffect] {
        var candidate = self
        let effects = try candidate.apply(event)
        self = candidate
        return SaveEffect.ordered(effects)
    }
    private mutating func apply(_ event: SaveSessionEvent) throws(SaveSessionRefusal) -> [SaveEffect] {
        switch event {
        case .edit(let local):
            return try edit(local)
        case .saveRequested:
            return try requestSave()
        case .saveCompleted(let attempt, let version):
            return try complete(attempt, version: version, interruptionConfirmation: false)
        case .saveFailed(let attempt, let fault):
            return try fail(attempt, fault: fault)
        case .externalChange(let remote):
            return try observeExternal(remote)
        case .conflictResolved(let choice):
            return try resolve(choice)
        case .saveConfirmedAfterInterruption(let attempt, let version):
            return try complete(attempt, version: version, interruptionConfirmation: true)
        case .reload(let version):
            return try reload(version)
        }
    }

    private mutating func reload(_ version: SaveContentVersion) throws(SaveSessionRefusal) -> [SaveEffect] {
        guard case .clean = state else {
            if case .saving = state { throw .savePending }
            if case .failed = state { throw .savePending }
            throw .reloadWouldDiscardLocal
        }
        state = .clean(version: version)
        return []
    }

    private mutating func edit(_ local: SaveContentVersion) throws(SaveSessionRefusal) -> [SaveEffect] {
        switch state {
        case .clean(let base):
            guard local != base else { return [] }
            state = .dirty(base: base, local: local)
            return []
        case .dirty(let base, let previous):
            guard local != previous else { return [] }
            for index in retainedCopies.indices {
                retainedCopies[index].supersede(after: previous, by: local)
            }
            let label = retainedCopies.first(where: {
                $0.role == .local && $0.version == previous
            })?.label ?? SaveConflictLabels.make("edited", role: .local, version: previous)
            let effect = try retain(
                role: .local, version: previous, label: label, releaseAfter: local, pinned: false
            )
            state = .dirty(base: base, local: local)
            return effect.map { [$0] } ?? []
        case .saving, .failed:
            throw .savePending
        case .conflicted:
            throw .unresolvedConflict
        }
    }
    private mutating func requestSave() throws(SaveSessionRefusal) -> [SaveEffect] {
        let base: SaveContentVersion
        let local: SaveContentVersion
        switch state {
        case .dirty(let savedBase, let savedLocal):
            base = savedBase
            local = savedLocal
        case .failed(let savedBase, let savedLocal, _, _):
            base = savedBase
            local = savedLocal
        case .clean:
            throw .noChangesToSave
        case .saving:
            throw .saveAlreadyPending
        case .conflicted:
            throw .unresolvedConflict
        }
        guard unresolvedAttempts.count < Self.maximumUnresolvedAttempts else {
            throw .attemptLimitExceeded
        }
        let followingOrdinal = try SaveAttemptID.nextOrdinal(after: nextAttemptOrdinal)
        let attempt = SaveAttemptID(rawValue: nextAttemptOrdinal)
        nextAttemptOrdinal = followingOrdinal
        unresolvedAttempts.append(attempt)
        state = .saving(base: base, local: local, attempt: attempt)
        return [.beginWrite(version: local, attempt: attempt)]
    }
    private mutating func fail(
        _ attempt: SaveAttemptID,
        fault: SaveFault
    ) throws(SaveSessionRefusal) -> [SaveEffect] {
        switch state {
        case .saving(let base, let local, let current) where current == attempt:
            state = .failed(base: base, local: local, attempt: attempt, fault: fault)
            return [.reportFault(fault)]
        case .failed(let base, let local, let current, _) where current == attempt:
            state = .failed(base: base, local: local, attempt: attempt, fault: fault)
            return [.reportFault(fault)]
        case .saving, .failed:
            throw .staleCompletion
        default:
            throw .noPendingSave
        }
    }
    private mutating func complete(
        _ attempt: SaveAttemptID,
        version: SaveContentVersion,
        interruptionConfirmation: Bool
    ) throws(SaveSessionRefusal) -> [SaveEffect] {
        let local: SaveContentVersion
        let current: SaveAttemptID
        switch state {
        case .saving(_, let savedLocal, let activeAttempt),
             .failed(_, let savedLocal, let activeAttempt, _):
            local = savedLocal
            current = activeAttempt
        default:
            throw .noPendingSave
        }
        guard version == local,
              unresolvedAttempts.contains(attempt),
              interruptionConfirmation || attempt == current else {
            throw .staleCompletion
        }
        if interruptionConfirmation,
           case .saving = state,
           attempt != current {
            throw .newerAttemptInFlight
        }
        state = .clean(version: version)
        unresolvedAttempts.removeAll()
        return releaseConfirmedCopies(by: version)
    }
    private mutating func observeExternal(
        _ remote: SaveContentVersion
    ) throws(SaveSessionRefusal) -> [SaveEffect] {
        switch state {
        case .clean:
            state = .clean(version: remote)
            return []
        case .dirty(let base, let local):
            if remote == base { return [] }
            if remote == local {
                state = .clean(version: remote)
                return releaseConfirmedCopies(by: remote)
            }
            let localLabel = SaveConflictLabels.make("conflict", role: .local, version: local)
            let remoteLabel = SaveConflictLabels.make("conflict", role: .remote, version: remote)
            let localEffect = try retain(
                role: .local, version: local, label: localLabel, releaseAfter: nil, pinned: false
            )
            let remoteEffect = try retain(
                role: .remote, version: remote, label: remoteLabel, releaseAfter: nil, pinned: false
            )
            state = .conflicted(base: base, local: local, remote: remote)
            return [localEffect, remoteEffect].compactMap { $0 } +
                [.presentConflict(base: base, local: local, remote: remote)]
        case .conflicted(let base, let local, let previousRemote):
            guard remote != previousRemote else { return [] }
            let nextLabel = SaveConflictLabels.make("conflict", role: .remote, version: remote)
            let nextEffect = try retain(
                role: .remote,
                version: remote,
                label: nextLabel,
                releaseAfter: nil,
                pinned: false
            )
            state = .conflicted(base: base, local: local, remote: remote)
            return [nextEffect].compactMap { $0 } +
                [.presentConflict(base: base, local: local, remote: remote)]
        case .saving, .failed:
            throw .savePending
        }
    }
    private mutating func resolve(_ choice: SaveConflictChoice) throws(SaveSessionRefusal) -> [SaveEffect] {
        guard case .conflicted(_, let local, let remote) = state else {
            if case .saving = state { throw .savePending }
            if case .failed = state { throw .savePending }
            throw .noConflictToResolve
        }
        switch choice {
        case .keepLocal:
            assignReleaseAfterToUnassignedCopies(local)
            state = .dirty(base: remote, local: local)
            return [.conflictResolutionApplied(choice: choice, requiresReview: true)]
        case .keepBoth:
            let copies = renameOrRetain(SaveCopyRename(
                role: .remote,
                version: remote,
                oldLabel: SaveConflictLabels.make("conflict", role: .remote, version: remote),
                newLabel: SaveConflictLabels.make("keep-both", role: .remote, version: remote),
                releaseAfter: nil,
                pinned: true
            ))
            assignReleaseAfterToUnassignedCopies(local)
            state = .dirty(base: remote, local: local)
            return copies.retains +
                [.conflictResolutionApplied(choice: choice, requiresReview: true)] +
                copies.releases
        case .keepRemote:
            let releases = releaseUnpinnedCopies()
            state = .clean(version: remote)
            return [.conflictResolutionApplied(choice: choice, requiresReview: true)] + releases
        }
    }

    private mutating func assignReleaseAfterToUnassignedCopies(_ version: SaveContentVersion) {
        for index in retainedCopies.indices where !retainedCopies[index].pinned {
            retainedCopies[index].update(releaseAfter: version, pinned: false)
        }
    }
    private mutating func retain(
        role: SaveCopyRole,
        version: SaveContentVersion,
        label: SaveCopyLabel,
        releaseAfter: SaveContentVersion?,
        pinned: Bool
    ) throws(SaveSessionRefusal) -> SaveEffect? {
        if let index = retainedCopies.firstIndex(where: {
            $0.hasIdentity(role: role, version: version, label: label)
        }) {
            retainedCopies[index].update(releaseAfter: releaseAfter, pinned: pinned)
            return nil
        }
        guard retainedCopies.count < Self.maximumRetainedCopies else {
            throw .retainedCopyLimitExceeded
        }
        retainedCopies.append(SaveRetainedCopy(
            role: role,
            version: version,
            label: label,
            releaseAfter: releaseAfter,
            pinned: pinned
        ))
        return .retainCopy(role: role, version: version, label: label)
    }

    private mutating func renameOrRetain(_ rename: SaveCopyRename) -> SaveCopyEffects {
        guard let index = retainedCopies.firstIndex(where: {
            $0.hasIdentity(role: rename.role, version: rename.version, label: rename.oldLabel)
        }) else {
            preconditionFailure("Active conflict remote must have a retained record")
        }
        let oldCopy = SaveEffect.releaseCopy(
            role: rename.role, version: rename.version, label: rename.oldLabel
        )
        if let existingIndex = retainedCopies.firstIndex(where: {
            $0.hasIdentity(role: rename.role, version: rename.version, label: rename.newLabel)
        }) {
            retainedCopies[existingIndex].rename(
                to: rename.newLabel, releaseAfter: rename.releaseAfter, pinned: rename.pinned
            )
            retainedCopies.remove(at: index)
            return SaveCopyEffects(retains: [], releases: [oldCopy])
        }
        retainedCopies[index].rename(
            to: rename.newLabel, releaseAfter: rename.releaseAfter, pinned: rename.pinned
        )
        return SaveCopyEffects(
            retains: [.retainCopy(role: rename.role, version: rename.version, label: rename.newLabel)],
            releases: [oldCopy]
        )
    }

    private mutating func releaseConfirmedCopies(by version: SaveContentVersion) -> [SaveEffect] {
        var release: [SaveRetainedCopy] = []
        retainedCopies.removeAll { copy in
            guard !copy.pinned else { return false }
            let confirmedRelease = copy.releaseAfter == version
            guard confirmedRelease else { return false }
            release.append(copy)
            return true
        }
        return release.map {
            .releaseCopy(role: $0.role, version: $0.version, label: $0.label)
        }
    }

    private mutating func releaseUnpinnedCopies() -> [SaveEffect] {
        var release: [SaveRetainedCopy] = []
        retainedCopies.removeAll { copy in
            guard !copy.pinned else { return false }
            release.append(copy)
            return true
        }
        return release.map {
            .releaseCopy(role: $0.role, version: $0.version, label: $0.label)
        }
    }
}
