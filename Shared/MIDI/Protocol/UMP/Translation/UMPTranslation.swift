/// Translates MIDI 1.0 channel voice in UMP (MT 0x2) to MIDI 2.0 channel voice (MT 0x4).
///
/// Follows the MIDI 1.0 Protocol → MIDI 2.0 Protocol default translation of MMA/AMEI M2-104-UM "Universal MIDI
/// Packet (UMP) Format and MIDI 2.0 Protocol". Values are scaled only through `UMPScaling` (min-centre-max up).
///
/// - Group and channel are kept. Meaning comes from `UMPMIDI1ChannelVoice.semantic`, so a Note On with velocity 0
///   becomes a Note Off with velocity 64 (scaled), as `MIDI1Semantic` reads it.
/// - Bank Select (CC 0/32) is absorbed into state and sent with the next Program Change (Bank Valid set when both
///   bytes are known; otherwise Bank Valid clear and an `incompleteBankSelect` loss).
/// - RPN (CC 101/100) and NRPN (CC 99/98) selections are absorbed. CC 6 sends a Registered/Assignable Controller
///   with the 14-bit value `msb << 7` (a Data Entry MSB resets the LSB to 0, the MIDI 1.0 convention); CC 38 sends
///   it again with the full 14-bit value. The null RPN (127/127) deselects; Data Entry then declares a loss.
/// - Every other Control Change (including Data Increment/Decrement, CC 96/97) is sent as a MIDI 2.0 Control
///   Change with its value scaled 7 → 32 bits.
///
/// State is bounded (16 groups × 16 channels) and value-typed. A refused call returns nothing and changes nothing;
/// refusals cannot happen for a checked `UMPMIDI1ChannelVoice` and exist only because the codec calls are throwing.
struct UMPMIDI1ToMIDI2Translator: Equatable, Sendable {
    private var channels = UMPTranslationTable(repeating: UMPUpChannelState())
    private var storedLosses = UMPTranslationLossCounts()

    init() {}

    /// Every loss declared so far.
    var losses: UMPTranslationLossCounts { storedLosses }

    /// The state of one group and channel.
    func state(group: UMPGroup, channel: UMPChannel) -> UMPUpChannelState { channels[group, channel] }

    /// Translates one message, updating state and loss counts.
    mutating func translate(
        _ voice: UMPMIDI1ChannelVoice
    ) throws(UMPRefusal) -> UMPTranslationOutput<UMPMIDI2ChannelVoice> {
        var next = self
        let output = try next.apply(voice)
        next.storedLosses.record(output.losses)
        self = next
        return output
    }

    private mutating func apply(
        _ voice: UMPMIDI1ChannelVoice
    ) throws(UMPRefusal) -> UMPTranslationOutput<UMPMIDI2ChannelVoice> {
        let group = voice.group
        switch voice.semantic {
        case let .noteOff(channel, note, velocity):
            return try Self.send(group, channel, .noteOff(
                note: UMPSevenBit(note), velocity: Self.velocity(velocity), attributeType: 0, attribute: 0))
        case let .noteOn(channel, note, velocity):
            return try Self.send(group, channel, .noteOn(
                note: UMPSevenBit(note), velocity: Self.velocity(velocity), attributeType: 0, attribute: 0))
        case let .polyphonicPressure(channel, note, pressure):
            return try Self.send(group, channel, .polyPressure(
                note: UMPSevenBit(note), value: UMPScaling.scaleUp(UInt32(pressure), fromBits: 7, toBits: 32)))
        case let .controlChange(channel, controller, value):
            return try controlChange(
                group, try Self.channel(channel), try UMPSevenBit(controller), try UMPSevenBit(value))
        case let .programChange(channel, program):
            let channel = try Self.channel(channel)
            let state = channels[group, channel]
            let message = UMPMIDI2Message.programChange(program: try UMPSevenBit(program), bank: state.bank)
            let partialBank = state.bank == nil && (state.bankMSB != nil || state.bankLSB != nil)
            let losses = partialBank
                ? [UMPTranslationLoss(reason: .incompleteBankSelect, group: group, channel: channel)] : []
            return UMPTranslationOutput(
                messages: [UMPMIDI2ChannelVoice(group: group, channel: channel, message: message)], losses: losses)
        case let .channelPressure(channel, pressure):
            return try Self.send(group, channel, .channelPressure(
                value: UMPScaling.scaleUp(UInt32(pressure), fromBits: 7, toBits: 32)))
        case let .pitchBend(channel, value):
            return try Self.send(group, channel, .pitchBend(
                value: UMPScaling.scaleUp(UInt32(value), fromBits: 14, toBits: 32)))
        case .systemCommon, .realTime, .sysEx:
            throw .notChannelVoice
        }
    }

