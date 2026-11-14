//
//  MIDI1WireTests.swift
//  FluxKlangTests
//
//  MIDI 1 wire bytes as a value (#81, slice MWB1): the byte vectors of every message, the event form, and round
//  trips through MIDI1Parser. Refusals are in MIDI1WireTests+Refusals.swift and the running-status writer is in
//  MIDI1WireTests+RunningStatus.swift. Nothing calls MIDI1Wire yet.
//

import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

@Suite("MIDI 1 wire bytes", .productionAccessAudit)
struct MIDI1WireTests {
    func events(_ bytes: [UInt8]) throws -> [MIDI1Event] {
        var parser = try #require(MIDI1Parser(maximumSysExPayloadBytes: 64))
        return bytes.compactMap { parser.consume($0) }
    }

    func refusal(_ message: MIDI1Semantic) -> MIDI1WireRefusal? {
        do {
            _ = try MIDI1Wire.bytes(message)
            return nil
        } catch {
            return error
        }
    }

    func refusal(event: MIDI1Event) -> MIDI1WireRefusal? {
        do {
            _ = try MIDI1Wire.bytes(event: event)
            return nil
        } catch {
            return error
        }
    }

    // MARK: Vectors

    @Test func noteOnVectors() throws {
        #expect(try MIDI1Wire.bytes(.noteOn(channel: 1, note: 0, velocity: 1)) == [0x90, 0x00, 0x01])
        #expect(try MIDI1Wire.bytes(.noteOn(channel: 16, note: 127, velocity: 127)) == [0x9F, 0x7F, 0x7F])
        #expect(try MIDI1Wire.bytes(.noteOn(channel: 10, note: 60, velocity: 100)) == [0x99, 0x3C, 0x64])
    }

    @Test func noteOffVectorsSendTheReleaseVelocityAsGiven() throws {
        #expect(try MIDI1Wire.bytes(.noteOff(channel: 1, note: 60, velocity: 0)) == [0x80, 0x3C, 0x00])
        #expect(try MIDI1Wire.bytes(.noteOff(channel: 1, note: 60, velocity: 100)) == [0x80, 0x3C, 0x64])
        #expect(try MIDI1Wire.bytes(.noteOff(channel: 16, note: 127, velocity: 64)) == [0x8F, 0x7F, 0x40])
    }

    @Test func polyphonicPressureAndControlChangeVectors() throws {
        #expect(try MIDI1Wire.bytes(.polyphonicPressure(channel: 2, note: 60, pressure: 100)) == [0xA1, 0x3C, 0x64])
        #expect(try MIDI1Wire.bytes(.controlChange(channel: 3, controller: 7, value: 100)) == [0xB2, 0x07, 0x64])
    }

    @Test func oneDataByteKindsHaveTwoBytes() throws {
        #expect(try MIDI1Wire.bytes(.programChange(channel: 1, program: 0)) == [0xC0, 0x00])
        #expect(try MIDI1Wire.bytes(.programChange(channel: 16, program: 127)) == [0xCF, 0x7F])
        #expect(try MIDI1Wire.bytes(.channelPressure(channel: 5, pressure: 64)) == [0xD4, 0x40])
    }

    @Test func pitchBendVectorsSendTheLeastSignificantSevenBitsFirst() throws {
        let vectors: [(message: MIDI1Semantic, bytes: [UInt8])] = [
            (.pitchBend(channel: 1, value: 0), [0xE0, 0x00, 0x00]),
            (.pitchBend(channel: 1, value: 1), [0xE0, 0x01, 0x00]),
            (.pitchBend(channel: 1, value: 127), [0xE0, 0x7F, 0x00]),
            (.pitchBend(channel: 1, value: 128), [0xE0, 0x00, 0x01]),
            (.pitchBend(channel: 1, value: 0x1234), [0xE0, 0x34, 0x24]),
            (.pitchBend(channel: 1, value: 8192), [0xE0, 0x00, 0x40]),
            (.pitchBend(channel: 1, value: 8193), [0xE0, 0x01, 0x40]),
            (.pitchBend(channel: 1, value: 16383), [0xE0, 0x7F, 0x7F]),
            (.pitchBend(channel: 16, value: 8192), [0xEF, 0x00, 0x40])
        ]
        #expect(vectors.count == 9)
        for vector in vectors {
            #expect(try MIDI1Wire.bytes(vector.message) == vector.bytes, "\(vector.message)")
        }
    }

