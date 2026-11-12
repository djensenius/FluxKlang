//
//  MIDICIMcoded7Tests.swift
//  FluxKlangTests
//
//  Golden vectors, round trips, refusal offsets, check order and hostile-input tests for `MIDICIMcoded7` (#83, slice
//  MCO1). Nothing calls it yet.
//
//  Provenance: the header bit order was cross-checked against the public JUCE and AM_MIDI2.0Lib sources (not against
//  the MIDI Association specification text M2-103-UM, which was not read). No byte array was copied from either
//  source; every vector below was computed from the format description by a separate script, not by the encoder.
//

import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

#if os(macOS)
@Suite("MIDI-CI Mcoded7", .productionAccessAudit)
#else
@Suite("MIDI-CI Mcoded7")
#endif
struct MIDICIMcoded7Tests {
    typealias Pair = (raw: [UInt8], encoded: [UInt8])

    /// Asserts both directions for each pair.
    private func expectPairs(_ pairs: [Pair]) throws {
        for pair in pairs {
            #expect(MIDICIMcoded7.encode(pair.raw) == pair.encoded)
            #expect(try MIDICIMcoded7.decode(pair.encoded) == pair.raw)
        }
    }

    @Test func emptyInputEncodesToEmptyOutputAndBack() throws {
        #expect(MIDICIMcoded7.encode([]) == [])
        #expect(try MIDICIMcoded7.decode([]) == [])
    }

    @Test func singleBytesCodeAsAHeaderAndALowByte() throws {
        try expectPairs([
            ([0x00], [0x00, 0x00]),
            ([0x7F], [0x00, 0x7F]),
            ([0x80], [0x40, 0x00]),
            ([0xFF], [0x40, 0x7F]),
            ([0xA5], [0x40, 0x25])
        ])
    }

