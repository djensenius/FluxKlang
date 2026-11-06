/// Which route received each sounding note-on and which input holds each pedal, so releases reach the route that
/// received the note-on whatever the current routing is. Nothing expires: only a release, the loss of the input or
/// the route, or a panic removes an entry. Storage is reserved up front and never grows past the policy.
///
/// A key-down press that loses every layer to `routeLost` or a route-scoped panic while a newer key-down press of the
/// same key is held leaves a release marker, so its own Note Off sends nothing instead of releasing that newer press
/// (`releaseMarkers`). A press that reached no route records nothing, so its Note Off can end the key's next press.
///
/// Every change goes through `route`, `panic`, `routeLost` and `inputLost`. The primitives they share are private to
/// this file: they keep the ledger's invariants only after their caller's capacity check.
///
/// Cost: one routed note, pedal or channel message is O(k · n) for k rules or layers over n held instances. Bulk
/// key-ups (CC 120, CC 123...127, `inputLost`) are O(n²): each key-up rescans the ledger for another key-down copy
/// and removes in place. `routeLost` and a route-scoped panic are O(n²) too: each lost key-down instance rescans the
/// notes for a layer that stays, and each marker for a newer press. The CC 121/124...127 preflight rescans the notes
/// and holds once per current rule (O(rules · (notes + holds))). All of this is control-side work, never for a
/// realtime thread; an indexed ledger is a follow-up.
struct MIDINoteLedger: Equatable, Sendable {
    /// Release velocity of synthesized note-offs (panic, loss, All Notes Off); MIDI 1.0's default.
    static let releaseVelocity: UInt8 = 64
    /// Pedal values 64...127 are down and 0...63 up, as for CC 64 in `MIDI1ChannelState`.
    static let pedalDownThreshold: UInt8 = 64
    /// Value of a pedal-down carried to a Note On's new route. The ledger treats pedals as on or off.
    static let carriedPedalValue: UInt8 = 127

    let policy: MIDINoteLedgerPolicy
    /// Arrival order, so the first key-down instance of an input note belongs to its oldest press.
    private(set) var notes: [MIDINoteInstance] = []
    /// Ascending by press and unique: lost key-down presses, each kept only while a newer key-down press of its key is
    /// (`markPressesLosingEveryLayer`). They share `policy.noteCapacity` with `notes`.
    private(set) var releaseMarkers: [MIDIReleaseMarker] = []
    /// Ascending and unique.
    private(set) var pedalHolds: [MIDIPedalHold] = []
    /// Private with no default value, so an initializer outside this file must delegate to `init(policy:)`, which
    /// reserves the storage that keeps routing allocation-free.
    private var nextPress: UInt64

    init(policy: MIDINoteLedgerPolicy = .standard) {
        self.policy = policy
        nextPress = 0
        notes.reserveCapacity(policy.noteCapacity)
        releaseMarkers.reserveCapacity(policy.noteCapacity)
        pedalHolds.reserveCapacity(policy.pedalCapacity)
    }

    /// The most outputs one routed event appends: All Sound Off releases every instance and hold, a pedal-down reaches
    /// each rule's route and each route holding a key, and a Note On sends one note-on and up to two carried pedals
    /// per rule. Reserve this to route without allocating.
    var maximumOutputsPerEvent: Int {
        policy.noteCapacity + policy.pedalCapacity + 3 * MIDIRouting.maximumRules
    }

    /// The destination pedal is down while any input holds it.
    func isPedalDown(_ pedal: MIDIPedal, route: MIDIRouteID, channel: UInt8) -> Bool {
        pedalHolds.contains { $0.route == route && $0.channel == channel && $0.pedal == pedal }
    }
}

// MARK: - Routing

/// The input, channel and routing table that one event is resolved against.
private struct MIDIRoutingContext {
    let input: MIDIInputID
    let channel: UInt8
    let routing: MIDIRouting

    func owns(_ instance: MIDINoteInstance) -> Bool {
        instance.input == input && instance.channel == channel
    }

    func owns(_ instance: MIDINoteInstance, inputNote: UInt8) -> Bool {
        owns(instance) && instance.inputNote == inputNote
    }

    func owns(_ hold: MIDIPedalHold) -> Bool {
        hold.input == input && hold.channel == channel
    }

    func owns(_ marker: MIDIReleaseMarker) -> Bool {
        marker.input == input && marker.channel == channel
    }

