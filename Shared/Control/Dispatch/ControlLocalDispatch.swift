//
//  ControlLocalDispatch.swift
//  FluxKlang
//
//  Turns one local MIDI control message into ordered proposals in two steps (#88, LCD1). `admit` decides which
//  bindings hear the message and decodes it per binding; the caller runs its echo check on each candidate and
//  collects the ids it classified as echoes; `settle` skips those and resolves the rest against host truth.
//  A proposal is a value that names no writer, command intent or outbound queue. Every input is a value, every
//  result is a value, and nothing here sends or writes.
//

/// One local MIDI message as the dispatcher reads it: the state update (which decides the control source and the
/// raw value), the sending origin and the controller-pair dialect.
struct ControlLocalInput: Sendable {
    let update: MIDI1StateUpdate
    let origin: ControlSourceOrigin
    let dialect: ControlIntakeDialect

    init(update: MIDI1StateUpdate, origin: ControlSourceOrigin, dialect: ControlIntakeDialect = .pairedFourteenBit) {
        self.update = update
        self.origin = origin
        self.dialect = dialect
    }
}

/// A binding that hears the message: the binding, the message decoded by its own profile and its pickup state.
struct ControlLocalCandidate: Hashable, Sendable {
    let binding: ControlBinding
    let input: ControlInput
    let state: PickupState

    fileprivate init(binding: ControlBinding, input: ControlInput, state: PickupState) {
        self.binding = binding
        self.input = input
        self.state = state
    }
}

/// What `admit` decided. `candidates` and the per-binding entries of `refusals` follow ascending binding id (UTF-8
/// byte order). A call-level refusal is the only entry of `refusals` and `candidates` is empty.
struct ControlLocalAdmission: Hashable, Sendable {
    let candidates: [ControlLocalCandidate]
    let refusals: [ControlLocalDispatchRefusal]

    fileprivate init(candidates: [ControlLocalCandidate], refusals: [ControlLocalDispatchRefusal]) {
        self.candidates = candidates
        self.refusals = refusals
    }
}

/// A request for the host to apply `operation` to `target`.
struct ControlLocalProposal: Hashable, Sendable {
    let binding: BindingID
    let target: ParameterID
    let operation: CommandOperation

    fileprivate init(binding: BindingID, target: ParameterID, operation: CommandOperation) {
        self.binding = binding
        self.target = target
        self.operation = operation
    }
}

/// An input a catch binding held back. `hardware` and `target` are the normalized positions the pickup decision
/// reported, passed through unmodified.
struct ControlLocalHold: Hashable, Sendable {
    let binding: BindingID
    let hardware: Double
    let target: Double
    let reason: PickupHoldReason

    fileprivate init(binding: BindingID, hardware: Double, target: Double, reason: PickupHoldReason) {
        self.binding = binding
        self.hardware = hardware
        self.target = target
        self.reason = reason
    }
}

/// The new pickup state of one binding that resolved.
struct ControlLocalPickupUpdate: Hashable, Sendable {
    let binding: BindingID
    let state: PickupState

    fileprivate init(binding: BindingID, state: PickupState) {
        self.binding = binding
        self.state = state
    }
}

/// What `settle` produced. Every list follows ascending binding id, except `refusals`: the admission's refusals
/// come first, then the refusals of `settle`, each group ascending (a concatenation, not a merge).
/// `pickupUpdates` lists only the bindings that resolved (proposed, held or unchanged): the caller applies them to
/// its own table, and the entry of a refused or echoed binding stays as it was. No table is copied or returned.
struct ControlLocalDispatchResult: Hashable, Sendable {
    let proposals: [ControlLocalProposal]
    let holds: [ControlLocalHold]
    let echoed: [BindingID]
    let refusals: [ControlLocalDispatchRefusal]
    let pickupUpdates: [ControlLocalPickupUpdate]

    fileprivate init(proposals: [ControlLocalProposal], holds: [ControlLocalHold], echoed: [BindingID],
                     refusals: [ControlLocalDispatchRefusal], pickupUpdates: [ControlLocalPickupUpdate]) {
        self.proposals = proposals
        self.holds = holds
        self.echoed = echoed
        self.refusals = refusals
        self.pickupUpdates = pickupUpdates
    }
}

/// The caller composes the steps in this order, which is documented and not enforced: (1) the Learn input gate
/// while a session exists, (2) `admit`, (3) the feedback echo check on each candidate, (4) `settle`, (5) the caller
/// applies `pickupUpdates` and submits the proposals through its own writer. The dispatcher calls neither the gate
/// nor the echo check and keeps no state.
enum ControlLocalDispatch {
    /// The most bindings one call evaluates.
    static let maximumBindings = ControlBindingLimit.maximumBindings

    /// Checks, first failure wins and refuses the whole call: (1) no Learn session is listening or awaiting
    /// review, (2) the update names a control source, (3) at most `maximumBindings` bindings, (4) no binding id
    /// repeats. Then every binding whose source matches is evaluated in ascending id order: it needs a pickup
    /// entry, then the update must fit its profile. One binding's refusal never suppresses another's candidate.
    static func admit(input: ControlLocalInput, learn: LearnPhaseKind, bindings: [ControlBinding],
                      pickup: [BindingID: PickupState]) -> ControlLocalAdmission {
        do throws(ControlLocalDispatchRefusal) {
            try requireNotLearning(learn)
            let key = try sourceKey(of: input)
            try requireWithinCap(bindings)
            try requireDistinctIDs(bindings)
            return collect(bindings, source: key.sourceID, input: input, pickup: pickup)
        } catch {
            return ControlLocalAdmission(candidates: [], refusals: [error])
        }
    }

