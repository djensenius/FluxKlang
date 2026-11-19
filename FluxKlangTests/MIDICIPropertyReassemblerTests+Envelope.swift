//
//  MIDICIPropertyReassemblerTests+Envelope.swift
//  FluxKlangTests
//
//  #838: intentional local receive compatibility tightening, not a standards requirement. These tests replace
//  changed-envelope success, preserve codec leniency and exercise the existing PXO codec/content pipeline.
//  The existing audited root owns this extension; no new root or live transport consumer.
//

import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension MIDICIPropertyReassemblerTests {
    enum EnvelopeChange: CaseIterable {
        case destination, device, format

        func apply(to header: MIDICIHeader) throws -> MIDICIHeader {
            var changed = header
            switch self {
            case .destination: changed.destination = try MIDICIMUID.make(0)
            case .device: changed.device = try SysExDeviceID(0x10)
            case .format: changed.format = header.format == .ci11 ? .ci12 : .ci11
            }
            return changed
        }
    }

    static func withEnvelope(
        _ message: MIDICIPropertyDataMessage, _ header: MIDICIHeader
    ) -> MIDICIPropertyDataMessage {
        .make(message.kind, header: header, chunk: message.chunk)
    }

    @Test(arguments: [MIDICIFormat.ci11, .ci12], [UInt16(2), 3])
    func consistentEnvelopesAssemble(format: MIDICIFormat, count: UInt16) throws {
        let header = try MIDICIMessageTests.header(
            format, device: 0x7F, source: Self.sourceA, destination: 0x0FFF_FEFF)
        var sut = try MIDICIPropertyReassembler.make()
        for number in 1...count {
            let message = Self.withEnvelope(try Self.chunk(
                number, of: count, data: [UInt8(number)],
                headerData: number == 1 ? Self.statusHeader : []), header)
            let done = try sut.accept(message)
            if number < count {
                #expect(done == nil)
                #expect(sut.openCount == 1)
            } else {
                #expect(done == MIDICIPropertyReassembly(
                    kind: .getReply, header: header, requestID: 0x2A, chunkCount: count, headerData: Self.statusHeader,
                    propertyData: (1...count).map { UInt8($0) }))
                #expect(sut.openCount == 0)
            }
        }
    }

    @Test(arguments: EnvelopeChange.allCases, [UInt16(2), 3])
    func changedEnvelopeDropsOnlyItsRequest(change: EnvelopeChange, number: UInt16) throws {
        let expected = try Self.header()
        let received = try change.apply(to: expected)
        var sut = try MIDICIPropertyReassembler.make()
        #expect(try sut.accept(Self.chunk(1, of: 3, data: [1], headerData: Self.statusHeader)) == nil)
        // Same source, different request: dropping one must not clear the source.
        #expect(try sut.accept(Self.chunk(1, of: 2, data: [9], request: 1)) == nil)
        if number == 3 {
            #expect(try sut.accept(Self.chunk(2, of: 3, data: [2])) == nil)
        }
        let changed = Self.withEnvelope(try Self.chunk(number, of: 3, data: [3]), received)
        #expect(Self.refusal(&sut, changed) == .envelopeChanged(expected: expected, received: received))
        #expect(sut.openCount == 1)
        #expect(Self.refusal(&sut, try Self.chunk(3, of: 3)) == .noOpenRequest(chunkNumber: 3))
        let unrelated = try #require(try sut.accept(Self.chunk(2, of: 2, data: [8], request: 1)))
        #expect(unrelated == (try Self.expected([9, 8], chunkCount: 2, request: 1, headerData: [])))
        #expect(sut.openCount == 0)
        // A fresh chunk 1 may select a new envelope; it cannot inherit the dropped prefix.
        #expect(try sut.accept(Self.withEnvelope(try Self.chunk(1, of: 2, data: [4]), received)) == nil)
        let restarted = try #require(try sut.accept(
            Self.withEnvelope(try Self.chunk(2, of: 2, data: [5]), received)))
        #expect(restarted == MIDICIPropertyReassembly(
            kind: .getReply, header: received, requestID: 0x2A, chunkCount: 2, headerData: [], propertyData: [4, 5]))
        #expect(sut.openCount == 0)
    }

    @Test func formerlyAcceptedDestinationAndFormatChangeIsNowRefused() throws {
        // Exact old threeChunksInOrder fixture: final destination 0 and CI 1.1, formerly labelled as CI 1.2.
        var sut = try MIDICIPropertyReassembler.make()
        #expect(try sut.accept(Self.chunk(1, of: 3, data: [1, 2], headerData: Self.statusHeader)) == nil)
        #expect(try sut.accept(Self.chunk(2, of: 3, data: [3])) == nil)
        let changed = try MIDICIMessageTests.header(.ci11, device: 0x7F, source: Self.sourceA, destination: 0)
        let final = Self.withEnvelope(try Self.chunk(3, of: 3, data: [4, 5]), changed)
        #expect(Self.refusal(&sut, final) == .envelopeChanged(expected: try Self.header(), received: changed))
        #expect(sut.openCount == 0)
    }

    @Test func combinedDefectsKeepTheRefusalOrder() throws {
        let expected = try Self.header()
        let received = try EnvelopeChange.destination.apply(to: expected)
        let cases: [(MIDICIPropertyDataMessage, Refusal)] = [
            (try Self.chunk(0, of: 0, headerData: [1], kind: .notify), .unknownChunkCount),
            (try Self.chunk(0, of: 4, headerData: [1], kind: .notify), .senderAbort),
            (try Self.chunk(1, of: 4, headerData: [1], kind: .notify), .alreadyOpen),
            (try Self.chunk(3, of: 4, headerData: [1], kind: .notify), .outOfOrder(expected: 2, got: 3)),
            (try Self.chunk(2, of: 4, headerData: [1], kind: .notify), .chunkCountChanged(expected: 3, got: 4)),
            (try Self.chunk(2, of: 3, headerData: [1], kind: .notify), .kindChanged(expected: .getReply, got: .notify)),
            (try Self.chunk(2, of: 3, data: [2], headerData: [1]),
             .envelopeChanged(expected: expected, received: received)),
            (try Self.chunk(2, of: 3, data: [2]), .envelopeChanged(expected: expected, received: received))
        ]
        for (message, refusal) in cases {
            // Later header data and byte overflow must not mask an envelope failure.
            var sut = try MIDICIPropertyReassembler.make(maximumPropertyBytes: 1)
            #expect(try sut.accept(Self.chunk(1, of: 3, data: [1])) == nil)
            #expect(Self.refusal(&sut, Self.withEnvelope(message, received)) == refusal)
            #expect(sut.openCount == 0)
            #expect(Self.refusal(&sut, try Self.chunk(2, of: 3)) == .noOpenRequest(chunkNumber: 2))
        }
        // A duplicate continuation still precedes envelope validation.
        var sut = try MIDICIPropertyReassembler.make()
        #expect(try sut.accept(Self.chunk(1, of: 3)) == nil)
        #expect(try sut.accept(Self.chunk(2, of: 3)) == nil)
        #expect(Self.refusal(&sut, Self.withEnvelope(try Self.chunk(2, of: 3), received))
            == .outOfOrder(expected: 3, got: 2))
        #expect(sut.openCount == 0)
    }

    @Test func sourceIsStillAKeyNotAnEnvelopeRefusal() throws {
        var sut = try MIDICIPropertyReassembler.make()
        #expect(try sut.accept(Self.chunk(1, of: 2, data: [1])) == nil)
        #expect(Self.refusal(&sut, try Self.chunk(2, of: 2, source: Self.sourceB))
            == .noOpenRequest(chunkNumber: 2))
        #expect(sut.openCount == 1)
        #expect(try sut.accept(Self.chunk(1, of: 2, data: [9], source: Self.sourceB)) == nil)
        let expected = try Self.header()
        let changed = try EnvelopeChange.device.apply(to: expected)
        #expect(Self.refusal(&sut, Self.withEnvelope(try Self.chunk(2, of: 2), changed))
            == .envelopeChanged(expected: expected, received: changed))
        #expect(sut.openCount == 1)
        let otherSource = try #require(try sut.accept(Self.chunk(2, of: 2, data: [8], source: Self.sourceB)))
        #expect(otherSource == (try Self.expected([9, 8], chunkCount: 2, source: Self.sourceB, headerData: [])))
        #expect(sut.openCount == 0)
    }

    @Test(arguments: [MIDICIFormat.ci11, .ci12])
    func consistentlyNoncanonicalDeviceIDsRemainReceiveLenient(format: MIDICIFormat) throws {
        let canonical = try MIDICIMessageTests.header(
            format, device: 0x7F, source: Self.sourceA, destination: 0x0FFF_FEFF)
        var expected = canonical
        expected.device = try SysExDeviceID(0x10)
        var sut = try MIDICIPropertyReassembler.make()
        for number: UInt16 in 1...3 {
            let message = Self.withEnvelope(try Self.chunk(number, of: 3, data: [UInt8(number)]), canonical)
            var wire = try message.encode(limits: .standard)
            try #require(wire.count > 1)
            wire[1] = 0x10 // Receive-only fixture: encoder still requires the Function Block device ID.
            let decoded = try MIDICIPropertyDataMessage.decode(payload: wire, limits: .standard)
            #expect(decoded.header == expected)
            #expect(throws: MIDICIRefusal.deviceNotFunctionBlock(0x10)) {
                try decoded.encode(limits: .standard)
            }
            let done = try sut.accept(decoded)
            if number < 3 {
                #expect(done == nil)
            } else {
                #expect(done == MIDICIPropertyReassembly(
                    kind: .getReply, header: expected, requestID: 0x2A, chunkCount: 3,
                    headerData: [], propertyData: [1, 2, 3]))
            }
        }
        #expect(sut.openCount == 0)
    }

    @Test(arguments: [MIDICIFormat.ci11, .ci12])
    func pxoMcoded7CutsKeepTheEnvelopeThroughContent(format: MIDICIFormat) throws {
        let header = try MIDICIMessageTests.header(
            format, device: 0x7F, source: Self.sourceA, destination: 0x0FFF_FEFF)
        let raw = (0...255).map { UInt8($0) }
        let coded = MIDICIMcoded7.encode(raw)
        let chunks = try MIDICIPropertyChunkerTests.cut(
            header: header, headerData: MIDICIPropertyChunkerTests.mcoded7Header, propertyData: coded, limit: 60)
        try #require(chunks.count == 9)
        #expect(chunks[0].chunk.propertyData.count == 10) // Inside an eight-byte encoding group.
        #expect(chunks.allSatisfy { $0.header == header })
        let done = try MIDICIPropertyChunkerTests.roundTrip(chunks, limit: 60)
        #expect(done.header == header)
        #expect(done.chunkCount == 9)
        #expect(done.propertyData == coded)
        let content = try MIDICIPropertyContent.decode(done)
        #expect(content.propertyHeader == MIDICIPropertyHeader(encoding: .mcoded7))
        #expect(content.body == raw)
    }

    /// Independent success invariant: inspect the submitted fragments, not the reassembler's state or header
    /// equality implementation. Checking fields separately here deliberately avoids repeating its guard.
    static func requireConsistentCompletion(
        _ done: MIDICIPropertyReassembly, fragments: [MIDICIPropertyDataMessage]
    ) throws {
        let first = try #require(fragments.first)
        #expect(done.header == first.header)
        #expect(done.kind == first.kind)
        #expect(done.requestID == first.chunk.requestID)
        #expect(Int(done.chunkCount) == fragments.count)
        #expect(done.chunkCount == first.chunk.chunkCount)
        #expect(done.headerData == first.chunk.headerData)
        #expect(done.propertyData == fragments.flatMap(\.chunk.propertyData))
        #expect(fragments.count == Int(first.chunk.chunkCount))
        for (index, fragment) in fragments.enumerated() {
            #expect(fragment.header.device == first.header.device)
            #expect(fragment.header.format == first.header.format)
            #expect(fragment.header.source == first.header.source)
            #expect(fragment.header.destination == first.header.destination)
            #expect(fragment.kind == first.kind)
            #expect(fragment.chunk.requestID == first.chunk.requestID)
            #expect(fragment.chunk.chunkCount == first.chunk.chunkCount)
            #expect(Int(fragment.chunk.chunkNumber) == index + 1)
            if index > 0 { #expect(fragment.chunk.headerData.isEmpty) }
        }
    }

    @Test func seededEnvelopeChangesCannotProduceInconsistentSuccess() throws {
        var random = SeededGenerator(state: 0x454E_5645_0000_0838)
        var successes = 0
        var changesSeen: Set<Int> = []
        var positionsSeen: Set<UInt16> = []
        // Bounded structured sequences complement the hostile shuffle: enough valid prefixes to reach the new
        // guard, plus unmodified successes that must satisfy a separate fragment-based invariant.
        for _ in 0..<512 {
            let count = UInt16.random(in: 2...3, using: &random)
            let position = UInt16.random(in: 2...count, using: &random)
            let change = Int.random(in: 0...4, using: &random)
            let format: MIDICIFormat = Bool.random(using: &random) ? .ci11 : .ci12
            let header = try MIDICIMessageTests.header(
                format, device: 0x7F, source: Self.sourceA, destination: 0x0FFF_FEFF)
            let request = UInt8.random(in: 0...0x7F, using: &random)
            var received = header
            switch change {
            case 1: received.destination = try MIDICIMUID.make(0)
            case 2: received.device = try SysExDeviceID(0x10)
            case 3: received.format = format == .ci11 ? .ci12 : .ci11
            case 4: received.source = try MIDICIMUID.make(Self.sourceB)
            default: break
            }
            var sut = try MIDICIPropertyReassembler.make()
            var fragments: [MIDICIPropertyDataMessage] = []
            for number in 1...count {
                let bytes = (0..<Int.random(in: 0...8, using: &random)).map { _ in
                    UInt8.random(in: 0...0x7F, using: &random)
                }
                let message = Self.withEnvelope(try Self.chunk(
                    number, of: count, data: bytes, headerData: number == 1 ? Self.statusHeader : [],
                    request: request), number == position ? received : header)
                var accepted = message
                let done: MIDICIPropertyReassembly?
                do {
                    done = try sut.accept(message)
                    #expect(number != position || change == 0)
                } catch {
                    #expect(number == position && change != 0)
                    let expected: Refusal = change == 4 ? .noOpenRequest(chunkNumber: number)
                        : .envelopeChanged(expected: header, received: received)
                    #expect(error == expected)
                    #expect(sut.openCount == (change == 4 ? 1 : 0))
                    changesSeen.insert(change)
                    positionsSeen.insert(number)
                    // A foreign source leaves the original prefix intact; finish it under its own envelope.
                    if change != 4 { break }
                    accepted = Self.withEnvelope(message, header)
                    done = try sut.accept(accepted)
                }
                fragments.append(accepted)
                if number == count {
                    try Self.requireConsistentCompletion(try #require(done), fragments: fragments)
                    successes += 1
                    #expect(sut.openCount == 0)
                } else {
                    #expect(done == nil)
                    #expect(sut.openCount == 1)
                }
            }
        }
        #expect(successes > 0)
        #expect(changesSeen == [1, 2, 3, 4])
        #expect(positionsSeen == [2, 3])
    }
}
