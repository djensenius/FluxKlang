/// Capacity of one note ledger. Both bounds fail closed: work that does not fit is refused before anything is sent.
/// Only the validating initializer builds one; the capacities are read-only.
struct MIDINoteLedgerPolicy: Hashable, Sendable {
    static let noteCapacityBounds = 1...4096
    static let pedalCapacityBounds = 1...1024
    static let standard = MIDINoteLedgerPolicy(validatedNoteCapacity: 1024, pedalCapacity: 256)

    /// Note-on instances (one per layer of each press) that are still held by a key or a pedal, plus release markers
    /// (one per lost key-down press whose Note Off is still to come; see `MIDINoteLedger.releaseMarkers`).
    var noteCapacity: Int { storedNoteCapacity }
    /// Pedal holds, one per (route, channel, pedal, input).
    var pedalCapacity: Int { storedPedalCapacity }

    // Private `let` storage behind get-only accessors: only this file's initializers can set it, so an initializer
    // in an extension elsewhere cannot skip the validation, and nothing changes it afterwards.
    private let storedNoteCapacity: Int
    private let storedPedalCapacity: Int

    init?(noteCapacity: Int = 1024, pedalCapacity: Int = 256) {
        guard Self.noteCapacityBounds.contains(noteCapacity),
              Self.pedalCapacityBounds.contains(pedalCapacity) else { return nil }
        self.init(validatedNoteCapacity: noteCapacity, pedalCapacity: pedalCapacity)
    }

    private init(validatedNoteCapacity noteCapacity: Int, pedalCapacity: Int) {
        storedNoteCapacity = noteCapacity
        storedPedalCapacity = pedalCapacity
    }
}

/// Every refusal appends no output and leaves the ledger unchanged. Channels are 1...16.
enum MIDIPerformanceRefusal: Error, Equatable, Hashable, Sendable {
    /// A channel outside 1...16, a data byte above 127 or a pitch bend above 16_383.
    case malformedEvent
    /// System messages are not routed by the note ledger.
    case systemMessage
    /// Recording every layer of this Note On would exceed the note capacity, which release markers share; nothing was
    /// sent. A marker's entry is freed by its Note Off, CC 120 or 123...127 of its input and channel, the loss of its
    /// input, or a full panic.
    case noteLedgerFull(input: MIDIInputID, channel: UInt8, note: UInt8)
    /// Recording this pedal-down on every target, or carrying a held pedal to a Note On's new routes, would exceed the
    /// pedal capacity; nothing was sent.
    case pedalLedgerFull(input: MIDIInputID, channel: UInt8, pedal: MIDIPedal)
    /// A Note Off (or Note On with velocity 0) or poly pressure for a note this input has no key down on, on this
    /// channel. Benign and frequent in normal playing: poly aftertouch trailing a Note Off, a key released after a
    /// full panic or after its input was lost, a repeated Note Off. Callers count or log it; it is not an error.
    /// A Note Off held back because another copy of the note is still down is not refused, nor is the first Note Off
    /// of a press whose route was lost or panicked: its release marker takes it, sending nothing.
    case unownedNote(input: MIDIInputID, channel: UInt8, note: UInt8)
    /// A pedal-up (value 0...63) from an input that holds that pedal on no route on this channel. Benign and frequent,
    /// as above: a continuous pedal sends many values below 64, and only the first releases. Count or log it.
    /// A pedal-up held back because another input still holds the pedal is not refused.
    case unownedPedal(input: MIDIInputID, channel: UInt8, pedal: MIDIPedal)
    /// CC 121 (Reset All Controllers) or CC 124...127 (omni and mono/poly mode, which imply All Notes Off) would reach
    /// `route` on this channel, where `owner` (another input) still has a key down, a sustained or sostenuto-held
    /// note, or a pedal hold. The receiver would reset that input's pedals or end its notes while the ledger still
    /// records them, so the whole message is refused before anything changes. `route` is the first such current
    /// route in rule order; `owner` the lowest other input owning something there. Not benign: the reset did not
    /// happen; the caller may retry once that ownership has ended.
    case sharedDestinationOwned(
        input: MIDIInputID, channel: UInt8, controller: UInt8, route: MIDIRouteID, owner: MIDIInputID
    )
}
