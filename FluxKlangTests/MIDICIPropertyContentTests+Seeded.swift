//
//  MIDICIPropertyContentTests+Seeded.swift
//  FluxKlangTests
//
//  Seeded hostile input for `MIDICIPropertyContent.decode(_:)` (#83, slice M83-PXD, issue #828), checked against a
//  reference model built from the two stages, `MIDICIPropertyHeader.parse(_:)` and
//  `MIDICIPropertyBody.decode(_:encoding:)`. The other cases are in `MIDICIPropertyContentTests.swift`.
//
//  Provenance: the inputs are generated from a fixed seed, the repo's header goldens and `MIDICIMcoded7.encode`; no
//  expected value is produced by the decoder under test. The Property Exchange specifications (M2-102-UM and
//  M2-103-UM) were not read.
//

import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension MIDICIPropertyContentTests {
    // MARK: Hostile input

    @Test func seededContentNeverTraps() throws {
        var random = PropertyContentSplitMix64(state: 0x5058_4400_0000_0828)
        var tally = PropertyContentTally()
        for _ in 0..<3_000 {
            tally.check(try PropertyContentInput.make(using: &random))
        }
        #expect(tally.seen == ["propertyDataNotAllowed", "header", "body"], "\(tally.seen)")
        #expect(tally.decoded > 0)
        #expect(tally.skipped > 0)
    }
}

/// SplitMix64, private to this file so its name cannot collide in the shared test module.
private struct PropertyContentSplitMix64: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return mixed ^ (mixed >> 31)
    }
}

/// Hostile reassemblies: any kind, a valid header or a corrupt one, and property data that is empty, Mcoded7 (kept or
/// corrupt) or random bytes.
private enum PropertyContentInput {
    static let alphabet: [UInt8] = [0x00, 0x20, 0x22, 0x3A, 0x41, 0x7B, 0x7D, 0x7F, 0x80, 0xFF]
    static let headers: [[UInt8]] = [
        [], Array("{}".utf8), MIDICIPropertyContentTests.mcoded7Header, MIDICIPropertyContentTests.zlibHeader,
        MIDICIPropertyContentTests.asciiHeader, MIDICIPropertyContentTests.gzipHeader,
        MIDICIMessageTests.exchangeStatus200Header, MIDICIMessageTests.exchangeResourceHeader
    ]
    static let sources: [UInt32] = [0x00, 0x80, 0x0123_4567, 0x0FFF_FEFF]

    static func element<Element>(
        of choices: [Element], using random: inout PropertyContentSplitMix64
    ) throws -> Element {
        try #require(choices.randomElement(using: &random))
    }

    /// The input kept, cut short, with one byte replaced, or with one byte inserted.
    static func corrupt(_ input: [UInt8], using random: inout PropertyContentSplitMix64) throws -> [UInt8] {
        var output = input
        let position = Int.random(in: 0...input.count, using: &random)
        let byte = try element(of: alphabet, using: &random)
        switch Int.random(in: 0..<4, using: &random) {
        case 0: break
        case 1: output.removeSubrange(position...)
        case 2 where position < output.count: output[position] = byte
        default: output.insert(byte, at: position)
        }
        return output
    }

    static func propertyData(using random: inout PropertyContentSplitMix64) throws -> [UInt8] {
        var bytes: [UInt8] = []
        switch Int.random(in: 0..<3, using: &random) {
        case 0:
            return bytes
        case 1:
            for _ in 0..<Int.random(in: 0...30, using: &random) {
                bytes.append(UInt8.random(in: 0...255, using: &random))
            }
            return try corrupt(MIDICIMcoded7.encode(bytes), using: &random)
        default:
            for _ in 0..<Int.random(in: 1...20, using: &random) {
                bytes.append(try element(of: alphabet, using: &random))
            }
            return bytes
        }
    }

    static func make(using random: inout PropertyContentSplitMix64) throws -> MIDICIPropertyReassembly {
        let kind = try element(of: MIDICIPropertyContentTests.kinds, using: &random)
        let format = try element(of: [MIDICIFormat.ci11, .ci12], using: &random)
        let source = try element(of: sources, using: &random)
        let header = try MIDICIMessageTests.header(format, device: 0x7F, source: source, destination: 0x0FFF_FEFF)
        let headerData = try corrupt(try element(of: headers, using: &random), using: &random)
        return MIDICIPropertyReassembly(
            kind: kind, header: header, requestID: UInt8.random(in: 0...0x7F, using: &random),
            headerData: headerData, propertyData: try propertyData(using: &random))
    }
}

/// The decoder rebuilt from its stages: the kind rule, `MIDICIPropertyHeader.parse(_:)`, then
/// `MIDICIPropertyBody.decode(_:encoding:)` with the parsed encoding.
private enum PropertyContentReference {
    static func content(
        _ input: MIDICIPropertyReassembly
    ) -> Result<MIDICIPropertyContent, MIDICIPropertyContentRefusal> {
        let kind = input.kind
        if kind.hasNoPropertyData && !input.propertyData.isEmpty {
            return .failure(.propertyDataNotAllowed(kind: kind, count: input.propertyData.count))
        }
        let parsed: MIDICIPropertyHeader
        switch MIDICIPropertyContentTests.headerStage(input.headerData) {
        case .failure(let refusal): return .failure(.header(refusal))
        case .success(let value): parsed = value
        }
        var decoded: [UInt8] = []
        if !kind.hasNoPropertyData {
            switch MIDICIPropertyContentTests.bodyStage(input.propertyData, parsed.encoding) {
            case .failure(let refusal): return .failure(.body(refusal))
            case .success(let value): decoded = value
            }
        }
        return .success(MIDICIPropertyContent(
            kind: kind, header: input.header, requestID: input.requestID, propertyHeader: parsed, body: decoded))
    }
}

/// Decodes hostile input twice and checks the outcome against `PropertyContentReference`.
private struct PropertyContentTally {
    /// Content of a kind with property data.
    var decoded = 0
    /// Content of a kind without property data, whose body was not decoded.
    var skipped = 0
    /// The refusals seen, by case name.
    var seen: Set<String> = []

    /// The name of a refusal's case. The switch is exhaustive, so a new case must be named here.
    static func name(of refusal: MIDICIPropertyContentRefusal) -> String {
        switch refusal {
        case .propertyDataNotAllowed: "propertyDataNotAllowed"
        case .header: "header"
        case .body: "body"
        }
    }

    mutating func check(_ input: MIDICIPropertyReassembly) {
        let first = MIDICIPropertyContentTests.outcome(input)
        #expect(MIDICIPropertyContentTests.outcome(input) == first)
        #expect(first == PropertyContentReference.content(input))
        switch first {
        case .failure(let refusal):
            seen.insert(Self.name(of: refusal))
        case .success(let content):
            #expect(content.kind == input.kind && content.header == input.header)
            #expect(content.requestID == input.requestID)
            if input.kind.hasNoPropertyData {
                #expect(content.body.isEmpty)
                skipped += 1
            } else {
                decoded += 1
            }
        }
    }
}
