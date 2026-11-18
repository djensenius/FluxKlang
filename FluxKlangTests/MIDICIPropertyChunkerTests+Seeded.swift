//
//  MIDICIPropertyChunkerTests+Seeded.swift
//  FluxKlangTests
//
//  Seeded input for `MIDICIPropertyChunker.chunks` (#83, slice M83-PXO, issue #831), checked against a reference
//  model that walks the property data chunk by chunk with the layout's constants written out (22 fixed bytes, 262,144
//  bytes, 16,383 chunks). Successful chunks are encoded, decoded and reassembled. The other cases are in
//  `MIDICIPropertyChunkerTests.swift`.
//
//  Provenance: the inputs are generated from a fixed seed and the repo's header goldens; no expected value is produced
//  by the chunker under test. The Property Exchange specifications (M2-102-UM and M2-103-UM) were not read.
//

import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension MIDICIPropertyChunkerTests {
    // MARK: Seeded input

    @Test func seededChunkingMatchesAReferenceModel() throws {
        var random = PropertyChunkerSplitMix64(state: 0x5058_4F00_0000_0831)
        var tally = PropertyChunkerTally()
        for _ in 0..<2_000 {
            try tally.check(try PropertyChunkerInput.make(using: &random))
        }
        let names: Set<String> = [
            "propertyDataNotAllowed", "propertyDataTooLong", "payloadLimitTooSmall", "tooManyChunks", "chunk"
        ]
        #expect(tally.seen == names, "\(tally.seen)")
        #expect(tally.chunked > 0)
        #expect(tally.multiChunk > 0)
        #expect(tally.roundTripped > 0)
    }
}

/// SplitMix64, private to this file so its name cannot collide in the shared test module.
private struct PropertyChunkerSplitMix64: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return mixed ^ (mixed >> 31)
    }
}

/// One call of the chunker: any kind, request id (now and then 0x80 or more), payload limit, header data and
/// property data (now and then with a byte of 0x80 or more, or long enough to reach a limit).
private struct PropertyChunkerInput {
    static let limits = [1, 22, 23, 24, 36, 47, 50, 60, 64, 100, 4_096]
    static let headers: [[UInt8]] = [
        [], [0x7B], MIDICIMessageTests.exchangeStatus200Header, MIDICIMessageTests.exchangeResourceHeader,
        MIDICIPropertyChunkerTests.mcoded7Header, [0x7B, 0x80, 0x7D], [UInt8](repeating: 0x20, count: 2_049)
    ]
    static let longCounts = [16_382, 16_383, 16_384, 262_144, 262_145]
    static let longLimits = [23, 24, 36, 4_096]

    let kind: MIDICIPropertyDataKind
    let header: MIDICIHeader
    let requestID: UInt8
    let headerData: [UInt8]
    let propertyData: [UInt8]
    let limit: Int

    static func element<Element>(
        of choices: [Element], using random: inout PropertyChunkerSplitMix64
    ) throws -> Element {
        try #require(choices.randomElement(using: &random))
    }

    static func sevenBit(_ count: Int, using random: inout PropertyChunkerSplitMix64) -> [UInt8] {
        (0..<count).map { _ in UInt8.random(in: 0...0x7F, using: &random) }
    }

    static func propertyData(using random: inout PropertyChunkerSplitMix64) throws -> [UInt8] {
        switch Int.random(in: 0..<40, using: &random) {
        case 0..<2:
            return MIDICIPropertyChunkerTests.data(try element(of: longCounts, using: &random))
        case 2..<10:
            return []
        case 10..<16:
            var bytes = sevenBit(Int.random(in: 1...400, using: &random), using: &random)
            let position = Int.random(in: 0..<bytes.count, using: &random)
            bytes[position] = UInt8.random(in: 0x80...0xFF, using: &random)
            return bytes
        default:
            return sevenBit(Int.random(in: 1...400, using: &random), using: &random)
        }
    }

    static func make(using random: inout PropertyChunkerSplitMix64) throws -> PropertyChunkerInput {
        let format = try element(of: [MIDICIFormat.ci11, .ci12], using: &random)
        let source = try element(of: [UInt32(0x80), 0x0123_4567], using: &random)
        let header = try MIDICIMessageTests.header(format, device: 0x7F, source: source, destination: 0x0FFF_FEFF)
        let highRequest = Int.random(in: 0..<10, using: &random) == 0
        let propertyData = try propertyData(using: &random)
        // Long property data meets little header data and a limit small enough to reach the chunk count limit.
        let long = propertyData.count > 16_000
        let headerData = try long || Bool.random(using: &random)
            ? element(of: long ? [[], [0x7B]] : headers, using: &random)
            : sevenBit(Int.random(in: 0...60, using: &random), using: &random)
        let limit = try long || Bool.random(using: &random)
            ? element(of: long ? longLimits : limits, using: &random)
            : Int.random(in: 1...4_096, using: &random)
        return PropertyChunkerInput(
            kind: try element(of: MIDICIPropertyChunkerTests.kinds, using: &random), header: header,
            requestID: UInt8.random(in: highRequest ? 0x80...0xFF : 0...0x7F, using: &random),
            headerData: headerData, propertyData: propertyData, limit: limit)
    }