    func hold(_ pedal: MIDIPedal, on route: MIDIRouteID) -> MIDIPedalHold {
        MIDIPedalHold(route: route, channel: channel, pedal: pedal, input: input)
    }
}

extension MIDINoteLedger {
    /// Convenience over `route(_:routing:into:)`; allocates the returned array.
    mutating func route(
        _ event: MIDIPerformanceEvent, routing: MIDIRouting
    ) throws(MIDIPerformanceRefusal) -> [MIDIRoutedOutput] {
        var outputs: [MIDIRoutedOutput] = []
        try route(event, routing: routing, into: &outputs)
        return outputs
    }

    /// Routes one channel voice message and appends what to send. Note-ons, pedal-downs and channel messages follow
    /// `routing`; note-offs, pedal-ups and poly pressure follow the ledger, carrying the notes recorded at note-on.
    /// A refusal appends nothing and leaves the ledger unchanged. With `maximumOutputsPerEvent` reserved in a reused
    /// buffer, routing does not allocate.
    mutating func route(
        _ event: MIDIPerformanceEvent, routing: MIDIRouting, into outputs: inout [MIDIRoutedOutput]
    ) throws(MIDIPerformanceRefusal) {
        guard let channel = event.message.routedChannel else { throw .systemMessage }
        guard (1...UInt8(MIDI1PerformanceState.channelCount)).contains(channel), event.message.hasRoutableData else {
            throw .malformedEvent
        }
        let context = MIDIRoutingContext(input: event.input, channel: channel, routing: routing)
        switch event.message {
        case let .noteOn(_, note, velocity) where velocity > 0:
            try pressNote(note, velocity: velocity, context: context, into: &outputs)
        case let .noteOn(_, note, _):
            // Note On velocity 0 is Note Off with release velocity 64, as in `MIDI1Event.semantic`.
            try releaseOldestPress(of: note, velocity: Self.releaseVelocity, context: context, into: &outputs)
        case let .noteOff(_, note, velocity):
            try releaseOldestPress(of: note, velocity: velocity, context: context, into: &outputs)
        case let .polyphonicPressure(_, note, pressure):
            try sendPolyPressure(of: note, pressure: pressure, context: context, into: &outputs)
        case let .controlChange(_, controller, value):
            try applyController(controller, value: value, context: context, into: &outputs)
        default:
            forward(event.message, context: context, into: &outputs)
        }
    }

    /// Carries held pedals to the note's new routes, then sends one note-on per distinct (route, transformed note) of
    /// the matching rules, recorded as one press. Refused whole, before anything is sent, when the notes or the
    /// carried holds do not fit; release markers count toward the note capacity. A press of a key with release markers
    /// ends after them and after the held presses they order.
    private mutating func pressNote(
        _ note: UInt8, velocity: UInt8, context: MIDIRoutingContext, into outputs: inout [MIDIRoutedOutput]
    ) throws(MIDIPerformanceRefusal) {
        let start = outputs.count
        try carryHeldPedals(to: note, context: context, into: &outputs)
        let noteStart = outputs.count
        for rule in context.routing.rules where rule.matches(context.input, channel: context.channel) {
            guard let sent = rule.transposed(note) else { continue }
            let message = MIDI1Semantic.noteOn(channel: context.channel, note: sent, velocity: velocity)
            Self.appendOnce(MIDIRoutedOutput(route: rule.route, message: message), since: noteStart, to: &outputs)
        }
        guard notes.count + releaseMarkers.count + outputs.count - noteStart <= policy.noteCapacity else {
            outputs.removeSubrange(start...)
            throw .noteLedgerFull(input: context.input, channel: context.channel, note: note)
        }
        addHolds(outputs[start..<noteStart], context: context)
        recordPress(input: context.input, channel: context.channel, inputNote: note, sent: outputs[noteStart...])
    }

    /// A pedal this input holds down on this channel is first sent down (value 127) to each route the note will reach
    /// without that hold, so the note sustains like the notes before it and the pedal-up later releases that route
    /// too. Sustain, then sostenuto: a carried sostenuto captures nothing of this input, since its note-on follows.
    private func carryHeldPedals(
        to note: UInt8, context: MIDIRoutingContext, into outputs: inout [MIDIRoutedOutput]
    ) throws(MIDIPerformanceRefusal) {
        let start = outputs.count
        for pedal in MIDIPedal.allCases where pedalHolds.contains(where: { context.owns($0) && $0.pedal == pedal }) {
            let message = MIDI1Semantic.controlChange(
                channel: context.channel, controller: pedal.rawValue, value: Self.carriedPedalValue
            )
            for rule in context.routing.rules where rule.matches(context.input, channel: context.channel)
                && rule.transposed(note) != nil && !pedalHolds.contains(context.hold(pedal, on: rule.route)) {
                Self.appendOnce(MIDIRoutedOutput(route: rule.route, message: message), since: start, to: &outputs)
            }
            guard pedalHolds.count + outputs.count - start <= policy.pedalCapacity else {
                outputs.removeSubrange(start...)
                throw .pedalLedgerFull(input: context.input, channel: context.channel, pedal: pedal)
            }
        }
    }

