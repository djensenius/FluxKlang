/// Who a Flex Data message is for: word 0 bits 21...20 (address) and 19...16 (channel).
enum UMPFlexDataAddress: Equatable, Sendable {
    /// Address 0: one channel of the group.
    case channel(UMPChannel)
    /// Address 1: the whole group. The channel nibble is ignored on decode and encoded as 0.
    case group
}

/// The Set Key Signature tonic, word 1 bits 27...24. The nibbles 8...15 name no note and are refused.
/// 0 is "Unknown" in the MIDI 2.0 Workbench and `NonStandard` in bl-midi2-rs. The Workbench lists 1...6 as A...F and
/// has no entry for 7; 7 = G follows bl-midi2-rs.
enum UMPFlexDataTonic: UInt8, CaseIterable, Equatable, Sendable {
    /// 0: a non-standard or unknown tonic.
    case nonStandard = 0
    case noteA = 1
    case noteB = 2
    case noteC = 3
    case noteD = 4
    case noteE = 5
    case noteF = 6
    case noteG = 7
}

/// The three bytes of a Set Time Signature message. Every byte value is accepted: no source checked limits them.
struct UMPFlexDataTimeSignature: Equatable, Sendable {
    /// Word 1 bits 31...24.
    let numerator: UInt8
    /// Word 1 bits 23...16: the beat note as a negative power of two (2 is a quarter note, 3 an eighth note).
    let denominatorExponent: UInt8
    /// Word 1 bits 15...8: the number of 1/32 notes.
    let thirtySecondNotes: UInt8
}

/// The two nibbles of a Set Key Signature message, and the only place their word 1 layout is defined.
///
/// Word 1: bits 31...28 sharps/flats (signed nibble), bits 27...24 tonic, bits 23...0 reserved. This nibble layout
/// follows the MIDI 2.0 Workbench (`libs/messageTypes.js`), ALSA alsa-lib `ump_msg.h`, bl-midi2-rs and ni-midi2.
/// cmidi2 and AM_MIDI2.0Lib's key signature helpers write two bytes instead (bits 31...24 and 23...16); that form is
/// refused when its tonic byte is non-zero, misread when the tonic byte is zero and sharps/flats is 0...7, and
/// refused (tonic nibble 8...15) when the tonic byte is zero and sharps/flats is negative. Not checked against the
/// M2-104-UM text.
struct UMPFlexDataKeySignature: Equatable, Sendable {
    /// The bits of word 1 that carry no field and must be zero.
    static let reservedWord1Mask: UInt32 = 0x00FF_FFFF

    /// 1...7 sharps, -1...-7 flats, 0 none. -8 (nibble 0x8) is a non-standard key, following bl-midi2-rs
    /// `SharpsFlats::NonStandard`; no other source or spec text checked confirms it.
    let sharpsOrFlats: Int8
    let tonic: UMPFlexDataTonic

    /// Refuses a sharps/flats count outside the signed 4-bit range -8...7.
    init(sharpsOrFlats: Int8, tonic: UMPFlexDataTonic) throws(UMPFlexDataRefusal) {
        guard (-8...7).contains(sharpsOrFlats) else {
            throw .invalidField(.sharpsOrFlats, value: Int(sharpsOrFlats))
        }
        self.sharpsOrFlats = sharpsOrFlats
        self.tonic = tonic
    }

    /// Decodes word 1. Refuses non-zero reserved bits (`reservedBitsSet(status: 0x05)`), then tonic 8...15.
    init(word1: UInt32) throws(UMPFlexDataRefusal) {
        guard word1 & Self.reservedWord1Mask == 0 else {
            throw .reservedBitsSet(status: UMPFlexDataContent.keySignatureStatus)
        }
        // Shifting the nibble into the top of a byte and back sign-extends it: 0x8...0xF become -8...-1.
        let sharpsOrFlats = Int8(bitPattern: UInt8(word1 >> 28) << 4) >> 4
        let tonicBits = UInt8((word1 >> 24) & 0x0F)
        guard let tonic = UMPFlexDataTonic(rawValue: tonicBits) else {
            throw .invalidField(.tonic, value: Int(tonicBits))
        }
        try self.init(sharpsOrFlats: sharpsOrFlats, tonic: tonic)
    }

