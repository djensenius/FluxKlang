/// The 4-bit Message Type (MT) in the top nibble of a packet's first word.
///
/// Word counts follow the Message Type allocation table of MMA/AMEI M2-104-UM "Universal MIDI Packet (UMP) Format
/// and MIDI 2.0 Protocol", cross-checked against Apple CoreMIDI `MIDIMessages.h`: MT 0x0, 0x1, 0x2, 0x6, 0x7 are
/// 32-bit packets; 0x3, 0x4, 0x8, 0x9, 0xA are 64-bit; 0xB, 0xC are 96-bit; 0x5, 0xD, 0xE, 0xF are 128-bit. Reserved
/// types keep their size so a receiver can skip them.
enum UMPMessageType: UInt8, CaseIterable, Equatable, Sendable {
    case utility = 0x0
    case system = 0x1
    case midi1ChannelVoice = 0x2
    case data64 = 0x3
    case midi2ChannelVoice = 0x4
    case data128 = 0x5
    case reserved6 = 0x6
    case reserved7 = 0x7
    case reserved8 = 0x8
    case reserved9 = 0x9
    case reservedA = 0xA
    case reservedB = 0xB
    case reservedC = 0xC
    case flexData = 0xD
    case reservedE = 0xE
    case stream = 0xF

    /// The type of the packet that starts with this word.
    init(firstWord: UInt32) {
        // Four bits always name one of the sixteen cases.
        self = Self.allCases[Int(firstWord >> 28)]
    }

    /// Packet length in 32-bit words.
    var wordCount: Int {
        switch self {
        case .utility, .system, .midi1ChannelVoice, .reserved6, .reserved7:
            return 1
        case .data64, .midi2ChannelVoice, .reserved8, .reserved9, .reservedA:
            return 2
        case .reservedB, .reservedC:
            return 3
        case .data128, .flexData, .reservedE, .stream:
            return 4
        }
    }

    /// True for types with no defined messages; their packets pass through as opaque words.
    var isReserved: Bool {
        switch self {
        case .reserved6, .reserved7, .reserved8, .reserved9, .reservedA, .reservedB, .reservedC, .reservedE:
            return true
        default:
            return false
        }
    }

    /// True for types whose second nibble is a Group (MT 0x1...0x5 and 0xD; media-contract §9.3, M2-104-UM).
    /// MT 0x0 and 0xF are groupless; reserved types are not claimed to carry one.
    var carriesGroup: Bool {
        switch self {
        case .system, .midi1ChannelVoice, .data64, .midi2ChannelVoice, .data128, .flexData:
            return true
        default:
            return false
        }
    }
}
