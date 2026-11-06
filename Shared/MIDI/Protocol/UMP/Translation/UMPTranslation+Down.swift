/// Translates MIDI 2.0 channel voice in UMP (MT 0x4) to MIDI 1.0 channel voice (MT 0x2).
///
/// Based on the MIDI 2.0 Protocol → MIDI 1.0 Protocol default translation of MMA/AMEI M2-104-UM "Universal MIDI
/// Packet (UMP) Format and MIDI 2.0 Protocol". Values are reduced only through `UMPScaling.scaleDown` (right shift).
///
/// - A Note On whose velocity scales down to 0 is sent with velocity 1, so it is not read as a Note Off
///   (`noteOnVelocityRemapped`).
/// - A Program Change with Bank Valid sends CC 0 and CC 32 first, unless this channel was already sent that bank.
/// - A Registered/Assignable Controller sends CC 101/100 (or 99/98) unless that address is already selected, then
///   CC 6 with the 14-bit MSB when the address or MSB changed, then always CC 38 with the LSB (some receivers only
///   commit a parameter on CC 38). A MIDI 1.0 sequence that never sent CC 38 therefore comes back from 1 → 2 → 1
///   with an extra CC 38 = 0, which means the same (a Data Entry MSB resets the LSB to 0). No null RPN is sent
///   afterwards.
/// - After forwarding Data Increment/Decrement (CC 96/97) the receiver's parameter value is unknown, so the next
///   parameter write resends CC 6. After forwarding Reset All Controllers (CC 121) the receiver's selection is
///   null, so the next write resends the selection; the bank is kept.
/// - Messages MIDI 1.0 cannot carry send nothing and declare a typed loss; precision and attribute losses are
///   declared alongside the sent message. Nothing is dropped silently.
///
/// Not real-time safe: `translate` copies its state and allocates its output, so call the translator on the
/// control or I/O thread, never on the audio render thread.
///
/// State is bounded (16 groups × 16 channels) and value-typed. A refused call returns nothing and changes nothing;
/// refusals cannot happen for a checked `UMPMIDI2ChannelVoice` and exist only because the codec calls are throwing.
struct UMPMIDI2ToMIDI1Translator: Equatable, Sendable {
    private var channels = UMPTranslationTable(repeating: UMPDownChannelState())
    private var storedLosses = UMPTranslationLossCounts()

    init() {}

    /// Every loss declared so far.
    var losses: UMPTranslationLossCounts { storedLosses }

    /// What the MIDI 1.0 receiver of one group and channel has been sent.
    func state(group: UMPGroup, channel: UMPChannel) -> UMPDownChannelState { channels[group, channel] }

    /// Forgets what one group and channel's receiver was sent (for example after it reconnects), so the next
    /// Program Change with a bank and the next parameter write send every byte again.
    mutating func reset(group: UMPGroup, channel: UMPChannel) {
        channels[group, channel] = UMPDownChannelState()
    }

    /// Translates one message, updating state and loss counts.
    mutating func translate(
        _ voice: UMPMIDI2ChannelVoice
    ) throws(UMPRefusal) -> UMPTranslationOutput<UMPMIDI1ChannelVoice> {
        var next = self
        var builder = UMPDownBuilder(group: voice.group, channel: voice.channel)
        try next.apply(voice.message, into: &builder)
        let output = UMPTranslationOutput(messages: builder.messages, losses: builder.losses)
        next.storedLosses.record(output.losses)
        self = next
        return output
    }

    // swiftlint:disable:next cyclomatic_complexity
    private mutating func apply(_ message: UMPMIDI2Message, into out: inout UMPDownBuilder) throws(UMPRefusal) {
        switch message {
        case .registeredPerNoteController, .assignablePerNoteController:
            out.lose(.perNoteController)
        case .perNotePitchBend:
            out.lose(.perNotePitchBend)
        case .perNoteManagement:
            out.lose(.perNoteManagement)
        case .relativeRegisteredController, .relativeAssignableController:
            out.lose(.relativeController)
        case let .noteOff(note, velocity, attributeType, _):
            out.attributes(attributeType)
            let reduced = try out.velocity(velocity)
            try out.send(.noteOff(channel: out.midi1Channel, note: note.value, velocity: reduced))
        case let .noteOn(note, velocity, attributeType, _):
            out.attributes(attributeType)
            var reduced = try out.velocity(velocity)
            if reduced == 0 {
                reduced = 1
                out.lose(.noteOnVelocityRemapped)
            }
            try out.send(.noteOn(channel: out.midi1Channel, note: note.value, velocity: reduced))
        case let .polyPressure(note, value):
            let pressure = UInt8(try out.reduce(value, toBits: 7))
            try out.send(.polyphonicPressure(channel: out.midi1Channel, note: note.value, pressure: pressure))
        case let .controlChange(index, value):
            guard ![0, 6, 32, 38, 98, 99, 100, 101].contains(index.value) else {
                return out.lose(.controllerReservedInMIDI2)
            }
            let reduced = UInt8(try out.reduce(value, toBits: 7))
            try out.send(.controlChange(channel: out.midi1Channel, controller: index.value, value: reduced))
            if index.value == 96 || index.value == 97 { channels[out.group, out.channel].dataEntryMSB = nil }
            if index.value == 121 { channels[out.group, out.channel].resetAllControllers() }
        case let .programChange(program, bank):
            try programChange(program, bank: bank, into: &out)
        case let .channelPressure(value):
            let pressure = UInt8(try out.reduce(value, toBits: 7))
            try out.send(.channelPressure(channel: out.midi1Channel, pressure: pressure))
        case let .pitchBend(value):
            let bend = UInt16(try out.reduce(value, toBits: 14))
            try out.send(.pitchBend(channel: out.midi1Channel, value: bend))
        case let .registeredController(bank, index, value):
            try parameter(UMPParameterAddress(kind: .registered, bank: bank, index: index), value, into: &out)
        case let .assignableController(bank, index, value):
            try parameter(UMPParameterAddress(kind: .assignable, bank: bank, index: index), value, into: &out)
        }
    }

