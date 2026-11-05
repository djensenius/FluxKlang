/// MIDI 1.0 channel voice in UMP (MT 0x2): `[0x2 | group][status][data1][data2]`.
///
/// Meaning comes from `MIDI1Event.channel(...).semantic`, so it always agrees with `MIDI1Semantic` (including a
/// Note On with velocity 0 meaning Note Off). The raw status and data bytes are kept too, so `packet` re-encodes the
/// exact word.
/// The protocol is the caller's: this type never decides whether data is effectively MIDI 1 or 2 (media-contract §9.1).
struct UMPMIDI1ChannelVoice: Equatable, Sendable {
    private let storedGroup: UMPGroup
    private let storedStatus: UInt8
    private let storedData1: UInt8
    private let storedData2: UInt8?
    private let storedSemantic: MIDI1Semantic

    private init(validatedGroup: UMPGroup, status: UInt8, data1: UInt8, data2: UInt8?, semantic: MIDI1Semantic) {
        storedGroup = validatedGroup
        storedStatus = status
        storedData1 = data1
        storedData2 = data2
        storedSemantic = semantic
    }

    /// Refuses anything but a `MIDI1Event.channel` that `MIDI1Semantic` accepts.
    init(group: UMPGroup, event: MIDI1Event) throws(UMPRefusal) {
        guard case let .channel(status, data1, data2) = event else { throw .notChannelVoice }
        guard let semantic = event.semantic else {
            throw .invalidMIDI1Message(status: status, data1: data1, data2: data2)
        }
        self.init(validatedGroup: group, status: status, data1: data1, data2: data2, semantic: semantic)
    }

    /// Encodes a channel case of `MIDI1Semantic` (channel 1...16). Note Off is sent as status 0x8n.
    ///
    /// MT2 keeps MIDI 1 semantics: `.noteOn(velocity: 0)` is sent as raw 0x9n with velocity 0, so its decoded
    /// `semantic` is `.noteOff(velocity: 64)` (as `MIDI1Semantic` maps it) while `event` and `packet` keep 0x9n.
    /// Pitch bend above 0x3FFF is refused rather than wrapped; every other field is a byte `MIDI1Semantic` checks.
    init(group: UMPGroup, semantic: MIDI1Semantic) throws(UMPRefusal) {
        let bytes: MIDI1ChannelBytes
        switch semantic {
        case let .noteOff(channel, note, velocity):
            bytes = MIDI1ChannelBytes(family: 0x80, channel: channel, data1: note, data2: velocity)
        case let .noteOn(channel, note, velocity):
            bytes = MIDI1ChannelBytes(family: 0x90, channel: channel, data1: note, data2: velocity)
        case let .polyphonicPressure(channel, note, pressure):
            bytes = MIDI1ChannelBytes(family: 0xA0, channel: channel, data1: note, data2: pressure)
        case let .controlChange(channel, controller, value):
            bytes = MIDI1ChannelBytes(family: 0xB0, channel: channel, data1: controller, data2: value)
        case let .programChange(channel, program):
            bytes = MIDI1ChannelBytes(family: 0xC0, channel: channel, data1: program, data2: nil)
        case let .channelPressure(channel, pressure):
            bytes = MIDI1ChannelBytes(family: 0xD0, channel: channel, data1: pressure, data2: nil)
        case let .pitchBend(channel, value):
            guard value <= 0x3FFF else { throw .valueOutOfRange(field: .fourteenBit, value: Int(value)) }
            bytes = MIDI1ChannelBytes(family: 0xE0, channel: channel, data1: UInt8(value & 0x7F),
                                      data2: UInt8(truncatingIfNeeded: value >> 7))
        case .systemCommon, .realTime, .sysEx:
            throw .notChannelVoice
        }
        guard (1...16).contains(bytes.channel) else {
            throw .valueOutOfRange(field: .channel, value: Int(bytes.channel))
        }
        let status = bytes.family | (bytes.channel - 1)
        try self.init(group: group, event: .channel(status: status, data1: bytes.data1, data2: bytes.data2))
    }

