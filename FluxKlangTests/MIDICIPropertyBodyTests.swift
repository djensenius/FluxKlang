//
//  MIDICIPropertyBodyTests.swift
//  FluxKlangTests
//
//  Passthrough, Mcoded7 goldens, the limit, refusals, check order and hostile input for
//  `MIDICIPropertyBody.decode(_:encoding:)` and `MIDICIPropertyHeader.decodeBody(_:)` (#83, slice M83-PXH2, issue
//  #824). Nothing calls the decoder yet.
//
//  Provenance: the ASCII goldens are `MIDICIMessageTests`' own property data (`[1,2]` and the Notify's `OK`). The
//  Mcoded7 vectors are copies of `MIDICIMcoded7Tests`' vectors, which were computed from the format description by a
//  separate script; none was produced by the decoder under test. Every expected offset was counted by hand. The
//  Property Exchange specifications (M2-102-UM and M2-103-UM) were not read.
//

import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

@Suite("MIDI-CI Property Exchange body", .productionAccessAudit)
struct MIDICIPropertyBodyTests {
    typealias Refusal = MIDICIPropertyBodyRefusal

    /// The three supported encodings and one unknown name.
    static let encodings: [MIDICIPropertyEncoding] = [.ascii, .mcoded7, .zlibMcoded7, .other("")]

    /// `{"foo": [1,2,3,4,5], "bar": [6,7,8,9,0]}` and a line feed, 41 bytes (`MIDICIMcoded7Tests`' text).
    static let jsonText: [UInt8] = [
        0x7B, 0x22, 0x66, 0x6F, 0x6F, 0x22, 0x3A, 0x20, 0x5B, 0x31, 0x2C, 0x32, 0x2C, 0x33, 0x2C, 0x34, 0x2C, 0x35,
        0x5D, 0x2C, 0x20, 0x22, 0x62, 0x61, 0x72, 0x22, 0x3A, 0x20, 0x5B, 0x36, 0x2C, 0x37, 0x2C, 0x38, 0x2C, 0x39,
        0x2C, 0x30, 0x5D, 0x7D, 0x0A
    ]
    /// `jsonText` in Mcoded7, 47 bytes: six groups, every header byte 0.
    static let jsonMcoded7: [UInt8] = [
        0x00, 0x7B, 0x22, 0x66, 0x6F, 0x6F, 0x22, 0x3A,
        0x00, 0x20, 0x5B, 0x31, 0x2C, 0x32, 0x2C, 0x33,
        0x00, 0x2C, 0x34, 0x2C, 0x35, 0x5D, 0x2C, 0x20,
        0x00, 0x22, 0x62, 0x61, 0x72, 0x22, 0x3A, 0x20,
        0x00, 0x5B, 0x36, 0x2C, 0x37, 0x2C, 0x38, 0x2C,
        0x00, 0x39, 0x2C, 0x30, 0x5D, 0x7D, 0x0A
    ]

    /// The decoded bytes or the refusal.
    static func outcome(_ bytes: [UInt8], _ encoding: MIDICIPropertyEncoding) -> Result<[UInt8], Refusal> {
        do {
            return .success(try MIDICIPropertyBody.decode(bytes, encoding: encoding))
        } catch {
            return .failure(error)
        }
    }

    // MARK: Decoding

    @Test func asciiPropertyDataPassesThroughByteForByte() throws {
        let everySevenBitByte = (0...0x7F).map { UInt8($0) }
        try #require(everySevenBitByte.count == 128)
        // Control bytes and DEL are kept, and the text is not checked: `}{` and a lone NUL are not JSON.
        let inputs: [[UInt8]] = [
            MIDICIMessageTests.exchangeArrayData, [0x4F, 0x4B], [], everySevenBitByte, Self.jsonText, [0x7D, 0x7B],
            [0x00]
        ]
        for input in inputs {
            #expect(try MIDICIPropertyBody.decode(input, encoding: .ascii) == input)
        }
    }