    /// Ends the oldest pending press of the input note (FIFO for duplicates). A release marker older than every
    /// key-down press of the note is consumed and sends nothing, so newer presses keep sounding; otherwise the oldest
    /// key-down press is released on every route it reached.
    private mutating func releaseOldestPress(
        of note: UInt8, velocity: UInt8, context: MIDIRoutingContext, into outputs: inout [MIDIRoutedOutput]
    ) throws(MIDIPerformanceRefusal) {
        let oldest = notes.first(where: { $0.keyDown && context.owns($0, inputNote: note) })
        if let marker = releaseMarkers.firstIndex(where: { context.owns($0) && $0.inputNote == note }),
           oldest.map({ releaseMarkers[marker].press < $0.press }) ?? true {
            releaseMarkers.remove(at: marker)
            return
        }
        guard let oldest else {
            throw .unownedNote(input: context.input, channel: context.channel, note: note)
        }
        releaseKeys(velocity: velocity, into: &outputs) { $0.press == oldest.press }
    }

    /// Poly pressure belongs to the key, so it follows the newest key-down press of the input note. Release markers
    /// sound nothing and are skipped.
    private func sendPolyPressure(
        of note: UInt8, pressure: UInt8, context: MIDIRoutingContext, into outputs: inout [MIDIRoutedOutput]
    ) throws(MIDIPerformanceRefusal) {
        guard let newest = notes.last(where: { $0.keyDown && context.owns($0, inputNote: note) }) else {
            throw .unownedNote(input: context.input, channel: context.channel, note: note)
        }
        for instance in notes where instance.keyDown && instance.press == newest.press {
            let message = MIDI1Semantic.polyphonicPressure(
                channel: instance.channel, note: instance.note, pressure: pressure
            )
            outputs.append(MIDIRoutedOutput(route: instance.route, message: message))
        }
    }

    /// Pedals and the note-releasing channel mode messages resolve through the ledger, scoped to this input and
    /// channel. Receiver-wide messages never reach a destination where another input owns something: raw CC 120 and
    /// 123 are not forwarded at all (the ledger releases this input's keys, and for CC 120 its pedals, instead), and
    /// CC 121 and 124...127, which must be forwarded, are refused whole before any change when a current route on this
    /// channel carries another input's notes or holds (`.sharedDestinationOwned`, after `.systemMessage` and
    /// `.malformedEvent`; these controllers have no other refusal). The preflight assumes the destination applies
    /// these messages to that one channel; an omni-mode receiver may apply them more widely, which a per-channel check
    /// cannot see (follow-up: receiver mode in #81/#66 routing metadata).
    private mutating func applyController(
        _ controller: UInt8, value: UInt8, context: MIDIRoutingContext, into outputs: inout [MIDIRoutedOutput]
    ) throws(MIDIPerformanceRefusal) {
        let message = MIDI1Semantic.controlChange(channel: context.channel, controller: controller, value: value)
        if let pedal = MIDIPedal(rawValue: controller) {
            guard value >= Self.pedalDownThreshold else {
                guard pedalHolds.contains(where: { context.owns($0) && $0.pedal == pedal }) else {
                    throw .unownedPedal(input: context.input, channel: context.channel, pedal: pedal)
                }
                // The ledger's pedals are binary, so the first value below 64 is a full release: send 0, never the
                // received half-pedal value, which would leave a continuous-pedal destination partly down. Later
                // values below 64 from this input and channel are refused as `.unownedPedal`.
                releaseHolds(value: 0, into: &outputs) { context.owns($0) && $0.pedal == pedal }
                return
            }
            try pressPedal(pedal, message: message, context: context, into: &outputs)
            return
        }
        switch controller {
        case 120:
            // All Sound Off: release this input's keys and drop its release markers, then release its pedals.
            releaseKeys(velocity: Self.releaseVelocity, into: &outputs) { context.owns($0) }
            releaseMarkers.removeAll { context.owns($0) }
            releaseHolds(value: 0, into: &outputs) { context.owns($0) }
        case 121:
            // Reset All Controllers releases this input's pedals; its other resets go to the current routes.
            try refuseSharedDestination(controller, context: context)
            releaseHolds(value: 0, into: &outputs) { context.owns($0) }
            forward(message, context: context, into: &outputs)
        case 123:
            // All Notes Off respects the pedals like Note Off.
            releaseKeys(velocity: Self.releaseVelocity, into: &outputs) { context.owns($0) }
            releaseMarkers.removeAll { context.owns($0) }
        case 124...127:
            // Omni and mono/poly mode imply All Notes Off through the ledger; the mode goes to the current routes.
            // Release markers are dropped only once the message is accepted.
            try refuseSharedDestination(controller, context: context)
            releaseKeys(velocity: Self.releaseVelocity, into: &outputs) { context.owns($0) }
            forward(message, context: context, into: &outputs)
            releaseMarkers.removeAll { context.owns($0) }
        default:
            forward(message, context: context, into: &outputs)
        }
    }