    /// Decodes an MT 0x2 packet. Refuses other types, statuses outside 0x80...0xEF, a non-zero unused third byte
    /// for 0xCn/0xDn, and data bytes that `MIDI1Semantic` refuses.
    init(decoding packet: UMPPacket) throws(UMPRefusal) {
        guard packet.messageType == .midi1ChannelVoice else {
            throw .wrongMessageType(expected: .midi1ChannelVoice, actual: packet.messageType)
        }
        let word = packet.words[0]
        let status = UInt8(truncatingIfNeeded: word >> 16)
        let data1 = UInt8(truncatingIfNeeded: word >> 8)
        let data2 = UInt8(truncatingIfNeeded: word)
        guard (0x80...0xEF).contains(status) else { throw .reservedStatus(mt: .midi1ChannelVoice, status: status) }
        let singleData = (0xC0...0xDF).contains(status)
        guard !singleData || data2 == 0 else { throw .reservedBitsSet(mt: .midi1ChannelVoice, status: status) }
        let group = try UMPGroup(UInt8((word >> 24) & 0x0F))
        try self.init(group: group, event: .channel(status: status, data1: data1, data2: singleData ? nil : data2))
    }

    var group: UMPGroup { storedGroup }
    /// The `MIDI1Event.channel` exactly as received or built (a Note On with velocity 0 stays 0x9n here).
    var event: MIDI1Event { .channel(status: storedStatus, data1: storedData1, data2: storedData2) }
    var semantic: MIDI1Semantic { storedSemantic }

    var packet: UMPPacket {
        .midi1ChannelVoice(UInt32(storedGroup.value) << 24 | UInt32(storedStatus) << 16 | UInt32(storedData1) << 8
            | UInt32(storedData2 ?? 0))
    }
}

/// Status family, 1-based channel and data bytes of a `MIDI1Semantic` channel message.
private struct MIDI1ChannelBytes {
    let family: UInt8
    let channel: UInt8
    let data1: UInt8
    let data2: UInt8?
}

/// Bank select carried by an MT 0x4 Program Change whose Bank Valid flag is set.
struct UMPBankSelect: Equatable, Sendable {
    let msb: UMPSevenBit
    let lsb: UMPSevenBit
}

/// The MIDI 2.0 channel voice messages (MT 0x4) of M2-104-UM; layouts cross-checked against Apple CoreMIDI
/// `MIDIMessages.h`. Status nibble 0x7 is reserved.
/// Every field is either a full-width integer or a checked type, so every value encodes.
enum UMPMIDI2Message: Equatable, Sendable {
    case registeredPerNoteController(note: UMPSevenBit, index: UInt8, value: UInt32)
    case assignablePerNoteController(note: UMPSevenBit, index: UInt8, value: UInt32)
    case registeredController(bank: UMPSevenBit, index: UMPSevenBit, value: UInt32)
    case assignableController(bank: UMPSevenBit, index: UMPSevenBit, value: UInt32)
    case relativeRegisteredController(bank: UMPSevenBit, index: UMPSevenBit, delta: Int32)
    case relativeAssignableController(bank: UMPSevenBit, index: UMPSevenBit, delta: Int32)
    case perNotePitchBend(note: UMPSevenBit, value: UInt32)
    case noteOff(note: UMPSevenBit, velocity: UInt16, attributeType: UInt8, attribute: UInt16)
    /// Velocity 0 is a Note On in MIDI 2.0; it is never turned into a Note Off.
    case noteOn(note: UMPSevenBit, velocity: UInt16, attributeType: UInt8, attribute: UInt16)
    case polyPressure(note: UMPSevenBit, value: UInt32)
    case controlChange(index: UMPSevenBit, value: UInt32)
    /// `bank` is nil when the Bank Valid flag is clear.
    case programChange(program: UMPSevenBit, bank: UMPBankSelect?)
    case channelPressure(value: UInt32)
    case pitchBend(value: UInt32)
    case perNoteManagement(note: UMPSevenBit, detach: Bool, reset: Bool)
}

