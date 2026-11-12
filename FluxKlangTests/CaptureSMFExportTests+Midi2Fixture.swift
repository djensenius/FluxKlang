import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// Builders of MIDI 2.0 channel-voice captures (MT 0x4) and of the MIDI 1 items they translate to. Channels are
/// 1...16 as in the other fixtures. Exact values: a 7-bit value `v` at 16 bits is `0xC924` for 100; at 32 bits,
/// 0, `0x8000_0000` and `0xFFFF_FFFF` reduce exactly to 7 bits (0, 64, 127) and to 14 bits (0, 0x2000, 0x3FFF).
extension CaptureSMFExportTests.Fixture {
    static let exactLow: UInt32 = 0
    static let exactMid: UInt32 = 0x8000_0000
    static let exactHigh: UInt32 = 0xFFFF_FFFF

    static func voice2(_ opcode: UInt32, _ channel: UInt8, _ byte3: UInt8, _ byte4: UInt8 = 0, data: UInt32,
                       group: UInt32 = 0) -> [UInt32] {
        [0x4000_0000 | group << 24 | opcode << 20 | UInt32(channel - 1) << 16 | UInt32(byte3) << 8 | UInt32(byte4),
         data]
    }

    static func noteOn2(_ channel: UInt8, _ note: UInt8, _ velocity: UInt16, attributeType: UInt8 = 0,
                        attribute: UInt16 = 0, group: UInt32 = 0) -> [UInt32] {
        voice2(0x9, channel, note, attributeType, data: UInt32(velocity) << 16 | UInt32(attribute), group: group)
    }

    static func noteOff2(_ channel: UInt8, _ note: UInt8, _ velocity: UInt16, group: UInt32 = 0) -> [UInt32] {
        voice2(0x8, channel, note, data: UInt32(velocity) << 16, group: group)
    }

    static func controlChange2(_ channel: UInt8, _ controller: UInt8, _ value: UInt32,
                               group: UInt32 = 0) -> [UInt32] {
        voice2(0xB, channel, controller, data: value, group: group)
    }

    /// A Program Change, with Bank Valid when `bank` (MSB, LSB) is given.
    static func program2(_ channel: UInt8, _ program: UInt8, bank: (msb: UInt8, lsb: UInt8)? = nil,
                         group: UInt32 = 0) -> [UInt32] {
        let bankWord = bank.map { UInt32($0.msb) << 8 | UInt32($0.lsb) } ?? 0
        return voice2(0xC, channel, 0, bank == nil ? 0 : 1, data: UInt32(program) << 24 | bankWord, group: group)
    }

    /// A Registered (`assignable` false) or Assignable Controller write.
    static func parameter2(_ channel: UInt8, _ bank: UInt8, _ index: UInt8, _ value: UInt32, assignable: Bool = false,
                           group: UInt32 = 0) -> [UInt32] {
        voice2(assignable ? 0x3 : 0x2, channel, bank, index, data: value, group: group)
    }

    static func event(_ ticks: Int64, _ message: MIDI1Semantic) -> MIDIClipItem {
        .event(ticks: ticks, message: message)
    }

    static func ccItem(_ ticks: Int64, _ channel: UInt8, _ controller: UInt8, _ value: UInt8) -> MIDIClipItem {
        event(ticks, .controlChange(channel: channel, controller: controller, value: value))
    }

    /// What a Registered Controller write of `value` (`exactMid`: Data Entry MSB 64, LSB 0) sends to a receiver that
    /// has seen nothing of it: selection MSB and LSB (CC 101 and 100, or 99 and 98), CC 6, CC 38.
    static func parameterItems(_ ticks: Int64, _ channel: UInt8, _ bank: UInt8, _ index: UInt8, msb: UInt8 = 64,
                               lsb: UInt8 = 0, assignable: Bool = false) -> [MIDIClipItem] {
        [ccItem(ticks, channel, assignable ? 99 : 101, bank), ccItem(ticks, channel, assignable ? 98 : 100, index),
         ccItem(ticks, channel, 6, msb), ccItem(ticks, channel, 38, lsb)]
    }

    /// What a Program Change with a bank sends to a receiver that has not seen the bank: CC 0, CC 32, the program.
    static func bankItems(_ ticks: Int64, _ channel: UInt8, _ program: UInt8, bank: (msb: UInt8, lsb: UInt8))
        -> [MIDIClipItem] {
        [ccItem(ticks, channel, 0, bank.msb), ccItem(ticks, channel, 32, bank.lsb),
         event(ticks, .programChange(channel: channel, program: program))]
    }

    static func note(_ channel: UInt8, _ note: UInt8, velocity: UInt8, release: UInt8 = 64, from start: Int64,
                     to end: Int64) -> MIDIClipItem {
        .note(MIDIClipNote(channel: channel, note: note, velocity: velocity, releaseVelocity: release,
                           startTicks: start, endTicks: end))
    }
}

extension CaptureSMFExportTests.Feed {
    /// A MIDI 2.0 channel-voice capture on a MIDI 2.0 port, from a genuine MIDI 2.0 endpoint unless `endpoint` says
    /// otherwise.
    @discardableResult
    mutating func addMIDI2(_ stream: StreamID, _ words: [UInt32], tick: Int64,
                           endpoint: MIDIEndpointProtocol = .midi2) throws -> MIDICaptureOutcome {
        try add(stream, words, tick: tick, endpoint: endpoint, port: .midi2)
    }
}
