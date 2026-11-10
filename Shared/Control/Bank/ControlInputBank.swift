//
//  ControlInputBank.swift
//  FluxKlang
//
//  Owns one pickup book and one trigger detector for a rig and joins a MIDI input to the control sources of its
//  bindings (#87, CPR1). `receive` runs the merged dispatchers in a pinned order; `inputLost` and `inputSeen` are the
//  only join to a MIDI input, and the host makes those calls itself. Nothing calls this yet. It reads no port,
//  registry, session, notice or time source, sends nothing and writes no parameter: proposals and commands are
//  returned, never submitted. `clear` is the host's explicit switch-off for toggles and latches.
//

/// What one `receive` produced. The pickup updates in `faders` are already stored in the bank's book.
struct ControlInputBankResult: Hashable, Sendable {
    let faders: ControlLocalDispatchResult
    let triggers: ControlLocalTriggerResult

    fileprivate init(faders: ControlLocalDispatchResult, triggers: ControlLocalTriggerResult) {
        self.faders = faders
        self.triggers = triggers
    }
}

/// What `inputLost` changed. Both lists are empty when the input was already lost.
struct ControlInputBankLoss: Hashable, Sendable {
    let input: MIDIInputID
    let origin: ControlSourceOrigin
    /// Fader bindings that became unavailable, ascending by id bytes.
    let unavailable: [BindingID]
    /// Releases of held triggers (cause `.disconnect`) with consecutive sequences, ascending by id bytes.
    let releases: [ControlTriggerCommand]

    fileprivate init(input: MIDIInputID, origin: ControlSourceOrigin, unavailable: [BindingID],
                     releases: [ControlTriggerCommand]) {
        self.input = input
        self.origin = origin
        self.unavailable = unavailable
        self.releases = releases
    }
}

/// A plain value. Identity: `ControlSourceOrigin` and `ControlSourceID` hold ASCII only here (the parser refuses
/// anything else), so their synthesized equality is byte equality. Every sort and search compares UTF-8 bytes.
/// The cost of `inputLost` and `inputSeen` grows with the sources of the slot times the book size: each call to
/// `sourceLost` or `sourceSeen` scans the whole book, and the slot lists fader and trigger sources alike, so the worst
/// case is (maximumFaders + maximumTriggers) x maximumFaders x 51 = 512 x 256 x 51 = 6,684,672 byte steps, once per
/// call on the control thread. A rig above `maximumFaders` or `maximumTriggers` is refused at build instead of
/// running silently dead; both limits are the bank's own and are not aliases of any binding cap. A `receive` costs
/// about 1.2 million byte steps at the limits (derivation in the evidence package).
struct ControlInputBank: Hashable, Sendable {
    static let maximumLinks = ControlSourceAvailability.maximumLiveOrigins
    static let maximumFaders = 256
    static let maximumTriggers = 256

    private struct Slot: Hashable, Sendable {
        let input: MIDIInputID
        let origin: ControlSourceOrigin
        /// Distinct sources of the origin, ascending by UTF-8 bytes.
        var sources: [ControlSourceID] = []
        var lost = false

        mutating func add(_ source: ControlSourceID) {
            var low = 0
            var high = sources.count
            let mine = source.rawValue.utf8
            while low < high {
                let middle = low + (high - low) / 2
                let probe = sources[middle].rawValue.utf8
                if probe.lexicographicallyPrecedes(mine) {
                    low = middle + 1
                } else if probe.elementsEqual(mine) {
                    return
                } else {
                    high = middle
                }
            }
            sources.insert(source, at: low)
        }
    }

    private(set) var pickup: ControlPickupBook
    private(set) var detector: ControlTriggerDetector
    /// The trigger list the dispatcher routes by, ascending by id bytes.
    private let routing: [ControlTriggerBinding]
    /// Ascending by input.
    private var slots: [Slot]

    /// Inputs reported lost and not yet seen again, ascending.
    var lostInputs: [MIDIInputID] { slots.filter(\.lost).map(\.input) }