/// MIDI 2.0 channel voice in UMP (MT 0x4): `[0x4 | group][status | channel][byte3][byte4]` then one data word.
///
/// Decoding refuses reserved statuses and non-zero reserved bits, so `packet` always re-encodes the received words.
/// Whether the data is genuine MIDI 2.0 or OS-upscaled MIDI 1.0 is the caller's knowledge (media-contract §9.1).
struct UMPMIDI2ChannelVoice: Equatable, Sendable {
    let group: UMPGroup
    let channel: UMPChannel
    let message: UMPMIDI2Message

    init(group: UMPGroup, channel: UMPChannel, message: UMPMIDI2Message) {
        self.group = group
        self.channel = channel
        self.message = message
    }

    init(decoding packet: UMPPacket) throws(UMPRefusal) {
        guard packet.messageType == .midi2ChannelVoice else {
            throw .wrongMessageType(expected: .midi2ChannelVoice, actual: packet.messageType)
        }
        let first = packet.words[0]
        let fields = UMPMIDI2Fields(
            status: UInt8((first >> 20) & 0x0F), byte3: UInt8(truncatingIfNeeded: first >> 8),
            byte4: UInt8(truncatingIfNeeded: first), data: packet.words[1]
        )
        group = try UMPGroup(UInt8((first >> 24) & 0x0F))
        channel = try UMPChannel(UInt8((first >> 16) & 0x0F))
        message = try fields.message()
    }

    var packet: UMPPacket {
        let fields = UMPMIDI2Fields(message)
        let first = UInt32(group.value) << 24 | UInt32(fields.status) << 20 | UInt32(channel.value) << 16
            | UInt32(fields.byte3) << 8 | UInt32(fields.byte4)
        return .midi2ChannelVoice(first, fields.data)
    }
}

/// The variable fields of an MT 0x4 packet.
private struct UMPMIDI2Fields {
    let status: UInt8
    let byte3: UInt8
    let byte4: UInt8
    let data: UInt32

    init(status: UInt8, byte3: UInt8, byte4: UInt8, data: UInt32) {
        self.status = status
        self.byte3 = byte3
        self.byte4 = byte4
        self.data = data
    }

    // swiftlint:disable:next cyclomatic_complexity
    init(_ message: UMPMIDI2Message) {
        switch message {
        case let .registeredPerNoteController(note, index, value):
            self.init(status: 0x0, byte3: note.value, byte4: index, data: value)
        case let .assignablePerNoteController(note, index, value):
            self.init(status: 0x1, byte3: note.value, byte4: index, data: value)
        case let .registeredController(bank, index, value):
            self.init(status: 0x2, byte3: bank.value, byte4: index.value, data: value)
        case let .assignableController(bank, index, value):
            self.init(status: 0x3, byte3: bank.value, byte4: index.value, data: value)
        case let .relativeRegisteredController(bank, index, delta):
            self.init(status: 0x4, byte3: bank.value, byte4: index.value, data: UInt32(bitPattern: delta))
        case let .relativeAssignableController(bank, index, delta):
            self.init(status: 0x5, byte3: bank.value, byte4: index.value, data: UInt32(bitPattern: delta))
        case let .perNotePitchBend(note, value):
            self.init(status: 0x6, byte3: note.value, byte4: 0, data: value)
        case let .noteOff(note, velocity, attributeType, attribute):
            self.init(status: 0x8, byte3: note.value, byte4: attributeType,
                      data: UInt32(velocity) << 16 | UInt32(attribute))
        case let .noteOn(note, velocity, attributeType, attribute):
            self.init(status: 0x9, byte3: note.value, byte4: attributeType,
                      data: UInt32(velocity) << 16 | UInt32(attribute))
        case let .polyPressure(note, value):
            self.init(status: 0xA, byte3: note.value, byte4: 0, data: value)
        case let .controlChange(index, value):
            self.init(status: 0xB, byte3: index.value, byte4: 0, data: value)
        case let .programChange(program, bank):
            let bankWord = bank.map { UInt32($0.msb.value) << 8 | UInt32($0.lsb.value) } ?? 0
            self.init(status: 0xC, byte3: 0, byte4: bank == nil ? 0 : 1,
                      data: UInt32(program.value) << 24 | bankWord)
        case let .channelPressure(value):
            self.init(status: 0xD, byte3: 0, byte4: 0, data: value)
        case let .pitchBend(value):
            self.init(status: 0xE, byte3: 0, byte4: 0, data: value)
        case let .perNoteManagement(note, detach, reset):
            self.init(status: 0xF, byte3: note.value, byte4: (detach ? 2 : 0) | (reset ? 1 : 0), data: 0)
        }
    }