    @Test func systemCommonVectors() throws {
        #expect(try MIDI1Wire.bytes(.systemCommon(status: 0xF1, data1: 0x77, data2: nil)) == [0xF1, 0x77])
        #expect(try MIDI1Wire.bytes(.systemCommon(status: 0xF2, data1: 0, data2: 0)) == [0xF2, 0x00, 0x00])
        #expect(try MIDI1Wire.bytes(.systemCommon(status: 0xF2, data1: 0x7F, data2: 0x7F)) == [0xF2, 0x7F, 0x7F])
        #expect(try MIDI1Wire.bytes(.systemCommon(status: 0xF2, data1: 0x10, data2: 0)) == [0xF2, 0x10, 0x00])
        #expect(try MIDI1Wire.bytes(.systemCommon(status: 0xF3, data1: 5, data2: nil)) == [0xF3, 0x05])
        #expect(try MIDI1Wire.bytes(.systemCommon(status: 0xF6, data1: nil, data2: nil)) == [0xF6])
    }

    @Test func allSixRealTimeBytes() throws {
        for status: UInt8 in [0xF8, 0xFA, 0xFB, 0xFC, 0xFE, 0xFF] {
            #expect(try MIDI1Wire.bytes(.realTime(status: status)) == [status])
        }
    }

