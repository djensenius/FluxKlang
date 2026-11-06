/// Translates MIDI 1.0 channel voice in UMP (MT 0x2) to MIDI 2.0 channel voice (MT 0x4).
///
/// Based on the MIDI 1.0 Protocol → MIDI 2.0 Protocol default translation of MMA/AMEI M2-104-UM "Universal MIDI
/// Packet (UMP) Format and MIDI 2.0 Protocol", as the reference translators implement it (ALSA `ump_convert`, JUCE
/// `Midi1ToMidi2DefaultTranslator`, cycfi/q `translate.hpp`, AM_MIDI2.0Lib). Where the references disagree, or
/// where this project fails closed instead of passing a message through, the choice is marked "project decision".
/// Values are scaled only through `UMPScaling` (min-centre-max up).
///
/// - Group and channel are kept. Meaning comes from `UMPMIDI1ChannelVoice.semantic`, so a Note On with velocity 0
///   becomes a Note Off with velocity 64 (scaled), as `MIDI1Semantic` reads it. Project decision: the references
///   split here (some keep a Note On with velocity 0); AM_MIDI2.0Lib matches this choice.
/// - Bank Select (CC 0/32) is absorbed into state and sent with the next Program Change (Bank Valid set when both
///   bytes are known). Project decision: after only one byte, the Program Change is sent with Bank Valid clear and
///   an `incompleteBankSelect` loss, because a guessed byte would select a bank nobody asked for (ALSA and q set
///   Bank Valid with the missing byte as 0 or its last value; JUCE treats either byte alone as valid). The bank
///   persists after the Program Change, as in JUCE and q (ALSA and AM_MIDI2.0Lib clear it).
/// - RPN (CC 101/100) and NRPN (CC 99/98) selections are absorbed. CC 6 is held, not sent: CC 38 completes it into
///   one Registered/Assignable Controller with the 14-bit value `msb << 7 | lsb`. A held CC 6 is sent with LSB 0
///   (a Data Entry MSB resets the LSB, the MIDI 1.0 convention) before a second CC 6, before any selection byte,
///   before any other message on the same group and channel, or by `flush(group:channel:)` / `flushAll()`. The
///   translator has no clock: an I/O layer that wants a held value sent after a timeout calls `flush`. A further
///   CC 38 re-sends the controller with the last MSB and the new LSB. The null RPN (127/127) deselects; Data Entry
///   then declares a loss.
/// - Data Increment/Decrement (CC 96/97) send nothing and declare `dataIncrementUnmapped`, with or without a
///   selected parameter, and forget the Data Entry MSB (the receiver's value is no longer known, so a following
///   CC 38 declares `dataEntryLSBWithoutMSB`). Project decision: the references pass CC 96/97 through as MIDI 2.0
///   Control Changes, but the selection they apply to was absorbed, so a bare MIDI 2.0 CC 96/97 has no meaning;
///   this translator fails closed with a declared loss because nothing may be dropped silently.
/// - Reset All Controllers (CC 121) is sent as a MIDI 2.0 Control Change, then forgets the RPN/NRPN selection and
///   the Data Entry MSB of that group and channel; the bank is kept (as `MIDI1ChannelState` does).
/// - Every other Control Change is sent as a MIDI 2.0 Control Change with its value scaled 7 → 32 bits.
///
/// Per group and channel, messages keep their order. Across channels, a write held on one channel is sent after
/// messages that arrived on other channels in the meantime.
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

    /// Sends the Data Entry held on one group and channel (its CC 6 with LSB 0), if any.
    mutating func flush(group: UMPGroup, channel: UMPChannel) -> [UMPMIDI2ChannelVoice] {
        guard let held = channels[group, channel].heldDataEntry else { return [] }
        channels[group, channel].heldDataEntry = nil
        return [held]
    }

    /// Sends every held Data Entry, group by group and channel by channel.
    mutating func flushAll() -> [UMPMIDI2ChannelVoice] {
        let held = channels.elements.compactMap(\.heldDataEntry)
        for voice in held { channels[voice.group, voice.channel].heldDataEntry = nil }
        return held
    }

    /// Forgets the state of one group and channel (for example after its sender reconnects). A held Data Entry is
    /// a value the sender set, so it is returned (sent) rather than discarded.
    mutating func reset(group: UMPGroup, channel: UMPChannel) -> [UMPMIDI2ChannelVoice] {
        let held = flush(group: group, channel: channel)
        channels[group, channel] = UMPUpChannelState()
        return held
    }

    private mutating func apply(
        _ voice: UMPMIDI1ChannelVoice
    ) throws(UMPRefusal) -> UMPTranslationOutput<UMPMIDI2ChannelVoice> {
        guard case let .channel(status, data1, _) = voice.event else { throw .notChannelVoice }
        // CC 38 completes a held CC 6; anything else on this group and channel sends it first.
        let completesHeldDataEntry = status & 0xF0 == 0xB0 && data1 == 38
        let flushed = completesHeldDataEntry ? [] : flush(group: voice.group, channel: try UMPChannel(status & 0x0F))
        let output = try message(voice)
        return UMPTranslationOutput(messages: flushed + output.messages, losses: output.losses)
    }

    private mutating func message(
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
        case 96, 97:
            channels[group, channel].dataEntryMSB = nil
            let loss = UMPTranslationLoss(reason: .dataIncrementUnmapped, group: group, channel: channel)
            return UMPTranslationOutput(messages: [], losses: [loss])
        default:
            let scaled = try UMPScaling.scaleUp(UInt32(value.value), fromBits: 7, toBits: 32)
            let message = UMPMIDI2Message.controlChange(index: controller, value: scaled)
            if controller.value == 121 { channels[group, channel].resetAllControllers() }
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
        if isMSB {
            channels[group, channel].dataEntryMSB = value
            channels[group, channel].heldDataEntry = UMPMIDI2ChannelVoice(
                group: group, channel: channel, message: try Self.parameter(address, UInt32(value.value) << 7))
            return UMPTranslationOutput(messages: [], losses: [])
        }
        guard let msb = channels[group, channel].dataEntryMSB else { return loss(.dataEntryLSBWithoutMSB) }
        channels[group, channel].heldDataEntry = nil
        let message = try Self.parameter(address, UInt32(msb.value) << 7 | UInt32(value.value))
        return UMPTranslationOutput(
            messages: [UMPMIDI2ChannelVoice(group: group, channel: channel, message: message)], losses: [])
    }

    /// The Registered (RPN) or Assignable (NRPN) Controller carrying a 14-bit Data Entry value.
    private static func parameter(
        _ address: UMPParameterAddress, _ fourteenBit: UInt32
    ) throws(UMPRefusal) -> UMPMIDI2Message {
        let scaled = try UMPScaling.scaleUp(fourteenBit, fromBits: 14, toBits: 32)
        return address.kind == .registered
            ? .registeredController(bank: address.bank, index: address.index, value: scaled)
            : .assignableController(bank: address.bank, index: address.index, value: scaled)
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
