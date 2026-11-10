//
//  ControlLocalTriggerDispatch.swift
//  FluxKlang
//
//  Turns one local MIDI control message into the commands of `ControlTriggerDetector.handle` (#87, LTD1): the
//  intake decides which source the message is and how each trigger binding decodes it, then every binding that
//  hears it is handed to the detector in ascending binding id order. Nothing calls this yet. It reads no MIDI port,
//  registry or Learn gate, owns no detector (the caller passes one `inout`) and sends nothing.
//

/// What `dispatch` decided. `commands`, `silent` and the per-binding entries of `refusals` follow ascending binding
/// id (UTF-8 byte order). A call-level refusal is the only entry of `refusals`, and `commands` and `silent` are empty.
/// `silent` lists the bindings that heard the message and were accepted but issued no command (no edge).
struct ControlLocalTriggerResult: Hashable, Sendable {
    let commands: [ControlTriggerCommand]
    let silent: [BindingID]
    let refusals: [ControlLocalTriggerRefusal]

    fileprivate init(commands: [ControlTriggerCommand], silent: [BindingID],
                     refusals: [ControlLocalTriggerRefusal]) {
        self.commands = commands
        self.silent = silent
        self.refusals = refusals
    }
}

/// The caller owns the detector and the host truth and calls the Learn gate itself; this reads only the Learn phase
/// kind. The bindings passed are the ROUTING list (the caller passes those it built the detector from): the detector
/// holds the authoritative binding, and this reads the list for source match, id and profile only. It does not compare
/// a routing binding's profile with the detector's own: `handle` takes no profile and the sorting `bindings` getter is
/// not used (owner question b).
enum ControlLocalTriggerDispatch {
    /// The most bindings one call evaluates.
    static let maximumBindings = ControlBindingLimit.maximumBindings

    /// Checks, first failure wins and refuses the whole call before any detector call: (1) no Learn session is
    /// listening or awaiting review, (2) the update names a control source (the intake admits what it admits: notes
    /// and sustain are refused), (3) at most `maximumBindings` bindings, (4) no binding id repeats. Then every
    /// binding whose source equals the update's source id is evaluated in ascending id order: the update must fit
    /// its profile, then the detector reads it. One binding's refusal never suppresses another's command.
    static func dispatch(input: ControlLocalInput, learn: LearnPhaseKind, bindings: [ControlTriggerBinding],
                         detector: inout ControlTriggerDetector,
                         truth: ControlTriggerHostTruth) -> ControlLocalTriggerResult {
        do throws(ControlLocalTriggerRefusal) {
            try requireNotLearning(learn)
            let key = try sourceKey(of: input)
            try requireWithinCap(bindings)
            try requireDistinctIDs(bindings)
            let heard = matching(bindings, source: key.sourceID)
            return fire(heard, input: input, detector: &detector, truth: truth)
        } catch {
            return ControlLocalTriggerResult(commands: [], silent: [], refusals: [error])
        }
    }

    private static func requireNotLearning(_ kind: LearnPhaseKind) throws(ControlLocalTriggerRefusal) {
        switch kind {
        case .listening, .awaitingReview:
            throw .learnActive(kind)
        case .idle, .committed, .cancelled, .blocked:
            break
        }
    }

    private static func sourceKey(of input: ControlLocalInput) throws(ControlLocalTriggerRefusal) -> ControlSourceKey {
        do throws(ControlIntakeRefusal) {
            return try MIDIControlIntake.key(for: input.update, origin: input.origin, dialect: input.dialect).key
        } catch {
            throw .intake(error)
        }
    }

    private static func requireWithinCap(_ bindings: [ControlTriggerBinding]) throws(ControlLocalTriggerRefusal) {
        guard bindings.count <= maximumBindings else { throw .tooManyBindings(bindings.count) }
    }

    private static func requireDistinctIDs(_ bindings: [ControlTriggerBinding]) throws(ControlLocalTriggerRefusal) {
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

    private static func matching(_ bindings: [ControlTriggerBinding], source: ControlSourceID)
        -> [ControlTriggerBinding] {
        var heard: [ControlTriggerBinding] = []
        for binding in bindings where binding.source.rawValue.utf8.elementsEqual(source.rawValue.utf8) {
            heard.append(binding)
        }
        heard.sort { precedes($0.id, $1.id) }
        return heard
    }

    private static func fire(_ heard: [ControlTriggerBinding], input: ControlLocalInput,
                             detector: inout ControlTriggerDetector,
                             truth: ControlTriggerHostTruth) -> ControlLocalTriggerResult {
        var commands: [ControlTriggerCommand] = []
        var silent: [BindingID] = []
        var refusals: [ControlLocalTriggerRefusal] = []
        commands.reserveCapacity(heard.count)
        for binding in heard {
            do throws(ControlLocalTriggerRefusal) {
                if let command = try step(binding, input: input, detector: &detector, truth: truth) {
                    commands.append(command)
                } else {
                    silent.append(binding.id)
                }
            } catch {
                refusals.append(error)
            }
        }
        return ControlLocalTriggerResult(commands: commands, silent: silent, refusals: refusals)
    }

    /// Per binding, first failure wins: the update fits the binding's profile, then the detector accepts it.
    private static func step(_ binding: ControlTriggerBinding, input: ControlLocalInput,
                             detector: inout ControlTriggerDetector,
                             truth: ControlTriggerHostTruth) throws(ControlLocalTriggerRefusal)
        -> ControlTriggerCommand? {
        let sample = try intakeSample(for: binding, input: input)
        do throws(ControlTriggerRefusal) {
            return try detector.handle(sample.input, from: binding.source, binding: binding.id, truth: truth)
        } catch {
            throw .detector(binding.id, error)
        }
    }

    private static func intakeSample(for binding: ControlTriggerBinding,
                                     input: ControlLocalInput) throws(ControlLocalTriggerRefusal)
        -> ControlIntakeSample {
        do throws(ControlIntakeRefusal) {
            return try MIDIControlIntake.resolve(
                input.update, origin: input.origin, profile: binding.profile, dialect: input.dialect
            )
        } catch {
            throw .bindingIntake(binding.id, error)
        }
    }

    private static func precedes(_ lhs: BindingID, _ rhs: BindingID) -> Bool {
        lhs.rawValue.utf8.lexicographicallyPrecedes(rhs.rawValue.utf8)
    }
}