    // swiftlint:disable:next cyclomatic_complexity
    func message() throws(UMPRefusal) -> UMPMIDI2Message {
        switch status {
        case 0x0:
            return .registeredPerNoteController(note: try sevenBit(byte3), index: byte4, value: data)
        case 0x1:
            return .assignablePerNoteController(note: try sevenBit(byte3), index: byte4, value: data)
        case 0x2:
            return .registeredController(bank: try sevenBit(byte3), index: try sevenBit(byte4), value: data)
        case 0x3:
            return .assignableController(bank: try sevenBit(byte3), index: try sevenBit(byte4), value: data)
        case 0x4:
            return .relativeRegisteredController(
                bank: try sevenBit(byte3), index: try sevenBit(byte4), delta: Int32(bitPattern: data))
        case 0x5:
            return .relativeAssignableController(
                bank: try sevenBit(byte3), index: try sevenBit(byte4), delta: Int32(bitPattern: data))
        case 0x6:
            try reserved(UInt32(byte4))
            return .perNotePitchBend(note: try sevenBit(byte3), value: data)
        case 0x8, 0x9:
            let note = try sevenBit(byte3)
            let velocity = UInt16(truncatingIfNeeded: data >> 16)
            let attribute = UInt16(truncatingIfNeeded: data)
            return status == 0x8
                ? .noteOff(note: note, velocity: velocity, attributeType: byte4, attribute: attribute)
                : .noteOn(note: note, velocity: velocity, attributeType: byte4, attribute: attribute)
        case 0xA:
            try reserved(UInt32(byte4))
            return .polyPressure(note: try sevenBit(byte3), value: data)
        case 0xB:
            try reserved(UInt32(byte4))
            return .controlChange(index: try sevenBit(byte3), value: data)
        case 0xC:
            return try programChange()
        case 0xD, 0xE:
            try reserved(UInt32(byte3) | UInt32(byte4))
            return status == 0xD ? .channelPressure(value: data) : .pitchBend(value: data)
        case 0xF:
            try reserved(UInt32(byte4 & 0xFC) | data)
            return .perNoteManagement(note: try sevenBit(byte3), detach: byte4 & 0x02 != 0, reset: byte4 & 0x01 != 0)
        default:
            throw .reservedStatus(mt: .midi2ChannelVoice, status: status)
        }
    }

    /// Program in data byte 1, byte 2 reserved, bank MSB/LSB in bytes 3/4. With Bank Valid clear the bank bytes
    /// must be zero, so the decoded message re-encodes to the same words.
    private func programChange() throws(UMPRefusal) -> UMPMIDI2Message {
        try reserved(UInt32(byte3) | UInt32(byte4 & 0xFE) | (data & 0x00FF_0000))
        let program = try sevenBit(UInt8(truncatingIfNeeded: data >> 24))
        let msb = UInt8(truncatingIfNeeded: data >> 8)
        let lsb = UInt8(truncatingIfNeeded: data)
        guard byte4 & 0x01 != 0 else {
            try reserved(UInt32(msb) | UInt32(lsb))
            return .programChange(program: program, bank: nil)
        }
        return .programChange(program: program, bank: UMPBankSelect(msb: try sevenBit(msb), lsb: try sevenBit(lsb)))
    }

    private func sevenBit(_ byte: UInt8) throws(UMPRefusal) -> UMPSevenBit {
        guard byte < 0x80 else { throw .reservedBitsSet(mt: .midi2ChannelVoice, status: status) }
        return try UMPSevenBit(byte)
    }

    private func reserved(_ bits: UInt32) throws(UMPRefusal) {
        guard bits == 0 else { throw .reservedBitsSet(mt: .midi2ChannelVoice, status: status) }
    }
}