    /// Pedal-down reaches each current route and each route still holding a key of this input and channel, so a
    /// note left on an old route sustains too. Refused whole, before anything is sent, when the holds do not fit.
    private mutating func pressPedal(
        _ pedal: MIDIPedal, message: MIDI1Semantic, context: MIDIRoutingContext,
        into outputs: inout [MIDIRoutedOutput]
    ) throws(MIDIPerformanceRefusal) {
        let start = outputs.count
        for rule in context.routing.rules where rule.matches(context.input, channel: context.channel) {
            Self.appendOnce(MIDIRoutedOutput(route: rule.route, message: message), since: start, to: &outputs)
        }
        for instance in notes where instance.keyDown && context.owns(instance) {
            Self.appendOnce(MIDIRoutedOutput(route: instance.route, message: message), since: start, to: &outputs)
        }
        let added = outputs[start...].reduce(0) { count, output in
            pedalHolds.contains(context.hold(pedal, on: output.route)) ? count : count + 1
        }
        guard pedalHolds.count + added <= policy.pedalCapacity else {
            outputs.removeSubrange(start...)
            throw .pedalLedgerFull(input: context.input, channel: context.channel, pedal: pedal)
        }
        addHolds(outputs[start...], context: context)
    }

    /// Preflight for the forwarded receiver-wide messages (CC 121, 124...127): throws for the first current route in
    /// rule order where another input has a note (key-down, sustained or sostenuto-held) or a pedal hold on this
    /// channel, naming the lowest such input. Changes nothing; ownership-safe translation is a follow-up.
    private func refuseSharedDestination(
        _ controller: UInt8, context: MIDIRoutingContext
    ) throws(MIDIPerformanceRefusal) {
        for rule in context.routing.rules where rule.matches(context.input, channel: context.channel) {
            guard let owner = otherOwner(on: rule.route, context: context) else { continue }
            throw .sharedDestinationOwned(
                input: context.input, channel: context.channel, controller: controller, route: rule.route, owner: owner
            )
        }
    }

    private func otherOwner(on route: MIDIRouteID, context: MIDIRoutingContext) -> MIDIInputID? {
        let owns = { (owner: MIDIInputID, owned: MIDIRouteID, channel: UInt8) in
            owner != context.input && owned == route && channel == context.channel
        }
        let noteOwner = notes.lazy.filter { owns($0.input, $0.route, $0.channel) }.map(\.input).min()
        let holdOwner = pedalHolds.lazy.filter { owns($0.input, $0.route, $0.channel) }.map(\.input).min()
        guard let noteOwner else { return holdOwner }
        return min(noteOwner, holdOwner ?? noteOwner)
    }

    /// Channel messages go to each current route once.
    private func forward(
        _ message: MIDI1Semantic, context: MIDIRoutingContext, into outputs: inout [MIDIRoutedOutput]
    ) {
        let start = outputs.count
        for rule in context.routing.rules where rule.matches(context.input, channel: context.channel) {
            Self.appendOnce(MIDIRoutedOutput(route: rule.route, message: message), since: start, to: &outputs)
        }
    }

    private static func appendOnce(_ output: MIDIRoutedOutput, since start: Int, to outputs: inout [MIDIRoutedOutput]) {
        guard !outputs[start...].contains(output) else { return }
        outputs.append(output)
    }
}

// MARK: - Loss and panic

