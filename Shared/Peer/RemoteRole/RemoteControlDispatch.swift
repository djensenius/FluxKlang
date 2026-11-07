//
//  RemoteControlDispatch.swift
//  FluxKlang
//
//  Turns one local MIDI message into proposals for the controlled host (#96, RR2). A proposal is a value that
//  names no writer, command intent or outbound queue: ids, the permission fingerprint and sequencing stay with
//  the caller. Every input is a value and the result is a value.
//

/// One local MIDI message as the dispatcher reads it: the semantic message (which decides whether it may be
/// control at all) and the state update derived from the same message (which decides the control source).
struct RemoteMIDIInput: Sendable {
    let semantic: MIDI1Semantic
    let update: MIDI1StateUpdate
    let origin: ControlSourceOrigin
    let dialect: ControlIntakeDialect

    init(semantic: MIDI1Semantic, update: MIDI1StateUpdate, origin: ControlSourceOrigin,
         dialect: ControlIntakeDialect = .pairedFourteenBit) {
        self.semantic = semantic
        self.update = update
        self.origin = origin
        self.dialect = dialect
    }
}

/// A request for the host to apply `operation` to `target`, resolved against the mirror stamped by `basis`.
struct RemoteProposal: Hashable, Sendable {
    let binding: BindingID
    let target: ParameterID
    let operation: CommandOperation
    let basis: CommandRevisions
    let session: PeerSyncSession

    fileprivate init(binding: BindingID, target: ParameterID, operation: CommandOperation,
                     basis: CommandRevisions, session: PeerSyncSession) {
        self.binding = binding
        self.target = target
        self.operation = operation
        self.basis = basis
        self.session = session
    }
}

/// What one call produced. `proposals`, `held` and the per-binding entries of `refusals` follow ascending
/// `BindingID`. `pickup` is the table the caller stores for the next call: the table passed in, with the entry of
/// every binding that resolved (proposed, held or unchanged) replaced by its new state; the entry of a refused
/// binding stays as it was.
struct RemoteDispatchResult: Hashable, Sendable {
    let proposals: [RemoteProposal]
    let held: [BindingID]
    let refusals: [RemoteDispatchRefusal]
    let pickup: [BindingID: PickupState]

    fileprivate init(proposals: [RemoteProposal], held: [BindingID], refusals: [RemoteDispatchRefusal],
                     pickup: [BindingID: PickupState]) {
        self.proposals = proposals
        self.held = held
        self.refusals = refusals
        self.pickup = pickup
    }

    /// A refused call: one refusal, nothing proposed or held, and the pickup table exactly as it came in.
    fileprivate init(refusal: RemoteDispatchRefusal, pickup: [BindingID: PickupState]) {
        self.init(proposals: [], held: [], refusals: [refusal], pickup: pickup)
    }
}

enum RemoteControlDispatch {
    /// The most bindings one call evaluates.
    static let maximumBindings = 256

    /// Checks, first failure wins and refuses the whole call: (1) the role is `.remoteController`, (2) its grant
    /// allows peer commands, (3) the message is not raw input, (4) a mirror is supplied and belongs to the
    /// controlled host, (5) the update names a control source, (6) at most `maximumBindings` bindings, (7) no
    /// binding id repeats. Then every binding whose source matches is evaluated in ascending id order; one
    /// binding's refusal never suppresses another's proposal. Bindings of other sources are skipped.
    static func propose(role: RemoteRole, mirror: RemoteMirror?, input: RemoteMIDIInput,
                        bindings: [ControlBinding], pickup: [BindingID: PickupState]) -> RemoteDispatchResult {
        do throws(RemoteDispatchRefusal) {
            let session = try controllingSession(of: role)
            try requireProposalGrant(of: role)
            try requireBindable(input.semantic)
            let live = try currentMirror(mirror, for: session)
            let key = try sourceKey(of: input)
            try requireWithinCap(bindings)
            try requireDistinctIDs(bindings)
            return evaluate(bindings, source: key.sourceID, mirror: live, input: input, pickup: pickup)
        } catch {
            return RemoteDispatchResult(refusal: error, pickup: pickup)
        }
    }

    private static func controllingSession(of role: RemoteRole) throws(RemoteDispatchRefusal) -> RemoteSession {
        guard case .remoteController(let session) = role.phase else { throw .notRemoteController(role.kind) }
        return session
    }