    @Test func mcoded7PropertyDataDecodes() throws {
        try #require(Self.jsonText.count == 41)
        try #require(Self.jsonMcoded7.count == 47)
        let pairs: [(encoded: [UInt8], raw: [UInt8])] = [
            ([], []),
            (Self.jsonMcoded7, Self.jsonText),
            ([0x40, 0x25], [0xA5]),
            ([0x55, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07], [0x81, 0x02, 0x83, 0x04, 0x85, 0x06, 0x87]),
            ([0x20, 0x41, 0x42, 0x43], [0x41, 0xC2, 0x43]),
            (
                [0x55, 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x20, 0x07, 0x08],
                [0x80, 0x01, 0x82, 0x03, 0x84, 0x05, 0x86, 0x07, 0x88]
            ),
            // The header bits beyond a short final group's data are ignored, as `MIDICIMcoded7` ignores them.
            ([0x7F, 0x41], [0xC1])
        ]
        for pair in pairs {
            #expect(try MIDICIPropertyBody.decode(pair.encoded, encoding: .mcoded7) == pair.raw)
        }
        for value in 0...255 {
            let byte = UInt8(value)
            #expect(try MIDICIPropertyBody.decode(MIDICIMcoded7.encode([byte]), encoding: .mcoded7) == [byte])
        }
        for count in 0...50 {
            let bytes = (0..<count).map { UInt8(truncatingIfNeeded: $0 * 37 + 11) }
            #expect(try MIDICIPropertyBody.decode(MIDICIMcoded7.encode(bytes), encoding: .mcoded7) == bytes)
        }
    }

    // MARK: Bounds

    @Test func theBodyLimitIsInclusive() throws {
        let maximum = MIDICIPropertyBody.maximumBytes
        #expect(maximum == 262_144)
        #expect(maximum == MIDICIPropertyReassembler.propertyBytesCeiling)
        // The large outputs are checked by count and first mismatch, so a failure prints small values.
        let atLimit = [UInt8](repeating: 0x41, count: maximum)
        let ascii = try MIDICIPropertyBody.decode(atLimit, encoding: .ascii)
        let asciiMismatch = ascii.firstIndex { $0 != 0x41 }
        #expect(ascii.count == maximum)
        #expect(asciiMismatch == nil)
        // 32,768 full groups, each a header of 0x7F and seven 0x41s, decode to 229,376 bytes of 0xC1.
        let group: [UInt8] = [0x7F, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41]
        let groups = [[UInt8]](repeating: group, count: 32_768).flatMap { $0 }
        try #require(groups.count == maximum)
        let mcoded7 = try MIDICIPropertyBody.decode(groups, encoding: .mcoded7)
        let mcoded7Mismatch = mcoded7.firstIndex { $0 != 0xC1 }
        #expect(mcoded7.count == 229_376)
        #expect(mcoded7Mismatch == nil)
        #expect(Self.outcome(atLimit, .zlibMcoded7) == .failure(.invalidCompressedData))
        #expect(Self.outcome(atLimit, .other("")) == .failure(.unsupportedEncoding(.other(""))))

        // One byte more is refused in every encoding; as Mcoded7 it would also end in a lone header byte.
        for over in [atLimit + [0x41], groups + [0x41]] {
            for encoding in Self.encodings {
                #expect(Self.outcome(over, encoding) == .failure(.tooLong(count: 262_145, limit: 262_144)))
            }
        }
    }

    // MARK: Refusals

    @Test func aByteOfEightBitsIsRefusedAtTheFirstOffset() {
        let cases: [([UInt8], Int)] = [
            ([0x80], 0),
            ([0x41, 0x42, 0xFF, 0x80], 2),
            ([0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x80], 8),
            ([0x00, 0x7F, 0x80, 0x00, 0xFF, 0x00, 0x00, 0x00], 2)
        ]
        for (bytes, offset) in cases {
            #expect(Self.outcome(bytes, .ascii) == .failure(.byteHigh(offset: offset)), "\(bytes)")
            #expect(Self.outcome(bytes, .mcoded7) == .failure(.byteHigh(offset: offset)), "\(bytes)")
        }
    }

    @Test func aLoneFinalHeaderByteIsTruncated() throws {
        let fullGroup = MIDICIMcoded7.encode([UInt8](repeating: 0xA5, count: 7))
        try #require(fullGroup.count == 8)
        let inputs: [[UInt8]] = [
            [0x00], [UInt8](repeating: 0x00, count: 9), [UInt8](repeating: 0x00, count: 17), fullGroup + [0x7F]
        ]
        for input in inputs {
            #expect(Self.outcome(input, .mcoded7) == .failure(.truncatedGroup(offset: input.count - 1)))
            // The same bytes are 7-bit ASCII.
            #expect(try MIDICIPropertyBody.decode(input, encoding: .ascii) == input)
        }
    }

    @Test func zlibIsRecognisedAndValidatesMcoded7BeforeCompression() {
        #expect(MIDICIPropertyEncoding(name: "zlib+Mcoded7") == .zlibMcoded7)
        for input in [[], [0x40, 0x25], Self.jsonMcoded7] {
            #expect(Self.outcome(input, .zlibMcoded7) == .failure(.invalidCompressedData), "\(input)")
        }
        #expect(Self.outcome([0x00], .zlibMcoded7) == .failure(.truncatedGroup(offset: 0)))
        #expect(Self.outcome([0x80], .zlibMcoded7) == .failure(.byteHigh(offset: 0)))
        #expect(Self.outcome([0x00, 0xFF], .zlibMcoded7) == .failure(.byteHigh(offset: 1)))
    }