extension MIDINoteLedger {
    /// Returns `panicPlan(scope, allNotesAndSoundOff:)` and forgets everything in `scope`, so a second panic emits
    /// nothing until a new note-on or pedal-down. A full panic also drops every release marker, so a key or pedal
    /// released after it is refused as unowned. A route-scoped panic marks and prunes as `routeLost` does.
    mutating func panic(_ scope: MIDIPanicScope = .all, allNotesAndSoundOff: Bool = true) -> [MIDIRoutedOutput] {
        let outputs = panicPlan(scope, allNotesAndSoundOff: allNotesAndSoundOff)
        if scope == .all {
            releaseMarkers.removeAll(keepingCapacity: true)
        } else {
            markPressesLosingEveryLayer { scope.contains($0.route) }
        }
        forget(notesWhere: { scope.contains($0.route) }, holdsWhere: { scope.contains($0.route) })
        return outputs
    }

    /// Removes the route's instances and holds and reports them; nothing is sent. Later releases and panics no
    /// longer target the route. A key-down press with no layer left keeps its place in its key's release FIFO as a
    /// release marker while a newer key-down press of the key is held; markers left ordering nothing are dropped.
    mutating func routeLost(_ route: MIDIRouteID) -> MIDIOrphanedRoute {
        let orphaned = MIDIOrphanedRoute(
            route: route, notes: notes.filter { $0.route == route }, pedalHolds: pedalHolds.filter { $0.route == route }
        )
        markPressesLosingEveryLayer { $0.route == route }
        forget(notesWhere: { $0.route == route }, holdsWhere: { $0.route == route })
        return orphaned
    }

    /// The input is gone: key-up for each of its key-down instances on its recorded routes (arrival order), then its
    /// pedal holds (ascending; a pedal goes up with its last holder). Its release markers go too. Notes another
    /// input's pedal sustains stay.
    mutating func inputLost(_ input: MIDIInputID) -> [MIDIRoutedOutput] {
        var outputs: [MIDIRoutedOutput] = []
        releaseKeys(velocity: Self.releaseVelocity, into: &outputs) { $0.input == input }
        releaseMarkers.removeAll { $0.input == input }
        releaseHolds(value: 0, into: &outputs) { $0.input == input }
        return outputs
    }
}

// MARK: - Primitives (private: each relies on its caller's capacity check)

extension MIDINoteLedger {
    /// Records one press: a key-down instance for each note-on in `sent`, all sharing a new press number.
    private mutating func recordPress(
        input: MIDIInputID, channel: UInt8, inputNote: UInt8, sent: ArraySlice<MIDIRoutedOutput>
    ) {
        guard !sent.isEmpty else { return }
        for output in sent {
            guard case let .noteOn(_, note, _) = output.message else { continue }
            notes.append(MIDINoteInstance(
                press: nextPress, input: input, channel: channel, inputNote: inputNote, route: output.route, note: note
            ))
        }
        nextPress &+= 1
    }

    /// Adds this input's hold for each pedal-down in `sent`, in order.
    private mutating func addHolds(_ sent: ArraySlice<MIDIRoutedOutput>, context: MIDIRoutingContext) {
        for output in sent {
            guard case let .controlChange(_, controller, _) = output.message,
                  let pedal = MIDIPedal(rawValue: controller) else { continue }
            addHold(context.hold(pedal, on: output.route))
        }
    }

    /// Adds `hold` unless present. The destination's first sostenuto hold captures the notes key-down there now.
    private mutating func addHold(_ hold: MIDIPedalHold) {
        let index = pedalHolds.firstIndex { !($0 < hold) } ?? pedalHolds.endIndex
        guard index == pedalHolds.endIndex || pedalHolds[index] != hold else { return }
        if hold.pedal == .sostenuto, !isPedalDown(.sostenuto, route: hold.route, channel: hold.channel) {
            for noteIndex in notes.indices where notes[noteIndex].keyDown
                && notes[noteIndex].route == hold.route && notes[noteIndex].channel == hold.channel {
                notes[noteIndex].sostenuto = true
            }
        }
        pedalHolds.insert(hold, at: index)
    }

    /// Key-up of every key-down instance `matching`, in arrival order. O(n²) when many match (see the type).
    private mutating func releaseKeys(
        velocity: UInt8, into outputs: inout [MIDIRoutedOutput], matching predicate: (MIDINoteInstance) -> Bool
    ) {
        var index = notes.startIndex
        while index < notes.endIndex {
            if notes[index].keyDown, predicate(notes[index]),
               releaseKey(at: index, velocity: velocity, into: &outputs) {
                continue
            }
            index += 1
        }
    }