    /// Delegates to the guard: only `.allowed` passes. The guard's one refusal for a controlling role is the
    /// observer grant; any other refusal it may gain would be reported as `observerHasNoCommands` until this
    /// mapping learns it.
    private static func requireProposalGrant(of role: RemoteRole) throws(RemoteDispatchRefusal) {
        guard case .allowed = RemoteRoleGuard.decide(role: role, capability: .peerUICommand) else {
            throw .observerHasNoCommands
        }
    }

    private static func requireBindable(_ semantic: MIDI1Semantic) throws(RemoteDispatchRefusal) {
        let raw = RemoteRoleGuard.classify(semantic)
        guard raw == .needsBinding else { throw .rawInput(raw) }
    }

    private static func currentMirror(_ mirror: RemoteMirror?,
                                      for session: RemoteSession) throws(RemoteDispatchRefusal) -> RemoteMirror {
        guard let mirror else { throw .mirrorUnavailable }
        guard mirror.session.hostEpoch.host == session.host else { throw .staleSession }
        return mirror
    }

    private static func sourceKey(of input: RemoteMIDIInput) throws(RemoteDispatchRefusal) -> ControlSourceKey {
        do throws(ControlIntakeRefusal) {
            return try MIDIControlIntake.key(for: input.update, origin: input.origin, dialect: input.dialect).key
        } catch {
            throw .intake(error)
        }
    }

    private static func requireWithinCap(_ bindings: [ControlBinding]) throws(RemoteDispatchRefusal) {
        guard bindings.count <= maximumBindings else { throw .tooManyBindings(bindings.count) }
    }

    private static func requireDistinctIDs(_ bindings: [ControlBinding]) throws(RemoteDispatchRefusal) {
        var seen = Set<BindingID>()
        var smallest: BindingID?
        for binding in bindings {
            let isRepeat = !seen.insert(binding.id).inserted
            if isRepeat { smallest = smallest.map { min($0, binding.id) } ?? binding.id }
        }
        if let smallest { throw .duplicateBinding(smallest) }
    }

    private static func evaluate(_ bindings: [ControlBinding], source: ControlSourceID, mirror: RemoteMirror,
                                 input: RemoteMIDIInput, pickup: [BindingID: PickupState]) -> RemoteDispatchResult {
        var proposals: [RemoteProposal] = []
        var held: [BindingID] = []
        var refusals: [RemoteDispatchRefusal] = []
        var updated = pickup
        for binding in bindings.sorted(by: { $0.id < $1.id }) where binding.source == source {
            do throws(RemoteDispatchRefusal) {
                let resolution = try resolve(binding, mirror: mirror, input: input, state: pickup[binding.id])
                updated[binding.id] = resolution.state
                switch resolution.decision {
                case .apply(let operation):
                    proposals.append(RemoteProposal(
                        binding: binding.id, target: binding.target, operation: operation,
                        basis: mirror.revisions, session: mirror.session
                    ))
                case .held:
                    held.append(binding.id)
                case .unchanged:
                    break
                }
            } catch {
                refusals.append(error)
            }
        }
        return RemoteDispatchResult(proposals: proposals, held: held, refusals: refusals, pickup: updated)
    }

    /// Per binding, first failure wins: the pickup entry is present, the update fits the binding's profile,
    /// then the binding resolves against the mirror's truth.
    private static func resolve(_ binding: ControlBinding, mirror: RemoteMirror, input: RemoteMIDIInput,
                                state: PickupState?) throws(RemoteDispatchRefusal) -> PickupResolution {
        guard let state else { throw .pickupStateMissing(binding.id) }
        let sample = try intakeSample(for: binding, input: input)
        do throws(ControlBindingRefusal) {
            return try binding.resolve(input: sample.input, truth: mirror.truth, state: state)
        } catch {
            throw .binding(binding.id, error)
        }
    }

    private static func intakeSample(for binding: ControlBinding,
                                     input: RemoteMIDIInput) throws(RemoteDispatchRefusal) -> ControlIntakeSample {
        do throws(ControlIntakeRefusal) {
            return try MIDIControlIntake.resolve(
                input.update, origin: input.origin, profile: binding.profile, dialect: input.dialect
            )
        } catch {
            throw .bindingIntake(binding.id, error)
        }
    }
}