    private mutating func controlChange(
        _ group: UMPGroup, _ channel: UMPChannel, _ controller: UMPSevenBit, _ value: UMPSevenBit
    ) throws(UMPRefusal) -> UMPTranslationOutput<UMPMIDI2ChannelVoice> {
        let empty = UMPTranslationOutput<UMPMIDI2ChannelVoice>(messages: [], losses: [])
        switch controller.value {
        case 0:
            channels[group, channel].bankMSB = value
            return empty
        case 32:
            channels[group, channel].bankLSB = value
            return empty
        case 99, 98:
            channels[group, channel].select(.assignable, isMSB: controller.value == 99, value: value)
            return empty
        case 101, 100:
            channels[group, channel].select(.registered, isMSB: controller.value == 101, value: value)
            return empty
        case 6, 38:
            return try dataEntry(group, channel, isMSB: controller.value == 6, value: value)
        default:
            let scaled = try UMPScaling.scaleUp(UInt32(value.value), fromBits: 7, toBits: 32)
            let message = UMPMIDI2Message.controlChange(index: controller, value: scaled)
            return UMPTranslationOutput(
                messages: [UMPMIDI2ChannelVoice(group: group, channel: channel, message: message)], losses: [])
        }
    }

    private mutating func dataEntry(
        _ group: UMPGroup, _ channel: UMPChannel, isMSB: Bool, value: UMPSevenBit
    ) throws(UMPRefusal) -> UMPTranslationOutput<UMPMIDI2ChannelVoice> {
        func loss(_ reason: UMPTranslationLossReason) -> UMPTranslationOutput<UMPMIDI2ChannelVoice> {
            UMPTranslationOutput(
                messages: [], losses: [UMPTranslationLoss(reason: reason, group: group, channel: channel)])
        }
        guard let address = channels[group, channel].parameter, !address.isNull else {
            return loss(.dataEntryWithoutParameter)
        }
        let fourteenBit: UInt32
        if isMSB {
            channels[group, channel].dataEntryMSB = value
            fourteenBit = UInt32(value.value) << 7
        } else {
            guard let msb = channels[group, channel].dataEntryMSB else { return loss(.dataEntryLSBWithoutMSB) }
            fourteenBit = UInt32(msb.value) << 7 | UInt32(value.value)
        }
        let scaled = try UMPScaling.scaleUp(fourteenBit, fromBits: 14, toBits: 32)
        let message: UMPMIDI2Message = address.kind == .registered
            ? .registeredController(bank: address.bank, index: address.index, value: scaled)
            : .assignableController(bank: address.bank, index: address.index, value: scaled)
        return UMPTranslationOutput(
            messages: [UMPMIDI2ChannelVoice(group: group, channel: channel, message: message)], losses: [])
    }

    /// `MIDI1Semantic` numbers channels 1...16; UMP uses 0...15.
    private static func channel(_ oneBased: UInt8) throws(UMPRefusal) -> UMPChannel {
        guard oneBased >= 1 else { throw .valueOutOfRange(field: .channel, value: Int(oneBased)) }
        return try UMPChannel(oneBased - 1)
    }

    private static func velocity(_ value: UInt8) throws(UMPRefusal) -> UInt16 {
        UInt16(truncatingIfNeeded: try UMPScaling.scaleUp(UInt32(value), fromBits: 7, toBits: 16))
    }

    private static func send(
        _ group: UMPGroup, _ channel: UInt8, _ message: UMPMIDI2Message
    ) throws(UMPRefusal) -> UMPTranslationOutput<UMPMIDI2ChannelVoice> {
        UMPTranslationOutput(
            messages: [UMPMIDI2ChannelVoice(group: group, channel: try Self.channel(channel), message: message)],
            losses: [])
    }
}