    @Test func sysExVectors() throws {
        #expect(try MIDI1Wire.bytes(.sysEx(payload: [])) == [0xF0, 0xF7])
        #expect(try MIDI1Wire.bytes(.sysEx(payload: [0, 127])) == [0xF0, 0x00, 0x7F, 0xF7])
        let long = try MIDI1Wire.bytes(.sysEx(payload: Array(0...63)))
        #expect(long == [
            0xF0, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26,
            27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47, 48, 49, 50, 51, 52,
            53, 54, 55, 56, 57, 58, 59, 60, 61, 62, 63, 0xF7
        ])
        #expect(long.count == 66)
    }

    @Test func theEventFormEmitsExactlyWhatItHolds() throws {
        let vectors: [(event: MIDI1Event, bytes: [UInt8])] = [
            (.channel(status: 0x90, data1: 60, data2: 0), [0x90, 0x3C, 0x00]),
            (.channel(status: 0xC5, data1: 3, data2: nil), [0xC5, 0x03]),
            (.channel(status: 0xE0, data1: 0x7F, data2: 0x7F), [0xE0, 0x7F, 0x7F]),
            (.channel(status: 0x80, data1: 0, data2: 0), [0x80, 0x00, 0x00]),
            (.channel(status: 0xEF, data1: 0, data2: 0), [0xEF, 0x00, 0x00]),
            (.systemCommon(status: 0xF2, data1: 1, data2: 2), [0xF2, 0x01, 0x02]),
            (.sysEx(payload: [1, 2]), [0xF0, 0x01, 0x02, 0xF7])
        ]
        #expect(vectors.count == 7)
        for vector in vectors {
            #expect(try MIDI1Wire.bytes(event: vector.event) == vector.bytes, "\(vector.event)")
        }
    }

    @Test func bothFormsAgreeOnTheSameMessage() throws {
        let pairs: [(message: MIDI1Semantic, event: MIDI1Event)] = [
            (.noteOn(channel: 3, note: 60, velocity: 100), .channel(status: 0x92, data1: 60, data2: 100)),
            (.noteOff(channel: 1, note: 60, velocity: 64), .channel(status: 0x80, data1: 60, data2: 64)),
            (.polyphonicPressure(channel: 16, note: 1, pressure: 2), .channel(status: 0xAF, data1: 1, data2: 2)),
            (.controlChange(channel: 2, controller: 7, value: 9), .channel(status: 0xB1, data1: 7, data2: 9)),
            (.programChange(channel: 4, program: 12), .channel(status: 0xC3, data1: 12, data2: nil)),
            (.channelPressure(channel: 9, pressure: 30), .channel(status: 0xD8, data1: 30, data2: nil)),
            (.pitchBend(channel: 1, value: 0x1234), .channel(status: 0xE0, data1: 0x34, data2: 0x24)),
            (.systemCommon(status: 0xF3, data1: 5, data2: nil), .systemCommon(status: 0xF3, data1: 5, data2: nil)),
            (.realTime(status: 0xFA), .realTime(status: 0xFA)),
            (.sysEx(payload: [9, 8, 7]), .sysEx(payload: [9, 8, 7]))
        ]
        for pair in pairs {
            #expect(try MIDI1Wire.bytes(pair.message) == MIDI1Wire.bytes(event: pair.event), "\(pair.message)")
        }
    }

    // MARK: Round trips through the parser

    @Test func everyChannelMessageRoundTripsThroughTheParser() throws {
        let values: [UInt8] = [0, 1, 64, 127]
        var checked = 0
        var mismatches = 0
        for channel in UInt8(1)...16 {
            var messages: [MIDI1Semantic] = []
            for first in values {
                messages.append(.programChange(channel: channel, program: first))
                messages.append(.channelPressure(channel: channel, pressure: first))
                for second in values {
                    messages.append(.noteOff(channel: channel, note: first, velocity: second))
                    if second != 0 { messages.append(.noteOn(channel: channel, note: first, velocity: second)) }
                    messages.append(.polyphonicPressure(channel: channel, note: first, pressure: second))
                    messages.append(.controlChange(channel: channel, controller: first, value: second))
                    let bend = UInt16(first) | (UInt16(second) << 7)
                    messages.append(.pitchBend(channel: channel, value: bend))
                }
            }
            for message in messages {
                let parsed = try events(MIDI1Wire.bytes(message))
                if parsed.count != 1 || parsed.first?.semantic != message { mismatches += 1 }
                checked += 1
            }
        }
        #expect(checked == 1344)
        #expect(mismatches == 0)
    }

    @Test func everyPitchBendValueRoundTripsOnTwoChannels() throws {
        var checked = 0
        var mismatches = 0
        for channel: UInt8 in [1, 16] {
            for value in UInt16(0)...16383 {
                let message = MIDI1Semantic.pitchBend(channel: channel, value: value)
                let bytes = try MIDI1Wire.bytes(message)
                let parsed = try events(bytes)
                if bytes.count != 3 || parsed.count != 1 || parsed.first?.semantic != message { mismatches += 1 }
                checked += 1
            }
        }
        #expect(checked == 32768)
        #expect(mismatches == 0)
    }

    @Test func everyEventRoundTripsThroughTheParser() throws {
        let sample: [MIDI1Event] = [
            .channel(status: 0x80, data1: 1, data2: 2), .channel(status: 0x90, data1: 60, data2: 0),
            .channel(status: 0xA3, data1: 4, data2: 5), .channel(status: 0xB7, data1: 7, data2: 100),
            .channel(status: 0xC0, data1: 9, data2: nil), .channel(status: 0xDF, data1: 11, data2: nil),
            .channel(status: 0xE5, data1: 0x7F, data2: 0x00),
            .systemCommon(status: 0xF1, data1: 0x20, data2: nil), .systemCommon(status: 0xF2, data1: 1, data2: 2),
            .systemCommon(status: 0xF3, data1: 3, data2: nil), .systemCommon(status: 0xF6, data1: nil, data2: nil),
            .realTime(status: 0xF8), .realTime(status: 0xFA), .realTime(status: 0xFB),
            .realTime(status: 0xFC), .realTime(status: 0xFE), .realTime(status: 0xFF),
            .sysEx(payload: []), .sysEx(payload: [1, 2, 3])
        ]
        #expect(sample.count == 19)
        for event in sample {
            let parsed = try events(MIDI1Wire.bytes(event: event))
            #expect(parsed == [event], "\(event)")
        }
    }

    @Test func semanticCommonRealTimeAndSysExRoundTrip() throws {
        let messages: [MIDI1Semantic] = [
            .systemCommon(status: 0xF1, data1: 0x45, data2: nil), .systemCommon(status: 0xF2, data1: 9, data2: 8),
            .systemCommon(status: 0xF3, data1: 2, data2: nil), .systemCommon(status: 0xF6, data1: nil, data2: nil),
            .realTime(status: 0xF8), .realTime(status: 0xFF),
            .sysEx(payload: []), .sysEx(payload: [0x7E, 0x00, 0x7F])
        ]
        for message in messages {
            let parsed = try events(MIDI1Wire.bytes(message))
            #expect(parsed.map(\.semantic) == [message], "\(message)")
        }
    }
}