    /// Per candidate in the admission's order: an id in `echoes` is only listed in `echoed` (host truth is not
    /// read); otherwise the binding resolves against `truth` into a proposal, a hold or nothing, and its new pickup
    /// state is reported. An echo id that is not a candidate is ignored.
    static func settle(_ admission: ControlLocalAdmission, echoes: Set<BindingID>,
                       truth: ControlHostTruth) -> ControlLocalDispatchResult {
        var proposals: [ControlLocalProposal] = []
        var holds: [ControlLocalHold] = []
        var echoed: [BindingID] = []
        var refusals = admission.refusals
        var updates: [ControlLocalPickupUpdate] = []
        for candidate in admission.candidates {
            let id = candidate.binding.id
            if echoes.contains(id) {
                echoed.append(id)
                continue
            }
            do throws(ControlLocalDispatchRefusal) {
                let resolution = try resolve(candidate, truth: truth)
                record(resolution.decision, of: candidate, proposals: &proposals, holds: &holds)
                updates.append(ControlLocalPickupUpdate(binding: id, state: resolution.state))
            } catch {
                refusals.append(error)
            }
        }
        return ControlLocalDispatchResult(
            proposals: proposals, holds: holds, echoed: echoed, refusals: refusals, pickupUpdates: updates
        )
    }

    private static func requireNotLearning(_ kind: LearnPhaseKind) throws(ControlLocalDispatchRefusal) {
        switch kind {
        case .listening, .awaitingReview:
            throw .learnActive(kind)
        case .idle, .committed, .cancelled, .blocked:
            break
        }
    }

    private static func sourceKey(of input: ControlLocalInput) throws(ControlLocalDispatchRefusal) -> ControlSourceKey {
        do throws(ControlIntakeRefusal) {
            return try MIDIControlIntake.key(for: input.update, origin: input.origin, dialect: input.dialect).key
        } catch {
            throw .intake(error)
        }
    }

    private static func requireWithinCap(_ bindings: [ControlBinding]) throws(ControlLocalDispatchRefusal) {
        guard bindings.count <= maximumBindings else { throw .tooManyBindings(bindings.count) }
    }

    private static func requireDistinctIDs(_ bindings: [ControlBinding]) throws(ControlLocalDispatchRefusal) {
        var seen = Set<BindingID>()
        var smallest: BindingID?
        for binding in bindings {
            let isRepeat = !seen.insert(binding.id).inserted
            if isRepeat { smallest = earlier(smallest, binding.id) }
        }
        if let smallest { throw .duplicateBinding(smallest) }
    }

    private static func earlier(_ current: BindingID?, _ other: BindingID) -> BindingID {
        guard let current else { return other }
        return precedes(other, current) ? other : current
    }

    private static func collect(_ bindings: [ControlBinding], source: ControlSourceID, input: ControlLocalInput,
                                pickup: [BindingID: PickupState]) -> ControlLocalAdmission {
        var matching: [ControlBinding] = []
        for binding in bindings where binding.source.rawValue.utf8.elementsEqual(source.rawValue.utf8) {
            matching.append(binding)
        }
        matching.sort { precedes($0.id, $1.id) }
        var candidates: [ControlLocalCandidate] = []
        candidates.reserveCapacity(matching.count)
        var refusals: [ControlLocalDispatchRefusal] = []
        for binding in matching {
            do throws(ControlLocalDispatchRefusal) {
                candidates.append(try candidate(for: binding, input: input, pickup: pickup))
            } catch {
                refusals.append(error)
            }
        }
        return ControlLocalAdmission(candidates: candidates, refusals: refusals)
    }

    /// Per binding, first failure wins: the pickup entry is present, then the update fits the binding's profile.
    private static func candidate(for binding: ControlBinding, input: ControlLocalInput,
                                  pickup: [BindingID: PickupState]) throws(ControlLocalDispatchRefusal)
        -> ControlLocalCandidate {
        guard let state = pickup[binding.id] else { throw .pickupStateMissing(binding.id) }
        let sample = try intakeSample(for: binding, input: input)
        return ControlLocalCandidate(binding: binding, input: sample.input, state: state)
    }

    private static func intakeSample(for binding: ControlBinding,
                                     input: ControlLocalInput) throws(ControlLocalDispatchRefusal)
        -> ControlIntakeSample {
        do throws(ControlIntakeRefusal) {
            return try MIDIControlIntake.resolve(
                input.update, origin: input.origin, profile: binding.profile, dialect: input.dialect
            )
        } catch {
            throw .bindingIntake(binding.id, error)
        }
    }

    private static func resolve(_ candidate: ControlLocalCandidate,
                                truth: ControlHostTruth) throws(ControlLocalDispatchRefusal) -> PickupResolution {
        do throws(ControlBindingRefusal) {
            return try candidate.binding.resolve(input: candidate.input, truth: truth, state: candidate.state)
        } catch {
            throw .binding(candidate.binding.id, error)
        }
    }

    private static func record(_ decision: PickupDecision, of candidate: ControlLocalCandidate,
                               proposals: inout [ControlLocalProposal], holds: inout [ControlLocalHold]) {
        let id = candidate.binding.id
        switch decision {
        case .apply(let operation):
            proposals.append(ControlLocalProposal(binding: id, target: candidate.binding.target, operation: operation))
        case .held(let hardware, let target, let reason):
            holds.append(ControlLocalHold(binding: id, hardware: hardware, target: target, reason: reason))
        case .unchanged:
            break
        }
    }

    private static func precedes(_ lhs: BindingID, _ rhs: BindingID) -> Bool {
        lhs.rawValue.utf8.lexicographicallyPrecedes(rhs.rawValue.utf8)
    }
}
