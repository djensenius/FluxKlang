//
//  MIDI1WireTests+Refusals.swift
//  FluxKlangTests
//
//  What MIDI1Wire refuses (#81, slice MWB1): each refusal, in the order the checks run, for the semantic and the
//  event forms. Part of the MIDI1WireTests suite.
//

import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension MIDI1WireTests {
    @Test func aChannelOutsideOneToSixteenIsRefusedForEveryKind() throws {
        for channel: UInt8 in [0, 17, 255] {
            let messages: [MIDI1Semantic] = [
                .noteOff(channel: channel, note: 60, velocity: 64),
                .noteOn(channel: channel, note: 60, velocity: 64),
                .polyphonicPressure(channel: channel, note: 60, pressure: 64),
                .controlChange(channel: channel, controller: 7, value: 64),
                .programChange(channel: channel, program: 5),
                .channelPressure(channel: channel, pressure: 5),
                .pitchBend(channel: channel, value: 8192)
            ]
            try #require(messages.count == 7)
            for message in messages {
                #expect(refusal(message) == .channelOutOfRange(channel), "\(message)")
            }
        }
        #expect(refusal(.noteOn(channel: 1, note: 60, velocity: 64)) == nil)
        #expect(refusal(.noteOn(channel: 16, note: 60, velocity: 64)) == nil)
        #expect(refusal(.pitchBend(channel: 1, value: 0)) == nil)
        #expect(refusal(.pitchBend(channel: 16, value: 0)) == nil)
    }

    @Test func theChannelIsCheckedFirst() {
        #expect(refusal(.noteOn(channel: 0, note: 0x80, velocity: 0x80)) == .channelOutOfRange(0))
        #expect(refusal(.pitchBend(channel: 17, value: 20000)) == .channelOutOfRange(17))
    }

    @Test func dataBytesAreCheckedLeftToRight() {
        #expect(refusal(.noteOn(channel: 1, note: 0x80, velocity: 0x90)) == .dataByteHigh(0x80))
        #expect(refusal(.noteOn(channel: 1, note: 0x7F, velocity: 0x90)) == .dataByteHigh(0x90))
        #expect(refusal(.noteOff(channel: 1, note: 0x80, velocity: 0x90)) == .dataByteHigh(0x80))
        #expect(refusal(.noteOff(channel: 1, note: 1, velocity: 0x90)) == .dataByteHigh(0x90))
        #expect(refusal(.polyphonicPressure(channel: 1, note: 0x81, pressure: 1)) == .dataByteHigh(0x81))
        #expect(refusal(.polyphonicPressure(channel: 1, note: 1, pressure: 0x82)) == .dataByteHigh(0x82))
        #expect(refusal(.controlChange(channel: 1, controller: 0x83, value: 1)) == .dataByteHigh(0x83))
        #expect(refusal(.controlChange(channel: 1, controller: 1, value: 0x84)) == .dataByteHigh(0x84))
        #expect(refusal(.programChange(channel: 1, program: 0x85)) == .dataByteHigh(0x85))
        #expect(refusal(.channelPressure(channel: 1, pressure: 0xFF)) == .dataByteHigh(0xFF))
    }

    @Test func pitchBendAbove16383IsRefused() {
        #expect(refusal(.pitchBend(channel: 1, value: 16384)) == .pitchBendOutOfRange(16384))
        #expect(refusal(.pitchBend(channel: 1, value: 16385)) == .pitchBendOutOfRange(16385))
        #expect(refusal(.pitchBend(channel: 1, value: 65535)) == .pitchBendOutOfRange(65535))
        #expect(refusal(.pitchBend(channel: 1, value: 16383)) == nil)
    }

    @Test func aSemanticNoteOnWithVelocityZeroIsRefused() {
        #expect(refusal(.noteOn(channel: 1, note: 60, velocity: 0)) == .noteOnVelocityZero(channel: 1, note: 60))
        #expect(refusal(.noteOn(channel: 16, note: 127, velocity: 0)) == .noteOnVelocityZero(channel: 16, note: 127))
        #expect(refusal(.noteOff(channel: 1, note: 60, velocity: 0)) == nil)
        #expect(refusal(.noteOn(channel: 1, note: 0x80, velocity: 0)) == .dataByteHigh(0x80))
    }

    @Test func unsupportedSystemCommonStatusesAreRefused() {
        for status: UInt8 in [0xF0, 0xF4, 0xF5, 0xF7, 0xF8, 0xFF, 0x00, 0x90] {
            #expect(refusal(.systemCommon(status: status, data1: 1, data2: 2)) == .unsupportedSystemCommon(status))
            #expect(refusal(.systemCommon(status: status, data1: nil, data2: nil)) == .unsupportedSystemCommon(status))
        }
    }

    @Test func systemCommonWithTheWrongNumberOfDataBytesIsRefused() throws {
        let shapes: [(status: UInt8, data: [UInt8])] = [
            (0xF1, []), (0xF1, [1, 2]), (0xF2, []), (0xF2, [1]), (0xF3, [1, 2]), (0xF6, [1]), (0xF6, [1, 2])
        ]
        try #require(shapes.count == 7)
        for shape in shapes {
            let message = MIDI1Semantic.systemCommon(
                status: shape.status, data1: shape.data.first, data2: shape.data.dropFirst().first
            )
            #expect(refusal(message) == .systemCommonDataShape(status: shape.status), "\(message)")
        }
    }

    @Test func systemCommonDataBytesMustBeBelowEighty() {
        #expect(refusal(.systemCommon(status: 0xF1, data1: 0x80, data2: nil)) == .dataByteHigh(0x80))
        #expect(refusal(.systemCommon(status: 0xF2, data1: 0x80, data2: 0)) == .dataByteHigh(0x80))
        #expect(refusal(.systemCommon(status: 0xF2, data1: 0, data2: 0x80)) == .dataByteHigh(0x80))
        #expect(refusal(.systemCommon(status: 0xF2, data1: 0x80, data2: 0x90)) == .dataByteHigh(0x80))
        #expect(refusal(.systemCommon(status: 0xF3, data1: 0xFF, data2: nil)) == .dataByteHigh(0xFF))
    }

    @Test func systemCommonChecksTheStatusThenTheShapeThenTheData() {
        #expect(refusal(.systemCommon(status: 0xF4, data1: 0x80, data2: nil)) == .unsupportedSystemCommon(0xF4))
        #expect(refusal(.systemCommon(status: 0xF2, data1: 0x80, data2: nil)) == .systemCommonDataShape(status: 0xF2))
    }

    @Test func unsupportedRealTimeStatusesAreRefused() {
        for status: UInt8 in [0xF9, 0xFD, 0xF7, 0xF0, 0x90, 0x00, 0x7F] {
            #expect(refusal(.realTime(status: status)) == .unsupportedRealTime(status))
        }
    }

    @Test func sysExReportsTheFirstPayloadByteThatIsEightyOrMore() {
        #expect(refusal(.sysEx(payload: [1, 0x80, 3, 0xF7])) == .sysExByteHigh(index: 1, byte: 0x80))
        #expect(refusal(.sysEx(payload: [0xF7])) == .sysExByteHigh(index: 0, byte: 0xF7))
        #expect(refusal(.sysEx(payload: [0xF0, 1])) == .sysExByteHigh(index: 0, byte: 0xF0))
        #expect(refusal(.sysEx(payload: [1, 2, 3, 4, 0x81])) == .sysExByteHigh(index: 4, byte: 0x81))
    }

    @Test func anEventChannelStatusOutsideEightyToEFIsRefused() {
        for status: UInt8 in [0x00, 0x7F, 0xF0, 0xF8, 0xFF] {
            #expect(refusal(event: .channel(status: status, data1: 1, data2: 2)) == .channelStatus(status))
        }
    }

    @Test func anEventChannelWithTheWrongShapeIsRefused() throws {
        let shapes: [(status: UInt8, data: [UInt8])] = [
            (0x90, [60]), (0x80, [1]), (0xA0, [1]), (0xB0, [1]), (0xE0, [1]), (0xC0, [5, 6]), (0xD0, [5, 6])
        ]
        try #require(shapes.count == 7)
        for shape in shapes {
            let data1 = try #require(shape.data.first)
            let event = MIDI1Event.channel(status: shape.status, data1: data1, data2: shape.data.dropFirst().first)
            #expect(refusal(event: event) == .channelDataShape(status: shape.status), "\(event)")
        }
    }

    @Test func eventChannelDataBytesAndTheOrderOfTheChecks() {
        #expect(refusal(event: .channel(status: 0x90, data1: 0x80, data2: 1)) == .dataByteHigh(0x80))
        #expect(refusal(event: .channel(status: 0x90, data1: 1, data2: 0x80)) == .dataByteHigh(0x80))
        #expect(refusal(event: .channel(status: 0xC0, data1: 0x80, data2: nil)) == .dataByteHigh(0x80))
        #expect(refusal(event: .channel(status: 0x7F, data1: 0x80, data2: nil)) == .channelStatus(0x7F))
        #expect(refusal(event: .channel(status: 0x90, data1: 0x80, data2: nil)) == .channelDataShape(status: 0x90))
    }

    @Test func theEventFormsRefuseExactlyLikeTheSemanticForms() {
        let cases: [(message: MIDI1Semantic, event: MIDI1Event)] = [
            (.systemCommon(status: 0xF4, data1: nil, data2: nil), .systemCommon(status: 0xF4, data1: nil, data2: nil)),
            (.systemCommon(status: 0xF7, data1: nil, data2: nil), .systemCommon(status: 0xF7, data1: nil, data2: nil)),
            (.systemCommon(status: 0xF1, data1: nil, data2: nil), .systemCommon(status: 0xF1, data1: nil, data2: nil)),
            (.systemCommon(status: 0xF6, data1: 1, data2: nil), .systemCommon(status: 0xF6, data1: 1, data2: nil)),
            (.systemCommon(status: 0xF2, data1: 0, data2: 0x80), .systemCommon(status: 0xF2, data1: 0, data2: 0x80)),
            (.systemCommon(status: 0xF3, data1: 0xFF, data2: nil),
             .systemCommon(status: 0xF3, data1: 0xFF, data2: nil)),
            (.realTime(status: 0xF9), .realTime(status: 0xF9)),
            (.realTime(status: 0x90), .realTime(status: 0x90)),
            (.sysEx(payload: [1, 0x80]), .sysEx(payload: [1, 0x80])),
            (.sysEx(payload: [0xF7]), .sysEx(payload: [0xF7]))
        ]
        for pair in cases {
            let fromMessage = refusal(pair.message)
            #expect(fromMessage != nil, "\(pair.message)")
            #expect(fromMessage == refusal(event: pair.event), "\(pair.message)")
        }
    }

    @Test func aRefusalIsAValue() {
        #expect(MIDI1WireRefusal.channelOutOfRange(0) == .channelOutOfRange(0))
        #expect(MIDI1WireRefusal.channelOutOfRange(0) != .channelOutOfRange(17))
        #expect(MIDI1WireRefusal.sysExByteHigh(index: 1, byte: 0x80) != .sysExByteHigh(index: 2, byte: 0x80))
        #expect(MIDI1WireRefusal.dataByteHigh(0x80) != .channelStatus(0x80))
        let refusals: Set<MIDI1WireRefusal> = [
            .channelOutOfRange(0), .channelOutOfRange(0), .channelOutOfRange(17),
            .sysExByteHigh(index: 1, byte: 0x80), .sysExByteHigh(index: 1, byte: 0x80)
        ]
        #expect(refusals.count == 3)
    }

    @Test func everySemanticDataBytePositionRefusesExactlyEighty() throws {
        let rows: [(accepted: MIDI1Semantic, refused: MIDI1Semantic)] = [
            (.noteOff(channel: 1, note: 0x7F, velocity: 1), .noteOff(channel: 1, note: 0x80, velocity: 1)),
            (.noteOff(channel: 1, note: 1, velocity: 0x7F), .noteOff(channel: 1, note: 1, velocity: 0x80)),
            (.noteOn(channel: 1, note: 0x7F, velocity: 1), .noteOn(channel: 1, note: 0x80, velocity: 1)),
            (.noteOn(channel: 1, note: 1, velocity: 0x7F), .noteOn(channel: 1, note: 1, velocity: 0x80)),
            (.polyphonicPressure(channel: 1, note: 0x7F, pressure: 1),
             .polyphonicPressure(channel: 1, note: 0x80, pressure: 1)),
            (.polyphonicPressure(channel: 1, note: 1, pressure: 0x7F),
             .polyphonicPressure(channel: 1, note: 1, pressure: 0x80)),
            (.controlChange(channel: 1, controller: 0x7F, value: 1),
             .controlChange(channel: 1, controller: 0x80, value: 1)),
            (.controlChange(channel: 1, controller: 1, value: 0x7F),
             .controlChange(channel: 1, controller: 1, value: 0x80)),
            (.programChange(channel: 1, program: 0x7F), .programChange(channel: 1, program: 0x80)),
            (.channelPressure(channel: 1, pressure: 0x7F), .channelPressure(channel: 1, pressure: 0x80)),
            (.systemCommon(status: 0xF1, data1: 0x7F, data2: nil),
             .systemCommon(status: 0xF1, data1: 0x80, data2: nil)),
            (.systemCommon(status: 0xF2, data1: 0x7F, data2: 1), .systemCommon(status: 0xF2, data1: 0x80, data2: 1)),
            (.systemCommon(status: 0xF2, data1: 1, data2: 0x7F), .systemCommon(status: 0xF2, data1: 1, data2: 0x80)),
            (.systemCommon(status: 0xF3, data1: 0x7F, data2: nil),
             .systemCommon(status: 0xF3, data1: 0x80, data2: nil))
        ]
        try #require(rows.count == 14)
        for row in rows {
            #expect(refusal(row.accepted) == nil, "\(row.accepted)")
            #expect(refusal(row.refused) == .dataByteHigh(0x80), "\(row.refused)")
        }
    }

    @Test func everyEventDataBytePositionRefusesExactlyEighty() throws {
        let rows: [(accepted: MIDI1Event, refused: MIDI1Event)] = [
            (.channel(status: 0x80, data1: 0x7F, data2: 1), .channel(status: 0x80, data1: 0x80, data2: 1)),
            (.channel(status: 0x80, data1: 1, data2: 0x7F), .channel(status: 0x80, data1: 1, data2: 0x80)),
            (.channel(status: 0x90, data1: 0x7F, data2: 1), .channel(status: 0x90, data1: 0x80, data2: 1)),
            (.channel(status: 0x90, data1: 1, data2: 0x7F), .channel(status: 0x90, data1: 1, data2: 0x80)),
            (.channel(status: 0xA0, data1: 0x7F, data2: 1), .channel(status: 0xA0, data1: 0x80, data2: 1)),
            (.channel(status: 0xA0, data1: 1, data2: 0x7F), .channel(status: 0xA0, data1: 1, data2: 0x80)),
            (.channel(status: 0xB0, data1: 0x7F, data2: 1), .channel(status: 0xB0, data1: 0x80, data2: 1)),
            (.channel(status: 0xB0, data1: 1, data2: 0x7F), .channel(status: 0xB0, data1: 1, data2: 0x80)),
            (.channel(status: 0xE0, data1: 0x7F, data2: 1), .channel(status: 0xE0, data1: 0x80, data2: 1)),
            (.channel(status: 0xE0, data1: 1, data2: 0x7F), .channel(status: 0xE0, data1: 1, data2: 0x80)),
            (.channel(status: 0xC0, data1: 0x7F, data2: nil), .channel(status: 0xC0, data1: 0x80, data2: nil)),
            (.channel(status: 0xD0, data1: 0x7F, data2: nil), .channel(status: 0xD0, data1: 0x80, data2: nil)),
            (.systemCommon(status: 0xF1, data1: 0x7F, data2: nil),
             .systemCommon(status: 0xF1, data1: 0x80, data2: nil)),
            (.systemCommon(status: 0xF2, data1: 0x7F, data2: 1), .systemCommon(status: 0xF2, data1: 0x80, data2: 1)),
            (.systemCommon(status: 0xF2, data1: 1, data2: 0x7F), .systemCommon(status: 0xF2, data1: 1, data2: 0x80)),
            (.systemCommon(status: 0xF3, data1: 0x7F, data2: nil),
             .systemCommon(status: 0xF3, data1: 0x80, data2: nil))
        ]
        try #require(rows.count == 16)
        for row in rows {
            #expect(refusal(event: row.accepted) == nil, "\(row.accepted)")
            #expect(refusal(event: row.refused) == .dataByteHigh(0x80), "\(row.refused)")
        }
    }

    @Test func sysExRefusesExactlyEightyAtTheFirstMiddleAndLastPosition() throws {
        let rows: [(accepted: [UInt8], refused: [UInt8])] = [
            ([0x7F, 1, 2], [0x80, 1, 2]),
            ([1, 0x7F, 2], [1, 0x80, 2]),
            ([1, 2, 0x7F], [1, 2, 0x80])
        ]
        try #require(rows.count == 3)
        for (index, row) in rows.enumerated() {
            #expect(refusal(.sysEx(payload: row.accepted)) == nil)
            #expect(refusal(event: .sysEx(payload: row.accepted)) == nil)
            let expected = MIDI1WireRefusal.sysExByteHigh(index: index, byte: 0x80)
            #expect(refusal(.sysEx(payload: row.refused)) == expected)
            #expect(refusal(event: .sysEx(payload: row.refused)) == expected)
        }
    }
}