    /// Word 1 with every reserved bit zero.
    var word1: UInt32 {
        UInt32(UInt8(bitPattern: sharpsOrFlats) & 0x0F) << 28 | UInt32(tonic.rawValue) << 24
    }
}

/// The Setup and Performance (status bank 0x00) messages this codec carries.
enum UMPFlexDataContent: Equatable, Sendable {
    /// Status 0x00. Word 1 is the number of 10-nanosecond units per quarter note; 0 and 0xFFFFFFFF are accepted.
    case setTempo(tenNanosecondsPerQuarterNote: UInt32)
    /// Status 0x01.
    case setTimeSignature(UMPFlexDataTimeSignature)
    /// Status 0x05.
    case setKeySignature(UMPFlexDataKeySignature)

    static let tempoStatus: UInt8 = 0x00
    static let timeSignatureStatus: UInt8 = 0x01
    static let keySignatureStatus: UInt8 = 0x05
    /// The bank 0x00 statuses this codec decodes; every other status is `unknownStatus`.
    static let decodedStatuses: Set<UInt8> = [tempoStatus, timeSignatureStatus, keySignatureStatus]

    /// Whether a message of this status may be BUILT with a channel address: only Set Key Signature. Building Set
    /// Tempo or Set Time Signature requires the group address, following bl-midi2-rs (`NoChannelProperty` writes
    /// address 1). Decoding does not apply this rule: ni-midi2, AM_MIDI2.0Lib, midi2.0lib and the MIDI 2.0 Workbench
    /// accept any address on read (only bl-midi2-rs refuses address 0 there). A decoded channel-addressed Set Tempo or
    /// Set Time Signature re-encodes with address 0: forwarding it unchanged does not normalise the address. Not
    /// checked against M2-104-UM.
    static func allowsChannelAddress(status: UInt8) -> Bool {
        status == keySignatureStatus
    }

    /// The status byte (word 0 bits 7...0).
    var status: UInt8 {
        switch self {
        case .setTempo: return Self.tempoStatus
        case .setTimeSignature: return Self.timeSignatureStatus
        case .setKeySignature: return Self.keySignatureStatus
        }
    }
}

/// One complete Flex Data packet (MT 0xD) of status bank 0x00: Set Tempo, Set Time Signature or Set Key Signature.
///
/// Word 0: `[0xD | group][form:2 address:2 channel:4][status bank][status]`; words 1...3 carry the data. `packet` is
/// the canonical encoding of (group, address, content). Decoding refuses every non-zero reserved bit except the channel
/// nibble of a group-addressed message, which is ignored; so `packet` re-encodes the received words exactly, except
/// that an ignored channel nibble comes back as 0.
struct UMPFlexDataMessage: Equatable, Sendable {
    /// Status bank 0x00, Setup and Performance.
    static let setupAndPerformanceBank: UInt8 = 0x00

    let group: UMPGroup
    let address: UMPFlexDataAddress
    let content: UMPFlexDataContent
    private let storedPacket: UMPPacket

    /// Builds a message to send. Refuses a channel address for Set Tempo and Set Time Signature
    /// (`UMPFlexDataContent.allowsChannelAddress(status:)`).
    init(group: UMPGroup, address: UMPFlexDataAddress, content: UMPFlexDataContent) throws(UMPFlexDataRefusal) {
        if case .channel = address, !UMPFlexDataContent.allowsChannelAddress(status: content.status) {
            throw .channelAddressNotAllowed(status: content.status)
        }
        try self.init(receivedGroup: group, address: address, content: content)
    }

    /// Builds a message without the send-only address rule, so a decoded channel-addressed Set Tempo or Set Time
    /// Signature is representable. Throws only `.ump`, which checked fields never reach.
    private init(receivedGroup group: UMPGroup, address: UMPFlexDataAddress, content: UMPFlexDataContent)
        throws(UMPFlexDataRefusal) {
        do {
            storedPacket = try UMPPacket(words: Self.words(group: group, address: address, content: content))
        } catch {
            throw .ump(error)
        }
        self.group = group
        self.address = address
        self.content = content
    }

