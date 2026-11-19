//
//  MIDICIPropertyReassemblerTests.swift
//  FluxKlangTests
//
//  `MIDICIPropertyReassembler` (#83, slice M83-PX1, issue #802): in-order assembly, single-chunk pass-through, every
//  refusal and that it drops the open request, source isolation, each limit exactly at and one past, `discard` and
//  `discardAll`, the factory ceilings and a seeded shuffle. Every chunk is built with `MIDICIPropertyChunk.make`;
//  the property data bytes are arbitrary 7-bit values written by hand.
//

import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

@Suite(.productionAccessAudit)
struct MIDICIPropertyReassemblerTests {
    typealias Refusal = MIDICIPropertyReassemblyRefusal

    static let sourceA: UInt32 = 0x0123_4567
    static let sourceB: UInt32 = 0x0000_0080
    /// `{"status":200}`.
    static let statusHeader: [UInt8] = [
        0x7B, 0x22, 0x73, 0x74, 0x61, 0x74, 0x75, 0x73, 0x22, 0x3A, 0x32, 0x30, 0x30, 0x7D
    ]

    static func header(source: UInt32 = sourceA, destination: UInt32 = 0x0FFF_FEFF) throws -> MIDICIHeader {
        try MIDICIMessageTests.header(.ci12, device: 0x7F, source: source, destination: destination)
    }

    /// Chunk `number` of `count` for request `request` from `source`.
    static func chunk(
        _ number: UInt16, of count: UInt16, data: [UInt8] = [], headerData: [UInt8] = [], request: UInt8 = 0x2A,
        source: UInt32 = sourceA, kind: MIDICIPropertyDataKind = .getReply
    ) throws -> MIDICIPropertyDataMessage {
        let body = try MIDICIPropertyChunk.make(
            requestID: request, headerData: headerData, chunkCount: count, chunkNumber: number, propertyData: data)
        return MIDICIPropertyDataMessage.make(kind, header: try header(source: source), chunk: body)
    }

    /// The refusal `accept` throws for `message`, or nil if it accepted it.
    static func refusal(_ sut: inout MIDICIPropertyReassembler, _ message: MIDICIPropertyDataMessage) -> Refusal? {
        do {
            _ = try sut.accept(message)
            return nil
        } catch {
            return error
        }
    }

    static func expected(
        _ data: [UInt8], chunkCount: UInt16, request: UInt8 = 0x2A, source: UInt32 = sourceA,
        headerData: [UInt8] = statusHeader
    ) throws -> MIDICIPropertyReassembly {
        MIDICIPropertyReassembly(
            kind: .getReply, header: try header(source: source), requestID: request, chunkCount: chunkCount,
            headerData: headerData,
            propertyData: data)
    }

    // MARK: Assembly

    @Test func threeChunksInOrderAssembleExactlyAndFreeTheSlot() throws {
        var sut = try MIDICIPropertyReassembler.make()
        #expect(sut.openCount == 0)
        #expect(try sut.accept(Self.chunk(1, of: 3, data: [0x01, 0x02], headerData: Self.statusHeader)) == nil)
        #expect(sut.openCount == 1)
        #expect(try sut.accept(Self.chunk(2, of: 3, data: [0x03])) == nil)
        #expect(sut.openCount == 1)
        // Changed-envelope success was intentionally retired in #838; +Envelope covers that exact regression.
        let done = try #require(try sut.accept(Self.chunk(3, of: 3, data: [0x04, 0x05])))
        #expect(done == (try Self.expected([0x01, 0x02, 0x03, 0x04, 0x05], chunkCount: 3)))
        #expect(sut.openCount == 0)
    }

