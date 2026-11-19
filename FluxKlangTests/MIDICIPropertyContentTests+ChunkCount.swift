//
//  MIDICIPropertyContentTests+ChunkCount.swift
//  FluxKlangTests
//
//  #846 extends #828 as local receive-content policy, not a normative receiver requirement.
//  Real codec -> reassembly -> content sequences retain count evidence. Direct malformed values exercise only
//  the content boundary. This extension belongs to the existing audited content root.
//

import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension MIDICIPropertyContentTests {
    /// Encode the unrestricted Get Reply layout, then replace its kind/device for receive-only fixtures.
    /// The strict encoder cannot emit multi-chunk Get Inquiry/Set Reply or noncanonical device IDs.
    /// Count is derived from the actual fragments, never supplied by the completion under test.
    static func receivedFragments(
        _ kind: MIDICIPropertyDataKind, format: MIDICIFormat, headerData: [UInt8],
        parts: [[UInt8]], device: UInt8 = 0x7F
    ) throws -> [MIDICIPropertyDataMessage] {
        try #require((1...3).contains(parts.count))
        let count = UInt16(parts.count)
        let header = try MIDICIMessageTests.header(
            format, device: 0x7F, source: MIDICIPropertyReassemblerTests.sourceA, destination: 0x0FFF_FEFF)
        var fragments: [MIDICIPropertyDataMessage] = []
        for (index, data) in parts.enumerated() {
            let chunk = try MIDICIPropertyChunk.make(
                requestID: 0x2A, headerData: index == 0 ? headerData : [], chunkCount: count,
                chunkNumber: UInt16(index + 1), propertyData: data)
            var wire = try MIDICIPropertyDataMessage.getReply(header, chunk).encode(limits: .standard)
            try #require(wire.count >= 22)
            wire[3] = kind.rawValue
            wire[1] = device
            let decoded = try MIDICIPropertyDataMessage.decode(payload: wire, limits: .standard)
            #expect(decoded.kind == kind)
            #expect(decoded.chunk == chunk)
            #expect(decoded.header.format == format)
            #expect(decoded.header.device.rawValue == device)
            fragments.append(decoded)
        }
        return fragments
    }

    @Test(arguments: [MIDICIPropertyDataKind.getInquiry, .setReply], [MIDICIFormat.ci11, .ci12])
    func restrictedContentRequiresOneActualChunk(kind: MIDICIPropertyDataKind, format: MIDICIFormat) throws {
        for count in 1...3 {
            let fragments = try Self.receivedFragments(
                kind, format: format, headerData: MIDICIMessageTests.exchangeStatus200Header,
                parts: [[UInt8]](repeating: [], count: count))
            var sut = try MIDICIPropertyReassembler.make()
            var complete: MIDICIPropertyReassembly?
            for (index, fragment) in fragments.enumerated() {
                complete = try sut.accept(fragment)
                if index + 1 < count {
                    #expect(complete == nil)
                    #expect(sut.openCount == 1)
                } else {
                    #expect(sut.openCount == 0)
                }
            }
            let done = try #require(complete)
            try MIDICIPropertyReassemblerTests.requireConsistentCompletion(done, fragments: fragments)
            #expect(done.chunkCount == UInt16(count))
            if count == 1 {
                #expect(Self.outcome(done) == .success(MIDICIPropertyContent(
                    kind: kind, header: done.header, requestID: 0x2A,
                    propertyHeader: MIDICIPropertyHeader(status: 200), body: [])))
            } else {
                #expect(Self.refusal(done) == .singleChunkRequired(kind: kind, chunkCount: UInt16(count)))
                let first = try #require(fragments.first)
                #expect(throws: MIDICIRefusal.singleChunkRequired(count: UInt16(count), number: 1)) {
                    try first.encode(limits: .standard)
                }
            }
        }
    }

    @Test(arguments: [MIDICIPropertyDataKind.getInquiry, .setReply], [MIDICIFormat.ci11, .ci12])
    func dataThenCountThenHeaderThroughTheCodec(kind: MIDICIPropertyDataKind, format: MIDICIFormat) throws {
        for count in 1...3 {
            for data: [UInt8] in [[], [0x41, 0x42]] {
                // Nonempty data only in the last fragment; the first header is malformed in every case.
                var parts = [[UInt8]](repeating: [], count: count)
                try #require(!parts.isEmpty)
                parts[count - 1] = data
                let fragments = try Self.receivedFragments(kind, format: format, headerData: [0x7B], parts: parts)
                let done = try Self.reassemble(fragments)
                try MIDICIPropertyReassemblerTests.requireConsistentCompletion(done, fragments: fragments)
                let expected: Refusal
                if !data.isEmpty {
                    expected = .propertyDataNotAllowed(kind: kind, count: 2)
                } else if count != 1 {
                    expected = .singleChunkRequired(kind: kind, chunkCount: UInt16(count))
                } else {
                    expected = .header(.unexpectedEnd(offset: 1))
                }
                #expect(Self.refusal(done) == expected)
            }
        }
    }

    @Test(arguments: [MIDICIPropertyDataKind.getInquiry, .setReply])
    func directlyConstructedZeroCountKeepsTheSamePrecedence(kind: MIDICIPropertyDataKind) throws {
        for headerData in [Self.bytes("{}"), [], [0x80], [UInt8](repeating: 0x80, count: 2_049)] {
            let empty = try Self.reassembly(kind, chunkCount: 0, headerData: headerData)
            #expect(Self.refusal(empty) == .singleChunkRequired(kind: kind, chunkCount: 0))
            let data = try Self.reassembly(kind, chunkCount: 0, headerData: headerData, propertyData: [0x80])
            #expect(Self.refusal(data) == .propertyDataNotAllowed(kind: kind, count: 1))
        }
    }

    @Test(arguments: [MIDICIPropertyDataKind.getInquiry, .setReply], [MIDICIFormat.ci11, .ci12])
    func countOneStillSkipsUnsupportedBodyEncoding(kind: MIDICIPropertyDataKind, format: MIDICIFormat) throws {
        let headers: [([UInt8], MIDICIPropertyEncoding)] = [
            (Self.zlibHeader, .zlibMcoded7), (Self.gzipHeader, .other("gzip")), (Self.mcoded7Header, .mcoded7)
        ]
        for (headerData, encoding) in headers {
            let fragments = try Self.receivedFragments(kind, format: format, headerData: headerData, parts: [[]])
            let done = try Self.reassemble(fragments)
            #expect(done.chunkCount == 1)
            #expect(Self.outcome(done) == .success(MIDICIPropertyContent(
                kind: kind, header: done.header, requestID: 0x2A,
                propertyHeader: MIDICIPropertyHeader(encoding: encoding), body: [])))
        }
    }

    @Test(arguments: [MIDICIFormat.ci11, .ci12])
    func otherKindsKeepMultiChunkContentAndMcoded7Cuts(format: MIDICIFormat) throws {
        for kind in Self.kinds where !kind.hasNoPropertyData {
            for count in 2...3 {
                // The two-byte Mcoded7 group 40 25 decodes to A5 even when cut between chunks.
                let parts: [[UInt8]] = count == 2 ? [[0x40], [0x25]] : [[], [0x40], [0x25]]
                let fragments = try Self.receivedFragments(
                    kind, format: format, headerData: Self.mcoded7Header, parts: parts)
                let done = try Self.reassemble(fragments)
                try MIDICIPropertyReassemblerTests.requireConsistentCompletion(done, fragments: fragments)
                #expect(Self.outcome(done) == .success(MIDICIPropertyContent(
                    kind: kind, header: done.header, requestID: 0x2A,
                    propertyHeader: MIDICIPropertyHeader(encoding: .mcoded7), body: [0xA5])))
            }
        }
    }

    @Test func otherKindsAcquireNoConstructedCountValidation() throws {
        for kind in Self.kinds where !kind.hasNoPropertyData {
            for count: UInt16 in [0, 1, 2, 3, .max] {
                let input = try Self.reassembly(kind, chunkCount: count, headerData: Self.bytes("{}"),
                                                propertyData: [0x41])
                #expect(try Self.outcome(input).get().body == [0x41])
                let header = try Self.reassembly(kind, chunkCount: count, headerData: [], propertyData: [0x80])
                #expect(Self.refusal(header) == .header(.unexpectedEnd(offset: 0)))
                let body = try Self.reassembly(
                    kind, chunkCount: count, headerData: Self.zlibHeader, propertyData: [0x80])
                #expect(Self.refusal(body) == .body(.byteHigh(offset: 0)))
            }
        }
    }

    @Test(arguments: [MIDICIPropertyDataKind.getInquiry, .setReply], [MIDICIFormat.ci11, .ci12])
    func restrictedKindsKeepNoncanonicalDeviceReceiveLeniency(
        kind: MIDICIPropertyDataKind, format: MIDICIFormat
    ) throws {
        for count in 1...3 {
            let fragments = try Self.receivedFragments(
                kind, format: format, headerData: Self.bytes("{}"),
                parts: [[UInt8]](repeating: [], count: count), device: 0x10)
            let done = try Self.reassemble(fragments)
            try MIDICIPropertyReassemblerTests.requireConsistentCompletion(done, fragments: fragments)
            #expect(done.header.device.rawValue == 0x10)
            if count == 1 {
                #expect(try Self.outcome(done).get().header == done.header)
            } else {
                #expect(Self.refusal(done) == .singleChunkRequired(kind: kind, chunkCount: UInt16(count)))
            }
        }
    }
}