    /// The four words, form 0 (complete) and status bank 0x00; every reserved bit is 0, including the channel nibble
    /// of a group-addressed message.
    var packet: UMPPacket { storedPacket }

    private static func words(group: UMPGroup, address: UMPFlexDataAddress, content: UMPFlexDataContent) -> [UInt32] {
        var first = 0xD000_0000 | UInt32(group.value) << 24 | UInt32(setupAndPerformanceBank) << 8
            | UInt32(content.status)
        switch address {
        case .channel(let channel): first |= UInt32(channel.value) << 16
        case .group: first |= 1 << 20
        }
        switch content {
        case .setTempo(let units):
            return [first, units, 0, 0]
        case .setTimeSignature(let signature):
            let data = UInt32(signature.numerator) << 24 | UInt32(signature.denominatorExponent) << 16
                | UInt32(signature.thirtySecondNotes) << 8
            return [first, data, 0, 0]
        case .setKeySignature(let key):
            return [first, key.word1, 0, 0]
        }
    }
}

extension UMPFlexDataMessage {
    /// Decodes one received Flex Data packet. Order of refusals: not MT 0xD, unknown status bank or status, form other
    /// than complete, reserved address, reserved bits, tonic 8...15. Receiving is lenient about addressing: every
    /// status accepts a channel address, and the channel nibble of a group-addressed message is ignored.
    init(decoding packet: UMPPacket) throws(UMPFlexDataRefusal) {
        guard packet.messageType == .flexData else { throw .notFlexData(actual: packet.messageType) }
        let words = packet.words
        let first = words[0]
        let bank = UInt8((first >> 8) & 0xFF)
        let status = UInt8(first & 0xFF)
        guard bank == Self.setupAndPerformanceBank, UMPFlexDataContent.decodedStatuses.contains(status) else {
            throw .unknownStatus(bank: bank, status: status)
        }
        let format = UInt8((first >> 22) & 0x3)
        guard format == 0 else { throw .wrongFormat(status: status, format: format) }
        let address = try Self.decodeAddress(first, status: status)
        let content: UMPFlexDataContent
        switch status {
        case UMPFlexDataContent.tempoStatus:
            try Self.requireZero(words[2] != 0 || words[3] != 0, status)
            content = .setTempo(tenNanosecondsPerQuarterNote: words[1])
        case UMPFlexDataContent.timeSignatureStatus:
            try Self.requireZero(words[1] & 0xFF != 0 || words[2] != 0 || words[3] != 0, status)
            content = .setTimeSignature(UMPFlexDataTimeSignature(
                numerator: UInt8(words[1] >> 24),
                denominatorExponent: UInt8((words[1] >> 16) & 0xFF),
                thirtySecondNotes: UInt8((words[1] >> 8) & 0xFF)
            ))
        default:
            try Self.requireZero(words[2] != 0 || words[3] != 0, status)
            content = .setKeySignature(try UMPFlexDataKeySignature(word1: words[1]))
        }
        let group: UMPGroup
        do {
            group = try UMPGroup(UInt8((first >> 24) & 0x0F))
        } catch {
            throw .ump(error)
        }
        try self.init(receivedGroup: group, address: address, content: content)
    }

    private static func decodeAddress(_ first: UInt32, status: UInt8) throws(UMPFlexDataRefusal) -> UMPFlexDataAddress {
        let addressBits = UInt8((first >> 20) & 0x3)
        let channelBits = UInt8((first >> 16) & 0x0F)
        switch addressBits {
        case 0:
            // Every status, including Set Tempo and Set Time Signature: only bl-midi2-rs refuses this on read.
            do {
                return .channel(try UMPChannel(channelBits))
            } catch {
                throw .ump(error)
            }
        case 1:
            // The channel nibble is ignored, as in ni-midi2, bl-midi2-rs, AM_MIDI2.0Lib and midi2.0lib; `packet`
            // encodes it as 0. M2-104-UM was not checked. Capture keeps raw MT 0xD words, so nothing is lost.
            return .group
        default:
            throw .reservedAddress(status: status, address: addressBits)
        }
    }

    private static func requireZero(_ reserved: Bool, _ status: UInt8) throws(UMPFlexDataRefusal) {
        if reserved { throw .reservedBitsSet(status: status) }
    }
}
