/// One routing rule: channel voice messages from `input` on `channels` go to `route` on the same channel. A note also
/// needs to be in `notes` (a split), and is sent transposed by `transpose` semitones; a transposed note outside
/// 0...127 is not sent to this route. Several rules matching one note form a layer. Only the validating initializer
/// builds one; the fields are read-only.
struct MIDIRoutingRule: Hashable, Sendable {
    static let transposeBounds = -127...127

    var input: MIDIInputID { storedInput }
    var route: MIDIRouteID { storedRoute }
    var channels: ClosedRange<UInt8> { storedChannels }
    var notes: ClosedRange<UInt8> { storedNotes }
    var transpose: Int { storedTranspose }

    // Private `let` storage behind get-only accessors: only this file's initializers can set it, so an initializer
    // in an extension elsewhere cannot skip the validation, and nothing changes it afterwards.
    private let storedInput: MIDIInputID
    private let storedRoute: MIDIRouteID
    private let storedChannels: ClosedRange<UInt8>
    private let storedNotes: ClosedRange<UInt8>
    private let storedTranspose: Int

    /// Refuses channels outside 1...16, notes above 127 and transpositions outside `transposeBounds`.
    init?(
        input: MIDIInputID, route: MIDIRouteID, channels: ClosedRange<UInt8> = 1...16,
        notes: ClosedRange<UInt8> = 0...127, transpose: Int = 0
    ) {
        guard channels.lowerBound >= 1, channels.upperBound <= UInt8(MIDI1PerformanceState.channelCount),
              notes.upperBound <= 0x7F, Self.transposeBounds.contains(transpose) else { return nil }
        storedInput = input
        storedRoute = route
        storedChannels = channels
        storedNotes = notes
        storedTranspose = transpose
    }

    func matches(_ input: MIDIInputID, channel: UInt8) -> Bool {
        self.input == input && channels.contains(channel)
    }

    /// The note this rule sends for `note`, or nil outside its split or outside the MIDI note range.
    func transposed(_ note: UInt8) -> UInt8? {
        guard notes.contains(note) else { return nil }
        let sent = Int(note) + transpose
        return (0...0x7F).contains(sent) ? UInt8(sent) : nil
    }
}

/// The caller's current routing table. Rule order is output order. Replacing the table only affects new note-ons,
/// pedal-downs and channel messages; releases follow the ledger. Only the validating initializer builds one.
struct MIDIRouting: Equatable, Sendable {
    static let maximumRules = 64
    static let empty = MIDIRouting(validated: [])

    var rules: [MIDIRoutingRule] { storedRules }

    // Private `let` storage, for the reason given on `MIDIRoutingRule`.
    private let storedRules: [MIDIRoutingRule]

    /// Refuses more than `maximumRules` rules.
    init?(rules: [MIDIRoutingRule]) {
        guard rules.count <= Self.maximumRules else { return nil }
        self.init(validated: rules)
    }

    private init(validated rules: [MIDIRoutingRule]) {
        storedRules = rules
    }
}

/// One channel voice message from one input.
struct MIDIPerformanceEvent: Equatable, Sendable {
    let input: MIDIInputID
    let message: MIDI1Semantic
}

/// One message to send to one route. The channel is the input channel; notes are the transformed notes.
struct MIDIRoutedOutput: Equatable, Sendable {
    let route: MIDIRouteID
    let message: MIDI1Semantic
}