    /// Builds the bank or refuses with the first failure of the order given on `ControlInputBankRefusal`. A new
    /// detector starts released and off; `afterSequence` resumes a counter so a rebuilt bank never reissues one.
    init(links: [ControlInputBankLink], faders: [ControlBinding], triggers: [ControlTriggerBinding],
         afterSequence: UInt64 = 0) throws(ControlInputBankRefusal) {
        guard links.count <= Self.maximumLinks else { throw .tooManyLinks(links.count) }
        var slots = try Self.makeSlots(links)
        guard faders.count <= Self.maximumFaders else { throw .tooManyFaders(faders.count) }
        guard triggers.count <= Self.maximumTriggers else { throw .tooManyTriggers(triggers.count) }
        let orderedFaders = faders.sorted { Self.precedes($0.id, $1.id) }
        let orderedTriggers = triggers.sorted { Self.precedes($0.id, $1.id) }
        let index = Self.originIndex(of: slots)
        var book = ControlPickupBook()
        for binding in orderedFaders {
            try Self.attach(binding.source, of: binding.id, to: &slots, index: index)
            do throws(ControlPickupBookRefusal) { try book.add(binding) } catch { throw .pickup(error) }
        }
        for binding in orderedTriggers {
            try Self.attach(binding.source, of: binding.id, to: &slots, index: index)
        }
        pickup = book
        detector = try Self.makeDetector(orderedTriggers, after: afterSequence)
        routing = orderedTriggers
        self.slots = slots
    }

    /// Runs one local update through the fader dispatcher, stores its pickup updates, then runs the trigger
    /// dispatcher. A refusal returns no result and leaves the bank equal: the book write is the only step that can
    /// throw after the link and lost checks, and it comes before the detector moves.
    mutating func receive(_ input: ControlLocalInput, learn: LearnPhaseKind, echoes: Set<BindingID>,
                          truth: ControlInputBankTruth) throws(ControlInputBankRefusal) -> ControlInputBankResult {
        let origin = input.origin
        guard let place = slots.firstIndex(where: { Self.sameOrigin($0.origin, origin) }) else {
            throw .unlinkedOrigin(origin)
        }
        guard !slots[place].lost else { throw .originLost(origin) }
        let admission = ControlLocalDispatch.admit(
            input: input, learn: learn, bindings: pickup.entries.map(\.binding), pickup: pickup.states
        )
        let faders = ControlLocalDispatch.settle(admission, echoes: echoes, truth: truth.control)
        try store(faders)
        let triggers = ControlLocalTriggerDispatch.dispatch(
            input: input, learn: learn, bindings: routing, detector: &detector, truth: truth.trigger
        )
        return ControlInputBankResult(faders: faders, triggers: triggers)
    }

    /// The host calls this after a detach or after it reads `.sensingLostReleased`. The held triggers of the origin
    /// are released first (all or nothing); then the origin is marked lost and its fader bindings become
    /// unavailable. A lost input returns an empty loss and changes nothing.
    mutating func inputLost(_ input: MIDIInputID) throws(ControlInputBankRefusal) -> ControlInputBankLoss {
        let place = try slotIndex(of: input)
        let slot = slots[place]
        guard !slot.lost else {
            return ControlInputBankLoss(input: input, origin: slot.origin, unavailable: [], releases: [])
        }
        let releases = try forgetHeld(on: slot.sources)
        slots[place].lost = true
        var unavailable: [BindingID] = []
        for source in slot.sources { unavailable += pickup.sourceLost(source) }
        return ControlInputBankLoss(
            input: input, origin: slot.origin, unavailable: Self.sorted(unavailable), releases: releases
        )
    }

    /// The only way back after `inputLost`. Returns the fader bindings that left the unavailable state, ascending;
    /// a catch binding waits for a fresh position. A live input returns `[]` and changes nothing.
    @discardableResult
    mutating func inputSeen(_ input: MIDIInputID) throws(ControlInputBankRefusal) -> [BindingID] {
        let place = try slotIndex(of: input)
        guard slots[place].lost else { return [] }
        slots[place].lost = false
        var seen: [BindingID] = []
        for source in slots[place].sources { seen += pickup.sourceSeen(source) }
        return Self.sorted(seen)
    }

