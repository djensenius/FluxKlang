import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

struct MIDIClockMathTests {
    @Test
    func gridConstantsDivideTheQuarterExactly() {
        #expect(MIDIClockMath.ticksPerPulse == 640)
        #expect(MIDIClockMath.ticksPerPulse * MIDIClockMath.pulsesPerQuarter == MusicalTime.ticksPerQuarter)
        #expect(MIDIClockMath.ticksPerSongPositionUnit == 3_840)
        #expect(MIDIClockMath.maximumSongPositionTicks == 62_910_720)
    }

    @Test
    func pulsesConvertAtSixHundredFortyTicks() throws {
        for (pulse, ticks) in [(Int64(0), Int64(0)), (1, 640), (6, 3_840), (24, 15_360)] {
            #expect(try MIDIClockMath.ticks(forPulse: pulse) == ticks)
        }
        let last = Int64.max / 640
        #expect(try MIDIClockMath.ticks(forPulse: last) == last * 640)
        #expect(throws: MIDIClockError.positionOverflow) { try MIDIClockMath.ticks(forPulse: last + 1) }
        #expect(throws: MIDIClockError.positionOverflow) { try MIDIClockMath.ticks(forPulse: .max) }
        #expect(throws: MIDIClockError.negativePulse(-1)) { try MIDIClockMath.ticks(forPulse: -1) }
        #expect(throws: MIDIClockError.negativePulse(.min)) { try MIDIClockMath.ticks(forPulse: .min) }
    }

    @Test
    func songPositionsConvertAtThreeThousandEightHundredFortyTicks() throws {
        for (position, ticks) in [(UInt16(0), Int64(0)), (1, 3_840), (4, 15_360), (16_383, 62_910_720)] {
            #expect(try MIDIClockMath.ticks(forSongPosition: position) == ticks)
        }
        #expect(throws: MIDIClockError.songPositionOutOfRange(16_384)) {
            try MIDIClockMath.ticks(forSongPosition: 16_384)
        }
        #expect(throws: MIDIClockError.songPositionOutOfRange(65_535)) {
            try MIDIClockMath.ticks(forSongPosition: .max)
        }
    }

    @Test
    func songPositionBytesAreLeastSignificantFirst() throws {
        #expect(try MIDIClockMath.songPosition(lsb: 0x7F, msb: 0x7F) == 16_383)
        #expect(try MIDIClockMath.songPosition(lsb: 0x00, msb: 0x01) == 128)
        #expect(try MIDIClockMath.songPosition(lsb: 0x01, msb: 0x00) == 1)
        #expect(throws: MIDIClockError.invalidDataByte(0x80)) { try MIDIClockMath.songPosition(lsb: 0x80, msb: 0) }
        #expect(throws: MIDIClockError.invalidDataByte(0xFF)) { try MIDIClockMath.songPosition(lsb: 0, msb: 0xFF) }
        let bytes = try MIDIClockMath.songPositionBytes(300)
        #expect(bytes.lsb == 44 && bytes.msb == 2)
        #expect(throws: MIDIClockError.songPositionOutOfRange(16_384)) { try MIDIClockMath.songPositionBytes(16_384) }
        for position in UInt16(0)...16_383 {
            let data = try MIDIClockMath.songPositionBytes(position)
            #expect(try MIDIClockMath.songPosition(lsb: data.lsb, msb: data.msb) == position)
            let ticks = try MIDIClockMath.ticks(forSongPosition: position)
            #expect(try MIDIClockMath.songPosition(atOrBeforeTicks: ticks)
                    == MIDISongPositionSplit(position: position, remainderPulses: 0, remainderTicks: 0))
        }
    }

    @Test
    func ticksSplitIntoPointerPulsesAndTicks() throws {
        #expect(try MIDIClockMath.songPosition(atOrBeforeTicks: 62_910_719)
                == MIDISongPositionSplit(position: 16_382, remainderPulses: 5, remainderTicks: 639))
        #expect(try MIDIClockMath.songPosition(atOrBeforeTicks: 62_914_559)
                == MIDISongPositionSplit(position: 16_383, remainderPulses: 5, remainderTicks: 639))
        #expect(try MIDIClockMath.songPosition(atOrBeforeTicks: 641)
                == MIDISongPositionSplit(position: 0, remainderPulses: 1, remainderTicks: 1))
        #expect(throws: MIDIClockError.songPositionOutOfRange(16_384)) {
            try MIDIClockMath.songPosition(atOrBeforeTicks: 62_914_560)
        }
        #expect(throws: MIDIClockError.negativeTicks(-1)) { try MIDIClockMath.songPosition(atOrBeforeTicks: -1) }
        #expect(throws: MIDIClockError.songPositionOutOfRange(Int64.max / 3_840)) {
            try MIDIClockMath.songPosition(atOrBeforeTicks: .max)
        }
    }

    @Test
    func messagesMapOnlyClockSyncStatuses() throws {
        let realTime: [(UInt8, MIDIClockMessage?)] = [
            (0xF8, .clock), (0xFA, .start), (0xFB, .continue), (0xFC, .stop),
            (0xF9, nil), (0xFE, nil), (0xFF, nil)
        ]
        for (status, message) in realTime {
            #expect(try MIDIClockMessage(MIDI1Event.realTime(status: status)) == message)
            #expect(try MIDIClockMessage(MIDI1Semantic.realTime(status: status)) == message)
        }
        #expect(try MIDIClockMessage(MIDI1Event.systemCommon(status: 0xF2, data1: 0x7F, data2: 0x7F))
                == .songPosition(16_383))
        #expect(try MIDIClockMessage(MIDI1Semantic.systemCommon(status: 0xF2, data1: 2, data2: 1))
                == .songPosition(130))
        #expect(try MIDIClockMessage(MIDI1Event.systemCommon(status: 0xF3, data1: 1, data2: nil)) == nil)
        #expect(try MIDIClockMessage(MIDI1Event.systemCommon(status: 0xF1, data1: 1, data2: nil)) == nil)
        #expect(try MIDIClockMessage(MIDI1Event.channel(status: 0x90, data1: 60, data2: 1)) == nil)
        #expect(try MIDIClockMessage(MIDI1Semantic.noteOn(channel: 1, note: 60, velocity: 1)) == nil)
        #expect(throws: MIDIClockError.missingSongPositionData) {
            try MIDIClockMessage(MIDI1Event.systemCommon(status: 0xF2, data1: 1, data2: nil))
        }
        #expect(throws: MIDIClockError.invalidDataByte(0x80)) {
            try MIDIClockMessage(MIDI1Event.systemCommon(status: 0xF2, data1: 0, data2: 0x80))
        }
    }

    @Test
    func parsedBytesRoundTripThroughOutgoingMessages() throws {
        var parser = try #require(MIDI1Parser(maximumSysExPayloadBytes: 16))
        let messages: [MIDIClockMessage] = [.songPosition(16_383), .continue, .clock, .stop, .start, .songPosition(0)]
        var decoded: [MIDIClockMessage] = []
        for message in messages {
            for byte in try message.bytes() {
                if let event = parser.consume(byte), let clock = try MIDIClockMessage(event) { decoded.append(clock) }
            }
        }
        #expect(decoded == messages)
        #expect(try MIDIClockMessage.songPosition(16_383).bytes() == [0xF2, 0x7F, 0x7F])
        #expect(throws: MIDIClockError.songPositionOutOfRange(16_384)) {
            try MIDIClockMessage.songPosition(16_384).bytes()
        }
    }
}