    @Test func aSingleChunkPassesThroughWithoutASlot() throws {
        var sut = try MIDICIPropertyReassembler.make(maximumOpenRequests: 1)
        let single = try #require(
            try sut.accept(Self.chunk(1, of: 1, data: [0x4F, 0x4B], headerData: Self.statusHeader)))
        #expect(single == (try Self.expected([0x4F, 0x4B], chunkCount: 1)))
        #expect(sut.openCount == 0)
        #expect(try sut.accept(Self.chunk(1, of: 2, data: [0x01], request: 0x01)) == nil)
        #expect(sut.openCount == 1)
        let full = try #require(try sut.accept(Self.chunk(1, of: 1, data: [0x02], headerData: Self.statusHeader)))
        #expect(full == (try Self.expected([0x02], chunkCount: 1)))
        #expect(sut.openCount == 1)
        // A kind with no property data (Table 33) passes through like any single chunk.
        let inquiry = try #require(try sut.accept(
            Self.chunk(1, of: 1, headerData: Self.statusHeader, request: 0x05, kind: .getInquiry)))
        #expect(inquiry == MIDICIPropertyReassembly(
            kind: .getInquiry, header: try Self.header(), requestID: 0x05, chunkCount: 1, headerData: Self.statusHeader,
            propertyData: []))
        #expect(sut.openCount == 1)
    }

    // MARK: Order

    @Test func aDuplicateChunkIsOutOfOrderAndDropsTheRequest() throws {
        var sut = try MIDICIPropertyReassembler.make()
        #expect(try sut.accept(Self.chunk(1, of: 3, data: [0x01])) == nil)
        #expect(try sut.accept(Self.chunk(2, of: 3, data: [0x02])) == nil)
        #expect(Self.refusal(&sut, try Self.chunk(2, of: 3, data: [0x02])) == .outOfOrder(expected: 3, got: 2))
        #expect(sut.openCount == 0)
        #expect(Self.refusal(&sut, try Self.chunk(3, of: 3, data: [0x03])) == .noOpenRequest(chunkNumber: 3))
    }

    @Test func aSkippedChunkIsOutOfOrder() throws {
        var sut = try MIDICIPropertyReassembler.make()
        #expect(try sut.accept(Self.chunk(1, of: 3, data: [0x01])) == nil)
        #expect(Self.refusal(&sut, try Self.chunk(3, of: 3, data: [0x03])) == .outOfOrder(expected: 2, got: 3))
        #expect(sut.openCount == 0)
    }

    @Test func aChangedChunkCountIsRefusedAndDropsTheRequest() throws {
        var sut = try MIDICIPropertyReassembler.make()
        #expect(try sut.accept(Self.chunk(1, of: 3, data: [0x01])) == nil)
        #expect(Self.refusal(&sut, try Self.chunk(2, of: 4, data: [0x02])) == .chunkCountChanged(expected: 3, got: 4))
        #expect(sut.openCount == 0)
    }

    @Test func everyOtherRefusalForAnOpenRequestDropsIt() throws {
        let cases: [(MIDICIPropertyDataMessage, Refusal)] = [
            (try Self.chunk(1, of: 3), .alreadyOpen),
            (try Self.chunk(2, of: 3, kind: .notify), .kindChanged(expected: .getReply, got: .notify)),
            (try Self.chunk(2, of: 3, headerData: [0x7B, 0x7D]), .headerAfterFirstChunk(chunkNumber: 2)),
            (try Self.chunk(1, of: 0), .unknownChunkCount),
            (try Self.chunk(0, of: 3), .senderAbort)
        ]
        for (message, refusal) in cases {
            var sut = try MIDICIPropertyReassembler.make()
            #expect(try sut.accept(Self.chunk(1, of: 3, data: [0x01])) == nil)
            #expect(try sut.accept(Self.chunk(1, of: 2, request: 0x01)) == nil)
            #expect(Self.refusal(&sut, message) == refusal)
            #expect(sut.openCount == 1)
            #expect(Self.refusal(&sut, try Self.chunk(2, of: 3)) == .noOpenRequest(chunkNumber: 2))
        }
    }

    @Test func aChunkAfterCompletionHasNoOpenRequest() throws {
        var sut = try MIDICIPropertyReassembler.make()
        #expect(try sut.accept(Self.chunk(1, of: 2, data: [0x01])) == nil)
        #expect(try sut.accept(Self.chunk(2, of: 2, data: [0x02])) != nil)
        #expect(Self.refusal(&sut, try Self.chunk(2, of: 2, data: [0x02])) == .noOpenRequest(chunkNumber: 2))
        #expect(sut.openCount == 0)
    }

    @Test func anUnknownRequestIDHasNoOpenRequestAndLeavesTheOthers() throws {
        var sut = try MIDICIPropertyReassembler.make()
        #expect(try sut.accept(Self.chunk(1, of: 2, request: 0x01)) == nil)
        #expect(Self.refusal(&sut, try Self.chunk(2, of: 2, request: 0x02)) == .noOpenRequest(chunkNumber: 2))
        #expect(sut.openCount == 1)
    }

    @Test func countZeroIsRefusedAndNumberZeroAborts() throws {
        var sut = try MIDICIPropertyReassembler.make()
        #expect(Self.refusal(&sut, try Self.chunk(1, of: 0, data: [0x01])) == .unknownChunkCount)
        #expect(Self.refusal(&sut, try Self.chunk(0, of: 0)) == .unknownChunkCount)
        #expect(Self.refusal(&sut, try Self.chunk(0, of: 2)) == .senderAbort)
        #expect(sut.openCount == 0)
        #expect(try sut.accept(Self.chunk(1, of: 2, data: [0x01])) == nil)
        #expect(Self.refusal(&sut, try Self.chunk(0, of: 2)) == .senderAbort)
        #expect(sut.openCount == 0)
        #expect(Self.refusal(&sut, try Self.chunk(2, of: 2)) == .noOpenRequest(chunkNumber: 2))
    }

    @Test func theSameRequestIDFromTwoSourcesStaysApart() throws {
        var sut = try MIDICIPropertyReassembler.make()
        #expect(try sut.accept(Self.chunk(1, of: 2, data: [0x01], headerData: Self.statusHeader)) == nil)
        #expect(try sut.accept(Self.chunk(1, of: 2, data: [0x09], source: Self.sourceB)) == nil)
        #expect(sut.openCount == 2)
        let first = try #require(try sut.accept(Self.chunk(2, of: 2, data: [0x02])))
        #expect(first == (try Self.expected([0x01, 0x02], chunkCount: 2)))
        #expect(sut.openCount == 1)
        let second = try #require(try sut.accept(Self.chunk(2, of: 2, data: [0x08], source: Self.sourceB)))
        #expect(second == (try Self.expected([0x09, 0x08], chunkCount: 2, source: Self.sourceB, headerData: [])))
        #expect(sut.openCount == 0)
    }

    // MARK: Limits

    @Test func thePropertyByteLimitIsInclusive() throws {
        var sut = try MIDICIPropertyReassembler.make(maximumPropertyBytes: 5)
        let five: [UInt8] = [0x01, 0x02, 0x03, 0x04, 0x05]
        #expect(try sut.accept(Self.chunk(1, of: 1, data: five)) != nil)
        #expect(Self.refusal(&sut, try Self.chunk(1, of: 1, data: five + [0x06])) == .tooManyBytes(total: 6, limit: 5))
        #expect(Self.refusal(&sut, try Self.chunk(1, of: 2, data: five + [0x06])) == .tooManyBytes(total: 6, limit: 5))
        #expect(sut.openCount == 0)
        #expect(try sut.accept(Self.chunk(1, of: 2, data: [0x01, 0x02, 0x03])) == nil)
        let done = try #require(try sut.accept(Self.chunk(2, of: 2, data: [0x04, 0x05])))
        #expect(done.propertyData == five)
        #expect(try sut.accept(Self.chunk(1, of: 2, data: [0x01, 0x02, 0x03])) == nil)
        #expect(Self.refusal(&sut, try Self.chunk(2, of: 2, data: [0x04, 0x05, 0x06]))
            == .tooManyBytes(total: 6, limit: 5))
        #expect(sut.openCount == 0)
    }

    @Test func theChunkLimitIsInclusive() throws {
        var sut = try MIDICIPropertyReassembler.make(maximumChunks: 3)
        #expect(Self.refusal(&sut, try Self.chunk(1, of: 4, request: 0x01)) == .tooManyChunks(count: 4, limit: 3))
        #expect(sut.openCount == 0)
        for number: UInt16 in 1...2 {
            #expect(try sut.accept(Self.chunk(number, of: 3, data: [UInt8(number)])) == nil)
        }
        let done = try #require(try sut.accept(Self.chunk(3, of: 3, data: [0x03])))
        #expect(done.propertyData == [0x01, 0x02, 0x03])
        #expect(sut.openCount == 0)
    }

    @Test func theOpenRequestLimitIsInclusiveAndKeepsTheOthers() throws {
        var sut = try MIDICIPropertyReassembler.make(maximumOpenRequests: 2)
        #expect(try sut.accept(Self.chunk(1, of: 2, data: [0x01], request: 0x01)) == nil)
        #expect(try sut.accept(Self.chunk(1, of: 2, data: [0x02], request: 0x02)) == nil)
        #expect(sut.openCount == 2)
        #expect(Self.refusal(&sut, try Self.chunk(1, of: 2, request: 0x03)) == .tooManyOpenRequests(limit: 2))
        #expect(sut.openCount == 2)
        let first = try #require(try sut.accept(Self.chunk(2, of: 2, data: [0x11], request: 0x01)))
        #expect(first == (try Self.expected([0x01, 0x11], chunkCount: 2, request: 0x01, headerData: [])))
        let second = try #require(try sut.accept(Self.chunk(2, of: 2, data: [0x12], request: 0x02)))
        #expect(second == (try Self.expected([0x02, 0x12], chunkCount: 2, request: 0x02, headerData: [])))
        #expect(sut.openCount == 0)
        #expect(Self.refusal(&sut, try Self.chunk(2, of: 2, request: 0x03)) == .noOpenRequest(chunkNumber: 2))
    }

    // MARK: Discard

    @Test func discardAndDiscardAllFreeSlotsAndReportCounts() throws {
        var sut = try MIDICIPropertyReassembler.make()
        let sourceA = try MIDICIMUID.make(Self.sourceA)
        let sourceB = try MIDICIMUID.make(Self.sourceB)
        #expect(try sut.accept(Self.chunk(1, of: 2, request: 0x01)) == nil)
        #expect(try sut.accept(Self.chunk(1, of: 2, request: 0x02)) == nil)
        #expect(try sut.accept(Self.chunk(1, of: 2, request: 0x01, source: Self.sourceB)) == nil)
        #expect(sut.openCount == 3)
        let discarded = sut.discard(source: sourceA, requestID: 0x01)
        let again = sut.discard(source: sourceA, requestID: 0x01)
        #expect(discarded)
        #expect(!again)
        #expect(sut.openCount == 2)
        #expect(sut.discardAll(source: sourceA) == 1)
        #expect(sut.discardAll(source: sourceA) == 0)
        #expect(sut.openCount == 1)
        #expect(Self.refusal(&sut, try Self.chunk(2, of: 2, request: 0x02)) == .noOpenRequest(chunkNumber: 2))
        let last = sut.discard(source: sourceB, requestID: 0x01)
        #expect(last)
        #expect(sut.openCount == 0)
        #expect(sut.discardAll(source: sourceB) == 0)
    }

    // MARK: Factory

    /// Factory arguments, the defaults unless given.
    struct Limits {
        var open = 8
        var chunks = 64
        var bytes = 65_536
    }

    @Test func theFactoryRefusesLimitsOutsideTheCeilings() throws {
        let defaults = try MIDICIPropertyReassembler.make()
        #expect(defaults.maximumOpenRequests == 8)
        #expect(defaults.maximumChunks == 64)
        #expect(defaults.maximumPropertyBytes == 65_536)
        let lowest = try MIDICIPropertyReassembler.make(
            maximumOpenRequests: 1, maximumChunks: 1, maximumPropertyBytes: 1)
        #expect(lowest.openCount == 0)
        let highest = try MIDICIPropertyReassembler.make(
            maximumOpenRequests: 127, maximumChunks: 256, maximumPropertyBytes: 262_144)
        #expect(highest.maximumPropertyBytes == 262_144)
        let refused: [(Limits, Refusal)] = [
            (Limits(open: 0), .limitOutOfRange(.openRequests, value: 0)),
            (Limits(open: 128), .limitOutOfRange(.openRequests, value: 128)),
            (Limits(chunks: 0), .limitOutOfRange(.chunks, value: 0)),
            (Limits(chunks: 257), .limitOutOfRange(.chunks, value: 257)),
            (Limits(bytes: 0), .limitOutOfRange(.propertyBytes, value: 0)),
            (Limits(bytes: 262_145), .limitOutOfRange(.propertyBytes, value: 262_145)),
            (Limits(open: -1, chunks: -1, bytes: -1), .limitOutOfRange(.openRequests, value: -1))
        ]
        for (limits, refusal) in refused {
            #expect(throws: refusal) {
                try MIDICIPropertyReassembler.make(
                    maximumOpenRequests: limits.open, maximumChunks: limits.chunks, maximumPropertyBytes: limits.bytes)
            }
        }
    }

    // MARK: Hostile input

    /// SplitMix64, so the shuffle is the same on every run.
    struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var mixed = state
            mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
            mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
            return mixed ^ (mixed >> 31)
        }
    }

    @Test func aSeededShuffleNeverTrapsAndNeverExceedsTheLimits() throws {
        var random = SeededGenerator(state: 0x5058_3120_0000_0802)
        var sut = try MIDICIPropertyReassembler.make(maximumOpenRequests: 3, maximumChunks: 4, maximumPropertyBytes: 6)
        let sources = [Self.sourceA, Self.sourceB]
        let kinds: [MIDICIPropertyDataKind] = [.getReply, .notify]
        var completed = 0, refused = 0
        for _ in 0..<5_000 {
            if UInt8.random(in: 0..<50, using: &random) == 0 {
                _ = sut.discardAll(source: try MIDICIMUID.make(sources.randomElement(using: &random) ?? Self.sourceA))
                continue
            }
            let length = Int.random(in: 0...4, using: &random)
            let message = try Self.chunk(
                UInt16.random(in: 0...5, using: &random), of: UInt16.random(in: 0...5, using: &random),
                data: (0..<length).map { _ in UInt8.random(in: 0...0x7F, using: &random) },
                headerData: Bool.random(using: &random) ? [] : [0x7B, 0x7D],
                request: UInt8.random(in: 0...2, using: &random),
                source: sources.randomElement(using: &random) ?? Self.sourceA,
                kind: kinds.randomElement(using: &random) ?? .getReply)
            do {
                if let done = try sut.accept(message) {
                    completed += 1
                    #expect(done.propertyData.count <= 6)
                }
            } catch {
                refused += 1
                if case .chunkNumberAboveCount = error { Issue.record("checks 3 and 5 come first") }
                if case .limitOutOfRange = error { Issue.record("accept never refuses a limit") }
            }
            #expect(sut.openCount <= 3)
        }
        #expect(completed > 0)
        #expect(refused > 0)
    }
}