    /// The host's explicit switch-off for a toggle or latch. Input never switches a latch off, and `inputLost` keeps
    /// toggle and latch outputs. Forwards to `ControlTriggerDetector.clear`: a `switchedOff` command (cause `.clear`)
    /// when the output is on, `nil` when it is already off. A lost origin does not block it, and no slot, link or book
    /// is read. A refusal (`.trigger` with the detector's payload: unknown id, momentary binding, exhausted sequence)
    /// leaves the bank equal.
    mutating func clear(_ id: BindingID) throws(ControlInputBankRefusal) -> ControlTriggerCommand? {
        do throws(ControlTriggerRefusal) { return try detector.clear(id) } catch { throw .trigger(error) }
    }

    private func slotIndex(of input: MIDIInputID) throws(ControlInputBankRefusal) -> Int {
        guard let place = slots.firstIndex(where: { $0.input == input }) else { throw .unknownInput(input) }
        return place
    }

    private mutating func store(_ result: ControlLocalDispatchResult) throws(ControlInputBankRefusal) {
        var states: [BindingID: PickupState] = [:]
        for update in result.pickupUpdates { states[update.binding] = update.state }
        do throws(ControlPickupBookRefusal) { try pickup.record(states) } catch { throw .pickup(error) }
    }

    private mutating func forgetHeld(
        on sources: [ControlSourceID]
    ) throws(ControlInputBankRefusal) -> [ControlTriggerCommand] {
        do throws(ControlTriggerRefusal) { return try detector.forgetHeld(on: Set(sources)) } catch {
            throw .trigger(error)
        }
    }

    private static func makeSlots(_ links: [ControlInputBankLink]) throws(ControlInputBankRefusal) -> [Slot] {
        let byInput = links.sorted { $0.input < $1.input }
        for position in byInput.indices.dropFirst() where byInput[position].input == byInput[position - 1].input {
            throw .duplicateInput(byInput[position].input)
        }
        let origins = links.map(\.origin).sorted { $0.token.utf8.lexicographicallyPrecedes($1.token.utf8) }
        for position in origins.indices.dropFirst() where sameOrigin(origins[position], origins[position - 1]) {
            throw .duplicateOrigin(origins[position])
        }
        return byInput.map { Slot(input: $0.input, origin: $0.origin) }
    }

    private static func makeDetector(
        _ triggers: [ControlTriggerBinding], after sequence: UInt64
    ) throws(ControlInputBankRefusal) -> ControlTriggerDetector {
        do throws(ControlTriggerRefusal) {
            return try ControlTriggerDetector(bindings: triggers, after: sequence)
        } catch {
            throw .trigger(error)
        }
    }

    private static func originIndex(of slots: [Slot]) -> [ControlSourceOrigin: Int] {
        var index: [ControlSourceOrigin: Int] = [:]
        for position in slots.indices { index[slots[position].origin] = position }
        return index
    }

    private static func attach(_ source: ControlSourceID, of id: BindingID, to slots: inout [Slot],
                               index: [ControlSourceOrigin: Int]) throws(ControlInputBankRefusal) {
        let key: ControlSourceKey
        do throws(ControlFeedbackMIDI1Refusal) {
            key = try ControlFeedbackMIDI1SourceParser.parse(source)
        } catch {
            throw .unmappableSource(id)
        }
        guard let position = index[key.origin] else { throw .originNotLinked(id, key.origin) }
        slots[position].add(source)
    }

    private static func sorted(_ ids: [BindingID]) -> [BindingID] {
        ids.sorted { precedes($0, $1) }
    }

    private static func precedes(_ lhs: BindingID, _ rhs: BindingID) -> Bool {
        lhs.rawValue.utf8.lexicographicallyPrecedes(rhs.rawValue.utf8)
    }

    private static func sameOrigin(_ lhs: ControlSourceOrigin, _ rhs: ControlSourceOrigin) -> Bool {
        lhs.token.utf8.elementsEqual(rhs.token.utf8)
    }
}