    @Test func anUnknownEncodingIsRefused() throws {
        let inputs: [[UInt8]] = [[], [0x41], [0x00], [0x40, 0x25], [0x80]]
        for name in ["ascii", "", "zlib", "MCODED7"] {
            let encoding = MIDICIPropertyEncoding(name: name)
            try #require(encoding == .other(name))
            for input in inputs {
                let outcome = Self.outcome(input, encoding)
                guard case .failure(.unsupportedEncoding(.other(let echoed))) = outcome else {
                    Issue.record("\(name) \(input): \(outcome)")
                    continue
                }
                #expect(Array(echoed.utf8) == Array(name.utf8))
            }
        }
    }

    @Test func theCheckOrderIsLengthThenEncodingThenHighByteThenTruncation() {
        // The length before the encoding and the bytes: 262,145 bytes of 0x80.
        let over = [UInt8](repeating: 0x80, count: 262_145)
        for encoding in Self.encodings + [.other("x")] {
            #expect(Self.outcome(over, encoding) == .failure(.tooLong(count: 262_145, limit: 262_144)))
        }
        // Recognized compression validates Mcoded7; an unknown encoding still wins before the bytes.
        #expect(Self.outcome([0x80], .zlibMcoded7) == .failure(.byteHigh(offset: 0)))
        #expect(Self.outcome([0x00], .zlibMcoded7) == .failure(.truncatedGroup(offset: 0)))
        #expect(Self.outcome([0x80], .other("x")) == .failure(.unsupportedEncoding(.other("x"))))
        // A high byte before the truncation: nine bytes end in a lone header byte that is itself high.
        let highAtTheEnd: [UInt8] = [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x80]
        #expect(Self.outcome(highAtTheEnd, .mcoded7) == .failure(.byteHigh(offset: 8)))
        let highEarly: [UInt8] = [0x00, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        #expect(Self.outcome(highEarly, .mcoded7) == .failure(.byteHigh(offset: 1)))
    }

    // MARK: The header

    @Test func theHeaderDecodesItsBodyWithItsEncoding() throws {
        let mcoded7 = try MIDICIPropertyHeader.parse(Array(#"{"mutualEncoding":"Mcoded7"}"#.utf8))
        try #require(mcoded7.encoding == .mcoded7)
        #expect(try mcoded7.decodeBody([0x40, 0x25]) == [0xA5])
        #expect(try mcoded7.decodeBody(Self.jsonMcoded7) == Self.jsonText)
        #expect(throws: Refusal.truncatedGroup(offset: 0)) { try mcoded7.decodeBody([0x00]) }

        // `mutualEncoding` absent is ASCII: the same bytes come back unchanged.
        let absent = try MIDICIPropertyHeader.parse(MIDICIMessageTests.exchangeStatus200Header)
        try #require(absent.encoding == .ascii)
        #expect(try absent.decodeBody([0x40, 0x25]) == [0x40, 0x25])
        let arrayData = MIDICIMessageTests.exchangeArrayData
        #expect(try MIDICIPropertyHeader().decodeBody(arrayData) == arrayData)
        #expect(throws: Refusal.byteHigh(offset: 1)) { try absent.decodeBody([0x00, 0x80]) }

        let zlib = try MIDICIPropertyHeader.parse(Array(#"{"mutualEncoding":"zlib+Mcoded7"}"#.utf8))
        try #require(zlib.encoding == .zlibMcoded7)
        #expect(throws: Refusal.invalidCompressedData) { try zlib.decodeBody([0x40, 0x25]) }
        let other = MIDICIPropertyHeader(encoding: .other("gzip"))
        #expect(throws: Refusal.unsupportedEncoding(.other("gzip"))) { try other.decodeBody([]) }
    }

    // MARK: Hostile input

    @Test func seededPropertyDataNeverTraps() throws {
        var random = PropertyBodySplitMix64(state: 0x5058_4832_0000_0083)
        let alphabet: [UInt8] = [0x00, 0x01, 0x3F, 0x40, 0x7F, 0x80, 0xFF]
        var tally = PropertyBodyTally()
        for _ in 0..<4_000 {
            let encoding = try #require(Self.encodings.randomElement(using: &random))
            var input: [UInt8] = []
            for _ in 0..<Int.random(in: 0...80, using: &random) {
                input.append(try #require(alphabet.randomElement(using: &random)))
            }
            tally.check(input, encoding)
        }
        for _ in 0..<1_000 {
            var raw: [UInt8] = []
            for _ in 0..<Int.random(in: 0...60, using: &random) {
                raw.append(UInt8.random(in: 0...255, using: &random))
            }
            let input = PropertyBodyTally.corrupt(MIDICIMcoded7.encode(raw), from: alphabet, using: &random)
            for encoding in Self.encodings {
                tally.check(input, encoding)
            }
        }
        // At the limit, outside the loops: one input of each length, for every encoding.
        let maximum = MIDICIPropertyBody.maximumBytes
        for count in [maximum - 1, maximum, maximum + 1] {
            let input = [UInt8](repeating: 0x40, count: count)
            for encoding in Self.encodings {
                tally.check(input, encoding)
            }
        }
        #expect(tally.seen == [
            "tooLong", "unsupportedEncoding", "byteHigh", "truncatedGroup", "invalidCompressedData"
        ], "\(tally.seen)")
        #expect(tally.asciiDecoded > 0)
        #expect(tally.mcoded7Decoded > 0)
    }
}

/// SplitMix64, private to this file so its name cannot collide in the shared test module.
private struct PropertyBodySplitMix64: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return mixed ^ (mixed >> 31)
    }
}

/// Decodes hostile input twice and checks the outcome against the rules and against `MIDICIMcoded7` itself.
private struct PropertyBodyTally {
    static let limit = MIDICIPropertyBody.maximumBytes
    var asciiDecoded = 0
    var mcoded7Decoded = 0
    /// The refusals seen, by case name.
    var seen: Set<String> = []

    /// The input kept, cut short, with one byte replaced, or with one byte inserted.
    static func corrupt(
        _ input: [UInt8], from alphabet: [UInt8], using random: inout PropertyBodySplitMix64
    ) -> [UInt8] {
        var output = input
        let position = Int.random(in: 0...input.count, using: &random)
        let byte = alphabet.randomElement(using: &random) ?? 0
        switch Int.random(in: 0..<4, using: &random) {
        case 0: break
        case 1: output.removeSubrange(position...)
        case 2 where position < input.count: output[position] = byte
        default: output.insert(byte, at: position)
        }
        return output
    }

    /// The name of a refusal's case. The switch is exhaustive, so a new case must be named here.
    static func name(of refusal: MIDICIPropertyBodyRefusal) -> String {
        switch refusal {
        case .tooLong: "tooLong"
        case .unsupportedEncoding: "unsupportedEncoding"
        case .byteHigh: "byteHigh"
        case .truncatedGroup: "truncatedGroup"
        case .decodedTooLong: "decodedTooLong"
        case .invalidCompressedData: "invalidCompressedData"
        }
    }

    /// `MIDICIMcoded7.decode` with its refusals renamed as the decoder renames them.
    static func reference(_ input: [UInt8]) -> Result<[UInt8], MIDICIPropertyBodyRefusal> {
        do {
            return .success(try MIDICIMcoded7.decode(input))
        } catch {
            switch error {
            case .dataByteHigh(let offset): return .failure(.byteHigh(offset: offset))
            case .truncatedGroup(let offset): return .failure(.truncatedGroup(offset: offset))
            }
        }
    }

    mutating func check(_ input: [UInt8], _ encoding: MIDICIPropertyEncoding) {
        let first = MIDICIPropertyBodyTests.outcome(input, encoding)
        #expect(MIDICIPropertyBodyTests.outcome(input, encoding) == first)
        if case .failure(let refusal) = first {
            seen.insert(Self.name(of: refusal))
        }
        if input.count > Self.limit {
            #expect(first == .failure(.tooLong(count: input.count, limit: Self.limit)))
        } else if case .other = encoding {
            #expect(first == .failure(.unsupportedEncoding(encoding)))
        } else if let high = input.firstIndex(where: { $0 >= 0x80 }) {
            #expect(first == .failure(.byteHigh(offset: high)))
        } else if encoding == .ascii {
            #expect(first == .success(input))
            asciiDecoded += 1
        } else if input.count % 8 == 1 {
            #expect(first == .failure(.truncatedGroup(offset: input.count - 1)))
        } else if encoding == .zlibMcoded7 {
            // Retain compressed cases in the seeded oracle. Independent bounded uncompress2 entry point,
            // not the body decoder's inflate helper, with the same whole-stream/trailing policy.
            switch Self.reference(input) {
            case .failure(let refusal): #expect(first == .failure(refusal))
            case .success(let compressed): #expect(first == MIDICIPropertyBodyTests.zlibReference(compressed))
            }
        } else {
            let decoded = try? first.get()
            #expect(decoded?.count == input.count - (input.count + 7) / 8)
            mcoded7Decoded += 1
        }
        if encoding == .mcoded7 && input.count <= Self.limit {
            #expect(first == Self.reference(input))
        }
    }
}