    @Test func theHeaderBitFollowsThePositionOfTheHighByte() throws {
        try expectPairs([
            ([0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00], [0x40, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]),
            ([0x00, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00], [0x20, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]),
            ([0x00, 0x00, 0x80, 0x00, 0x00, 0x00, 0x00], [0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]),
            ([0x00, 0x00, 0x00, 0x80, 0x00, 0x00, 0x00], [0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]),
            ([0x00, 0x00, 0x00, 0x00, 0x80, 0x00, 0x00], [0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]),
            ([0x00, 0x00, 0x00, 0x00, 0x00, 0x80, 0x00], [0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]),
            ([0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x80], [0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        ])
    }

    @Test func aFullGroupCarriesEveryHighBit() throws {
        try expectPairs([
            (
                [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF],
                [0x7F, 0x7F, 0x7F, 0x7F, 0x7F, 0x7F, 0x7F, 0x7F]
            ),
            (
                [0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80],
                [0x7F, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
            ),
            (
                [0x7F, 0x7F, 0x7F, 0x7F, 0x7F, 0x7F, 0x7F],
                [0x00, 0x7F, 0x7F, 0x7F, 0x7F, 0x7F, 0x7F, 0x7F]
            ),
            (
                [0x81, 0x02, 0x83, 0x04, 0x85, 0x06, 0x87],
                [0x55, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07]
            )
        ])
    }

    @Test func aShortGroupLeavesTheUnusedHeaderBitsClear() throws {
        try expectPairs([
            ([0x41, 0xC2, 0x43], [0x20, 0x41, 0x42, 0x43]),
            ([0x00, 0x00, 0x00, 0x00, 0x00, 0x80], [0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        ])
    }

    @Test func groupBoundariesAndTheEncodedLength() throws {
        try expectPairs([
            (
                [0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80],
                [0x7F, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x40, 0x00]
            ),
            (
                [0x80, 0x01, 0x82, 0x03, 0x84, 0x05, 0x86, 0x07, 0x88],
                [0x55, 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x20, 0x07, 0x08]
            ),
            (
                [UInt8](repeating: 0xFF, count: 14),
                [0x7F, 0x7F, 0x7F, 0x7F, 0x7F, 0x7F, 0x7F, 0x7F, 0x7F, 0x7F, 0x7F, 0x7F, 0x7F, 0x7F, 0x7F, 0x7F]
            )
        ])
        let lengths: [(count: Int, encoded: Int)] = [
            (0, 0), (1, 2), (6, 7), (7, 8), (8, 10), (13, 15), (14, 16), (15, 18)
        ]
        for pair in lengths {
            #expect(MIDICIMcoded7.encode([UInt8](repeating: 0xC3, count: pair.count)).count == pair.encoded)
        }
    }

    @Test func anAsciiJSONTextCodesWithEveryHeaderZero() throws {
        let text: [UInt8] = [
            0x7B, 0x22, 0x66, 0x6F, 0x6F, 0x22, 0x3A, 0x20, 0x5B, 0x31, 0x2C, 0x32, 0x2C, 0x33, 0x2C, 0x34, 0x2C, 0x35,
            0x5D, 0x2C, 0x20, 0x22, 0x62, 0x61, 0x72, 0x22, 0x3A, 0x20, 0x5B, 0x36, 0x2C, 0x37, 0x2C, 0x38, 0x2C, 0x39,
            0x2C, 0x30, 0x5D, 0x7D, 0x0A
        ]
        let encoded: [UInt8] = [
            0x00, 0x7B, 0x22, 0x66, 0x6F, 0x6F, 0x22, 0x3A,
            0x00, 0x20, 0x5B, 0x31, 0x2C, 0x32, 0x2C, 0x33,
            0x00, 0x2C, 0x34, 0x2C, 0x35, 0x5D, 0x2C, 0x20,
            0x00, 0x22, 0x62, 0x61, 0x72, 0x22, 0x3A, 0x20,
            0x00, 0x5B, 0x36, 0x2C, 0x37, 0x2C, 0x38, 0x2C,
            0x00, 0x39, 0x2C, 0x30, 0x5D, 0x7D, 0x0A
        ]
        try #require(text.count == 41)
        try #require(encoded.count == 47)
        try expectPairs([(text, encoded)])
    }

    @Test func everySingleByteValueRoundTripsAsTwoLowBytes() throws {
        for value in 0...255 {
            let byte = UInt8(value)
            let encoded = MIDICIMcoded7.encode([byte])
            try #require(encoded.count == 2)
            #expect(encoded.allSatisfy { $0 < 0x80 })
            #expect(try MIDICIMcoded7.decode(encoded) == [byte])
        }
    }

    @Test func lengthsZeroToFiftyRoundTripWithTheFormulaLength() throws {
        for count in 0...50 {
            let bytes = (0..<count).map { UInt8(truncatingIfNeeded: $0 * 37 + 11) }
            let encoded = MIDICIMcoded7.encode(bytes)
            let whole = count / 7
            let rest = count % 7
            #expect(encoded.count == 8 * whole + (rest == 0 ? 0 : rest + 1))
            #expect(encoded.allSatisfy { $0 < 0x80 })
            #expect(try MIDICIMcoded7.decode(encoded) == bytes)
        }
    }

    @Test func refusalsNameTheFirstOffendingOffset() {
        #expect(throws: MIDICIMcoded7Refusal.dataByteHigh(offset: 0)) { try MIDICIMcoded7.decode([0x80]) }
        #expect(throws: MIDICIMcoded7Refusal.dataByteHigh(offset: 2)) { try MIDICIMcoded7.decode([0x00, 0x7F, 0x80]) }
        #expect(throws: MIDICIMcoded7Refusal.dataByteHigh(offset: 1)) { try MIDICIMcoded7.decode([0x00, 0x80, 0x90]) }
        #expect(throws: MIDICIMcoded7Refusal.dataByteHigh(offset: 8)) {
            try MIDICIMcoded7.decode([0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x80])
        }
        #expect(throws: MIDICIMcoded7Refusal.truncatedGroup(offset: 0)) { try MIDICIMcoded7.decode([0x00]) }
        #expect(throws: MIDICIMcoded7Refusal.truncatedGroup(offset: 8)) {
            try MIDICIMcoded7.decode([UInt8](repeating: 0x00, count: 9))
        }
        #expect(throws: MIDICIMcoded7Refusal.truncatedGroup(offset: 16)) {
            try MIDICIMcoded7.decode([UInt8](repeating: 0x00, count: 17))
        }
    }

    @Test func theHighByteCheckRunsBeforeTheTruncationCheck() {
        #expect(throws: MIDICIMcoded7Refusal.dataByteHigh(offset: 0)) { try MIDICIMcoded7.decode([0x80]) }
        #expect(throws: MIDICIMcoded7Refusal.truncatedGroup(offset: 0)) { try MIDICIMcoded7.decode([0x00]) }
        let highAtTheEnd: [UInt8] = [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x80]
        #expect(throws: MIDICIMcoded7Refusal.dataByteHigh(offset: 8)) { try MIDICIMcoded7.decode(highAtTheEnd) }
    }

    @Test func strayHeaderBitsBeyondAShortGroupAreIgnored() throws {
        #expect(try MIDICIMcoded7.decode([0x7F, 0x41]) == [0xC1])
        #expect(try MIDICIMcoded7.decode([0x7F, 0x41, 0x42]) == [0xC1, 0xC2])
        #expect(try MIDICIMcoded7.decode([0x01, 0x41, 0x42]) == [0x41, 0x42])
        #expect(try MIDICIMcoded7.decode([UInt8](repeating: 0x00, count: 8)) == [UInt8](repeating: 0x00, count: 7))
        #expect(try MIDICIMcoded7.decode([UInt8](repeating: 0x00, count: 16)) == [UInt8](repeating: 0x00, count: 14))
    }

    @Test func everyShortHostileInputDecodesOrThrowsByTheRules() throws {
        let values: [UInt8] = [0x00, 0x01, 0x40, 0x7F, 0x80, 0xFF]
        var inputs: [[UInt8]] = values.map { [$0] }
        for first in values {
            for second in values {
                inputs.append([first, second])
            }
        }
        try #require(inputs.count == 42)
        for input in inputs {
            if let offset = input.firstIndex(where: { $0 >= 0x80 }) {
                #expect(throws: MIDICIMcoded7Refusal.dataByteHigh(offset: offset)) { try MIDICIMcoded7.decode(input) }
            } else if input.count == 1 {
                #expect(throws: MIDICIMcoded7Refusal.truncatedGroup(offset: 0)) { try MIDICIMcoded7.decode(input) }
            } else {
                let header = try #require(input.first)
                let data = try #require(input.last)
                let expected: UInt8 = header & 0x40 == 0 ? data : data + 0x80
                #expect(try MIDICIMcoded7.decode(input) == [expected])
            }
        }
    }
}