    func outcome() throws -> Result<[MIDICIPropertyDataMessage], MIDICIPropertyChunkingRefusal> {
        try MIDICIPropertyChunkerTests.outcome(
            kind, header: header, requestID: requestID, headerData: headerData, propertyData: propertyData,
            limit: limit)
    }
}

/// The chunker rebuilt by walking the property data: the sizes of the chunks' property data, or the refusal.
private enum PropertyChunkerReference {
    static func sizes(_ input: PropertyChunkerInput) -> Result<[Int], MIDICIPropertyChunkingRefusal> {
        let dataCount = input.propertyData.count
        let headerCount = input.headerData.count
        if input.kind.hasNoPropertyData && dataCount != 0 {
            return .failure(.propertyDataNotAllowed(kind: input.kind, count: dataCount))
        }
        if dataCount > 262_144 { return .failure(.propertyDataTooLong(count: dataCount, limit: 262_144)) }
        let room = input.limit - 22
        if headerCount > room || (dataCount > 0 && room < 1) {
            let needed = 22 + max(headerCount, min(dataCount, 1))
            return .failure(.payloadLimitTooSmall(needed: needed, limit: input.limit))
        }
        let first = min(dataCount, room - headerCount)
        var sizes = [first]
        var left = dataCount - first
        while left > 0 {
            sizes.append(min(left, room))
            left -= min(left, room)
        }
        if sizes.count > 16_383 { return .failure(.tooManyChunks(count: sizes.count, limit: 16_383)) }
        if let refusal = factory(input) { return .failure(.chunk(refusal)) }
        return .success(sizes)
    }

    /// The first refusal of `MIDICIPropertyChunk.make` for any chunk, in its order: the request id, the length of
    /// the header data, a header byte, then the first property data byte of 0x80 or more.
    static func factory(_ input: PropertyChunkerInput) -> MIDICIRefusal? {
        if input.requestID >= 0x80 { return .fieldOutOfRange(.requestID, value: Int(input.requestID)) }
        if input.headerData.count > 2_048 { return .propertyHeaderTooLong(input.headerData.count) }
        if let high = input.headerData.first(where: { $0 >= 0x80 }) {
            return .fieldOutOfRange(.headerData, value: Int(high))
        }
        if let high = input.propertyData.first(where: { $0 >= 0x80 }) {
            return .fieldOutOfRange(.propertyData, value: Int(high))
        }
        return nil
    }
}

/// Chunks seeded input and checks it against `PropertyChunkerReference`; successful chunks are checked as messages.
private struct PropertyChunkerTally {
    /// Inputs that were chunked.
    var chunked = 0
    /// Inputs that gave more than one chunk.
    var multiChunk = 0
    /// Inputs whose chunks went through the codec and a reassembler (at most 256 chunks).
    var roundTripped = 0
    /// The refusals seen, by case name.
    var seen: Set<String> = []

    /// The name of a refusal's case. The switch is exhaustive, so a new case must be named here.
    static func name(of refusal: MIDICIPropertyChunkingRefusal) -> String {
        switch refusal {
        case .propertyDataNotAllowed: "propertyDataNotAllowed"
        case .propertyDataTooLong: "propertyDataTooLong"
        case .payloadLimitTooSmall: "payloadLimitTooSmall"
        case .tooManyChunks: "tooManyChunks"
        case .chunk: "chunk"
        }
    }

    mutating func check(_ input: PropertyChunkerInput) throws {
        let outcome = try input.outcome()
        #expect(outcome.map(MIDICIPropertyChunkerTests.propertySizes) == PropertyChunkerReference.sizes(input))
        switch outcome {
        case .failure(let refusal):
            seen.insert(Self.name(of: refusal))
        case .success(let messages):
            chunked += 1
            multiChunk += messages.count > 1 ? 1 : 0
            try checkMessages(messages, input)
        }
    }

    /// The envelope and header data of every chunk, the property data in order, every payload within the limit, and
    /// for at most 256 chunks the round trip.
    mutating func checkMessages(_ messages: [MIDICIPropertyDataMessage], _ input: PropertyChunkerInput) throws {
        MIDICIPropertyChunkerTests.expectEnvelope(
            messages, kind: input.kind, header: input.header, requestID: input.requestID,
            headerData: input.headerData)
        #expect(messages.flatMap(\.chunk.propertyData) == input.propertyData)
        let payloads = try MIDICIPropertyChunkerTests.payloadSizes(messages, limit: input.limit)
        #expect(payloads.allSatisfy { $0 <= input.limit })
        guard messages.count <= 256 else { return }
        let reassembly = try MIDICIPropertyChunkerTests.roundTrip(messages, limit: input.limit)
        #expect(reassembly == MIDICIPropertyReassembly(
            kind: input.kind, header: input.header, requestID: input.requestID, headerData: input.headerData,
            propertyData: input.propertyData))
        roundTripped += 1
    }
}
