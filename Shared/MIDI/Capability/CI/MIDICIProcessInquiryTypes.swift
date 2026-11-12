/// Sub-id 2 of the Process Inquiry messages handled by `MIDICIProcessInquiryMessage`.
enum MIDICIProcessInquiryKind: UInt8, Sendable {
    case capabilitiesInquiry = 0x40
    case capabilitiesReply = 0x41
    case messageReportInquiry = 0x42
    case messageReportReply = 0x43
    case messageReportEnd = 0x44

    /// The exact length of the payload (F0 and F7 excluded): the 13-byte header and the body of the kind.
    var payloadBytes: Int {
        switch self {
        case .capabilitiesInquiry: return MIDICIProcessInquiryMessage.capabilitiesInquiryBytes
        case .capabilitiesReply: return MIDICIProcessInquiryMessage.capabilitiesReplyBytes
        case .messageReportInquiry: return MIDICIProcessInquiryMessage.messageReportInquiryBytes
        case .messageReportReply: return MIDICIProcessInquiryMessage.messageReportReplyBytes
        case .messageReportEnd: return MIDICIProcessInquiryMessage.messageReportEndBytes
        }
    }
}

// The four bitmaps below drop every reserved bit in `init(rawValue:)`, and every `OptionSet` operation (insert,
// union, array literal and the rest) builds its result through that initialiser. A value therefore never carries
// a reserved bit: decode ignores one set on the wire and encode writes 0 (M2-101-UM v1.2, Tables 42, 43 and 45).

/// The Process Inquiry Supported Features of a Reply to Process Inquiry Capabilities (Table 42): D0 MIDI Message
/// Report. D1 to D6 are reserved, and no message uses them yet.
struct MIDICIProcessInquiryFeatures: OptionSet, Hashable, Sendable {
    static let midiMessageReport = MIDICIProcessInquiryFeatures(rawValue: 0x01)

    private static let definedBits: UInt8 = 0x01

    let rawValue: UInt8

    init(rawValue: UInt8) {
        self.rawValue = rawValue & Self.definedBits
    }
}

/// The System Messages bitmap of a MIDI Message Report Inquiry and its Reply (Tables 43 and 45). D3 to D7 are
/// reserved.
struct MIDICIReportSystemMessages: OptionSet, Hashable, Sendable {
    static let mtcQuarterFrame = MIDICIReportSystemMessages(rawValue: 0x01)
    static let songPosition = MIDICIReportSystemMessages(rawValue: 0x02)
    static let songSelect = MIDICIReportSystemMessages(rawValue: 0x04)

    private static let definedBits: UInt8 = 0x07

    let rawValue: UInt8

    init(rawValue: UInt8) {
        self.rawValue = rawValue & Self.definedBits
    }
}

/// The Channel Controller Messages bitmap (Tables 43 and 45). D6 and D7 are reserved.
struct MIDICIReportChannelControllers: OptionSet, Hashable, Sendable {
    static let pitchbend = MIDICIReportChannelControllers(rawValue: 0x01)
    static let controlChange = MIDICIReportChannelControllers(rawValue: 0x02)
    /// RPN (Registered Controller).
    static let registeredController = MIDICIReportChannelControllers(rawValue: 0x04)
    /// NRPN (Assignable Controller).
    static let assignableController = MIDICIReportChannelControllers(rawValue: 0x08)
    static let programChange = MIDICIReportChannelControllers(rawValue: 0x10)
    static let channelPressure = MIDICIReportChannelControllers(rawValue: 0x20)

    private static let definedBits: UInt8 = 0x3F

    let rawValue: UInt8

    init(rawValue: UInt8) {
        self.rawValue = rawValue & Self.definedBits
    }
}

/// The Note Data Messages bitmap (Tables 43 and 45). D5 to D7 are reserved.
struct MIDICIReportNoteData: OptionSet, Hashable, Sendable {
    static let notes = MIDICIReportNoteData(rawValue: 0x01)
    static let polyPressure = MIDICIReportNoteData(rawValue: 0x02)
    static let perNotePitchbend = MIDICIReportNoteData(rawValue: 0x04)
    static let registeredPerNoteController = MIDICIReportNoteData(rawValue: 0x08)
    static let assignablePerNoteController = MIDICIReportNoteData(rawValue: 0x10)

    private static let definedBits: UInt8 = 0x1F

    let rawValue: UInt8

    init(rawValue: UInt8) {
        self.rawValue = rawValue & Self.definedBits
    }
}

/// The Message Data Control byte of an Inquiry: MIDI Message Report, how much the Responder reports (section 9.5.1,
/// Table 44): 0x00 asks for the Begin and End replies only, 0x01 for the controllers with non-default values and the
/// active notes, 0x7F for everything. 0x02 to 0x7E are reserved. Any 7-bit value is kept as received, not refused, as
/// `MIDICIEndpointStatus` keeps an unknown status: `isReserved` tells a reserved value from a defined one, and
/// whether to act on it is the caller's decision.
struct MIDICIReportDataControl: Equatable, Hashable, Sendable {
    static let beginEndOnly = MIDICIReportDataControl(validated: 0x00)
    static let nonDefaultValues = MIDICIReportDataControl(validated: 0x01)
    static let full = MIDICIReportDataControl(validated: 0x7F)

    private let storage: UInt8

    var rawValue: UInt8 { storage }
    /// True for 0x02 to 0x7E, the values Table 44 reserves.
    var isReserved: Bool { (0x02...0x7E).contains(storage) }

    private init(validated storage: UInt8) {
        self.storage = storage
    }

    static func make(_ raw: UInt8) throws(MIDICIRefusal) -> MIDICIReportDataControl {
        guard raw < 0x80 else { throw .fieldOutOfRange(.dataControl, value: Int(raw)) }
        return MIDICIReportDataControl(validated: raw)
    }
}

/// The three bitmaps of an Inquiry: MIDI Message Report and of its Reply (Tables 43 and 45): the System Messages, the
/// Channel Controller Messages and the Note Data Messages. The reserved byte between the System Messages and the
/// Channel Controller bitmaps is not stored: decode ignores it and encode writes 0x00.
struct MIDICIReportSelection: Equatable, Hashable, Sendable {
    /// Bytes on the wire: the System Messages bitmap, the reserved byte, the Channel Controller bitmap and the Note
    /// Data bitmap.
    static let wireByteCount = 4

    var system: MIDICIReportSystemMessages = []
    var channelControllers: MIDICIReportChannelControllers = []
    var noteData: MIDICIReportNoteData = []

    /// The four bytes as they are written, the reserved byte as 0x00.
    var wireBytes: [UInt8] {
        [system.rawValue, 0x00, channelControllers.rawValue, noteData.rawValue]
    }

    /// Reads the four bytes; the reserved byte is skipped whatever it holds.
    static func read(_ reader: inout MIDICIReader) throws(MIDICIRefusal) -> MIDICIReportSelection {
        let system = try reader.byte()
        _ = try reader.byte()
        let channelControllers = try reader.byte()
        let noteData = try reader.byte()
        return MIDICIReportSelection(
            system: MIDICIReportSystemMessages(rawValue: system),
            channelControllers: MIDICIReportChannelControllers(rawValue: channelControllers),
            noteData: MIDICIReportNoteData(rawValue: noteData))
    }
}