    /// Removes the holds `matching`. A destination pedal goes up, and `value` is sent, only with its last holder.
    private mutating func releaseHolds(
        value: UInt8, into outputs: inout [MIDIRoutedOutput], matching predicate: (MIDIPedalHold) -> Bool
    ) {
        var index = pedalHolds.startIndex
        while index < pedalHolds.endIndex {
            let hold = pedalHolds[index]
            guard predicate(hold) else {
                index += 1
                continue
            }
            pedalHolds.remove(at: index)
            guard !isPedalDown(hold.pedal, route: hold.route, channel: hold.channel) else { continue }
            let message = MIDI1Semantic.controlChange(
                channel: hold.channel, controller: hold.pedal.rawValue, value: value
            )
            outputs.append(MIDIRoutedOutput(route: hold.route, message: message))
            destinationPedalUp(hold.pedal, route: hold.route, channel: hold.channel)
        }
    }

    /// Drops entries without sending anything: a panic has planned their release, or their route is gone.
    private mutating func forget(
        notesWhere notePredicate: (MIDINoteInstance) -> Bool, holdsWhere holdPredicate: (MIDIPedalHold) -> Bool
    ) {
        notes.removeAll(where: notePredicate)
        pedalHolds.removeAll(where: holdPredicate)
    }

    /// Before `forget`, keeps each key's release order across the loss of the instances `lost`. A release marker stays,
    /// and a key-down press whose every layer is lost becomes one (in press order), only while a newer key-down press
    /// of its key keeps a layer. Nothing else strands a marker: a Note Off ends its key's oldest entry; CC 120,
    /// 123...127, `inputLost` and a full panic drop it with the presses. Each replaces a forgotten instance.
    private mutating func markPressesLosingEveryLayer(_ lost: (MIDINoteInstance) -> Bool) {
        let notes = notes
        releaseMarkers.removeAll { marker in !notes.contains { marker.orders($0) && !lost($0) } }
        for instance in notes where instance.keyDown && lost(instance)
            && !notes.contains(where: { $0.press == instance.press && !lost($0) }) {
            let marker = MIDIReleaseMarker(of: instance)
            let index = releaseMarkers.firstIndex { $0.press >= instance.press } ?? releaseMarkers.endIndex
            guard index == releaseMarkers.endIndex || releaseMarkers[index].press != instance.press,
                  notes.contains(where: { marker.orders($0) && !lost($0) }) else { continue }
            releaseMarkers.insert(marker, at: index)
        }
    }

    /// Key-up of one instance. Returns true when it was removed because no pedal holds it. The note-off is sent
    /// only when no other key-down instance still sounds the same note on the same route and channel.
    private mutating func releaseKey(at index: Int, velocity: UInt8, into outputs: inout [MIDIRoutedOutput]) -> Bool {
        let released = notes[index]
        let sustained = isPedalDown(.sustain, route: released.route, channel: released.channel)
        let removed = !sustained && !released.sostenuto
        if removed {
            notes.remove(at: index)
        } else {
            notes[index].keyDown = false
            notes[index].sustained = sustained
        }
        let stillDown = notes.contains {
            $0.keyDown && $0.route == released.route && $0.channel == released.channel && $0.note == released.note
        }
        if !stillDown {
            let message = MIDI1Semantic.noteOff(channel: released.channel, note: released.note, velocity: velocity)
            outputs.append(MIDIRoutedOutput(route: released.route, message: message))
        }
        return removed
    }

    /// The last hold of a destination pedal is gone: notes it alone was holding on that route and channel end.
    /// Other routes and channels keep their pedals. A key-up note the sostenuto releases while the sustain pedal is
    /// down there passes to the sustain (as the destination keeps it sounding) and ends with the sustain's last holder;
    /// a sustain release likewise leaves a sostenuto-held note until the sostenuto goes up.
    private mutating func destinationPedalUp(_ pedal: MIDIPedal, route: MIDIRouteID, channel: UInt8) {
        let sustainDown = isPedalDown(.sustain, route: route, channel: channel)
        for index in notes.indices where notes[index].route == route && notes[index].channel == channel {
            switch pedal {
            case .sustain: notes[index].sustained = false
            case .sostenuto:
                if sustainDown, !notes[index].keyDown { notes[index].sustained = true }
                notes[index].sostenuto = false
            }
        }
        notes.removeAll { !$0.keyDown && !$0.sustained && !$0.sostenuto }
    }
}