    private mutating func programChange(
        _ program: UMPSevenBit, bank: UMPBankSelect?, into out: inout UMPDownBuilder
    ) throws(UMPRefusal) {
        if let bank, channels[out.group, out.channel].bank != bank {
            try out.send(.controlChange(channel: out.midi1Channel, controller: 0, value: bank.msb.value))
            try out.send(.controlChange(channel: out.midi1Channel, controller: 32, value: bank.lsb.value))
            channels[out.group, out.channel].bank = bank
        }
        try out.send(.programChange(channel: out.midi1Channel, program: program.value))
    }

    private mutating func parameter(
        _ address: UMPParameterAddress, _ value: UInt32, into out: inout UMPDownBuilder
    ) throws(UMPRefusal) {
        guard !address.isNull else { return out.lose(.nullParameterAddress) }
        let fourteenBit = try out.reduce(value, toBits: 14)
        let msb = UInt8(fourteenBit >> 7)
        let lsb = UInt8(fourteenBit & 0x7F)
        var state = channels[out.group, out.channel]
        if state.parameter != address {
            let (msbController, lsbController): (UInt8, UInt8) = address.kind == .registered ? (101, 100) : (99, 98)
            let channel = out.midi1Channel
            try out.send(.controlChange(channel: channel, controller: msbController, value: address.bank.value))
            try out.send(.controlChange(channel: channel, controller: lsbController, value: address.index.value))
            state.parameter = address
            state.dataEntryMSB = nil
        }
        if state.dataEntryMSB?.value != msb {
            try out.send(.controlChange(channel: out.midi1Channel, controller: 6, value: msb))
            state.dataEntryMSB = try UMPSevenBit(msb)
        }
        try out.send(.controlChange(channel: out.midi1Channel, controller: 38, value: lsb))
        channels[out.group, out.channel] = state
    }
}

/// Collects the MIDI 1.0 messages and losses of one translated MIDI 2.0 message.
private struct UMPDownBuilder {
    let group: UMPGroup
    let channel: UMPChannel
    private(set) var messages: [UMPMIDI1ChannelVoice] = []
    private(set) var losses: [UMPTranslationLoss] = []

    init(group: UMPGroup, channel: UMPChannel) {
        self.group = group
        self.channel = channel
    }

    /// `MIDI1Semantic` numbers channels 1...16.
    var midi1Channel: UInt8 { channel.value + 1 }

    mutating func send(_ semantic: MIDI1Semantic) throws(UMPRefusal) {
        messages.append(try UMPMIDI1ChannelVoice(group: group, semantic: semantic))
    }

    mutating func lose(_ reason: UMPTranslationLossReason) {
        losses.append(UMPTranslationLoss(reason: reason, group: group, channel: channel))
    }

    /// Media-contract §9.3 counts an attribute loss only for attribute type ≠ 0; with type 0 the attribute value
    /// carries no meaning.
    mutating func attributes(_ attributeType: UInt8) {
        if attributeType != 0 { lose(.attributeDropped) }
    }

    /// 16 → 7 bits; declares `velocityDownscaled` when the original is not the upscale of the result.
    mutating func velocity(_ value: UInt16) throws(UMPRefusal) -> UInt8 {
        let reduced = try UMPScaling.scaleDown(UInt32(value), fromBits: 16, toBits: 7)
        if try UMPScaling.scaleUp(reduced, fromBits: 7, toBits: 16) != UInt32(value) { lose(.velocityDownscaled) }
        return UInt8(reduced)
    }

    /// 32 → `toBits` bits; declares `valueDownscaled` when the original is not the upscale of the result.
    mutating func reduce(_ value: UInt32, toBits: Int) throws(UMPRefusal) -> UInt32 {
        let reduced = try UMPScaling.scaleDown(value, fromBits: 32, toBits: toBits)
        if try UMPScaling.scaleUp(reduced, fromBits: toBits, toBits: 32) != value { lose(.valueDownscaled) }
        return reduced
    }
}
