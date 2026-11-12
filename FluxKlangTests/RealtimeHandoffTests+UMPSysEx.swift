import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

private typealias Root = RealtimeHandoffTests

// MARK: - UMP SysEx7 (MT 0x3) to SysExAssembler bridge (#83 UKB1)

extension RealtimeHandoffTests {
    struct SysExUMPBridge {
        /// The six lanes of a chunk tuple as an array, so lanes past `count` can be compared too.
        private static func lanes(_ bytes: SysExChunkBytes) -> [UInt8] {
            [bytes.0, bytes.1, bytes.2, bytes.3, bytes.4, bytes.5]
        }

        /// Every status nibble on the wire (M2-104-UM, MT 0x3) maps to the kernel status with the same wire value,
        /// and back.
        @Test func statusMapsBothWaysOnWireValues() throws {
            // swiftlint:disable:next large_tuple
            let wire: [(nibble: UInt8, ump: UMPSysEx7Status, kernel: SysExChunkStatus)] = [
                (0x0, .complete, .complete), (0x1, .start, .start), (0x2, .continue, .continue), (0x3, .end, .end)
            ]
            #expect(wire.count == UMPSysEx7Status.allCases.count && wire.count == SysExChunkStatus.allCases.count)
            for (nibble, ump, kernel) in wire {
                #expect(SysExChunkStatus(ump) == kernel && SysExChunkStatus(ump).rawValue == nibble)
                #expect(UMPSysEx7Status(kernel) == ump && UMPSysEx7Status(kernel).rawValue == nibble)
                // The nibble decoded from raw words reaches the kernel unchanged.
                let decoded = try UMPSysEx7Packet(decoding: UMPPacket(words: [0x3000_0000 | UInt32(nibble) << 20, 0]))
                #expect(SysExChunk(decoded).status.rawValue == nibble)
            }
            for status in SysExChunkStatus.allCases {
                #expect(SysExChunkStatus(UMPSysEx7Status(status)) == status)
            }
            for status in UMPSysEx7Status.allCases {
                #expect(UMPSysEx7Status(SysExChunkStatus(status)) == status)
            }
        }

        /// Counts 0...6: the bytes land in the first `count` lanes and every lane past `count` is zero.
        @Test(arguments: 0...6)
        func packetBecomesZeroFilledChunk(count: Int) throws {
            let bytes = (0..<count).map { UInt8(0x41 + $0) }
            for status in UMPSysEx7Status.allCases {
                let packet = try UMPSysEx7Packet(group: UMPGroup(7), status: status, bytes: bytes)
                let chunk = SysExChunk(packet)
                #expect(chunk.status == SysExChunkStatus(status))
                #expect(chunk.count == UInt8(count))
                #expect(Self.lanes(chunk.bytes) == bytes + Array(repeating: 0, count: 6 - count))
            }
        }

        /// The group never selects the source: the same chunk comes out for every group.
        @Test func groupDoesNotAffectChunk() throws {
            let expected = SysExChunk(try UMPSysEx7Packet(group: UMPGroup(0), status: .start, bytes: [1, 2, 3]))
            for group in UInt8(0)...15 {
                let chunk = SysExChunk(try UMPSysEx7Packet(group: UMPGroup(group), status: .start, bytes: [1, 2, 3]))
                #expect(chunk.status == expected.status && chunk.count == expected.count)
                #expect(Self.lanes(chunk.bytes) == Self.lanes(expected.bytes))
            }
        }

        /// Split by the codec, bridged, assembled: the delivered bytes are exactly the payload.
        @Test(arguments: [0, 1, 6, 7, 12, 13, SysExAssembler.defaultMaximumMessageBytes])
        func splitPayloadAssemblesExactly(length: Int) throws {
            let maximum = SysExAssembler.defaultMaximumMessageBytes
            let fixture = try SysExFixture(maximum: maximum, pool: maximum * 2)
            let payload = Root.sysexMessage(UInt64(length), length: length)
            let packets = try UMPSysEx7Packet.packets(group: UMPGroup(3), payload: payload)
            #expect(packets.count == max(1, (length + 5) / 6))
            let statuses = packets.map { fixture.assembler.accept(source: 2, packet: $0, frame: 11) }
            #expect(statuses.allSatisfy { $0 == .ok })
            let messages = fixture.drain()
            let delivered = try #require(messages.first)
            #expect(messages.count == 1)
            #expect(delivered.bytes == payload && Int(delivered.ref.length) == length)
            #expect(delivered.ref.source == 2)
            #expect(fixture.assembler.emittedCount == 1 && fixture.assembler.discardedCount == 0)
            #expect(fixture.takeFaults().isEmpty)
        }

        /// Hand-written MT 0x3 words on group 5, decoded and bridged: the message assembles on the caller's source 1.
        @Test func decodedWordsAssembleOnCallerSource() throws {
            let words: [[UInt32]] = [
                [0x3516_7E7F, 0x0601_1011], // start, 6 bytes
                [0x3526_1213, 0x1415_1617], // continue, 6 bytes
                [0x3532_2021, 0x0000_0000] // end, 2 bytes
            ]
            let payload: [UInt8] = [0x7E, 0x7F, 0x06, 0x01, 0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x20, 0x21]
            let fixture = try SysExFixture()
            for pair in words {
                let packet = try UMPSysEx7Packet(decoding: UMPPacket(words: pair))
                #expect(packet.group.value == 5)
                #expect(fixture.assembler.accept(source: 1, packet: packet) == .ok)
            }
            let delivered = try #require(fixture.drain().first)
            #expect(delivered.bytes == payload && delivered.ref.source == 1)
            #expect(fixture.takeFaults().isEmpty)
        }

        /// A payload over the assembler maximum is discarded whole with `.sysexOverflow`, never truncated; the
        /// source then assembles the next message normally.
        @Test func oversizedPayloadOverflowsWithoutTruncation() throws {
            let fixture = try SysExFixture(maximum: 12)
            let oversized = Root.sysexMessage(1, length: 25)
            let packets = try UMPSysEx7Packet.packets(group: UMPGroup(0), payload: oversized)
            let statuses = packets.map { fixture.assembler.accept(source: 3, packet: $0, frame: 4) }
            #expect(statuses == [.ok, .ok, .refused(.invalidLength), .refused(.invalidLength),
                                 .refused(.invalidLength)])
            #expect(fixture.drain().isEmpty)
            #expect(fixture.assembler.emittedCount == 0 && fixture.assembler.discardedCount == 1)
            #expect(fixture.takeFaults() == [FaultRecord(scope: fixture.scope(3), kind: .sysexOverflow, count: 1,
                                                         firstFrame: 4)])
            // One byte over in a single complete packet is refused too.
            let tiny = try SysExFixture(maximum: 4)
            let five = try UMPSysEx7Packet.packets(group: UMPGroup(0), payload: [1, 2, 3, 4, 5])
            #expect(five.map { tiny.assembler.accept(source: 0, packet: $0) } == [.refused(.invalidLength)])
            #expect(tiny.drain().isEmpty && tiny.assembler.discardedCount == 1)
            #expect(tiny.takeFaults().map(\.kind) == [.sysexOverflow])
            // The next message on the overflowed source is whole.
            let next = Root.sysexMessage(2, length: 12)
            let nextPackets = try UMPSysEx7Packet.packets(group: UMPGroup(0), payload: next)
            #expect(nextPackets.map { fixture.assembler.accept(source: 3, packet: $0) } == [.ok, .ok])
            let delivered = try #require(fixture.drain().first)
            #expect(delivered.bytes == next && delivered.ref.source == 3)
        }

        /// Two sources whose packets alternate (on the same group) each assemble their own message.
        @Test func interleavedSourcesAssembleBoth() throws {
            let fixture = try SysExFixture()
            let first = Root.sysexMessage(10, length: 20)
            let second = Root.sysexMessage(11, length: 13)
            let firstPackets = try UMPSysEx7Packet.packets(group: UMPGroup(9), payload: first)
            let secondPackets = try UMPSysEx7Packet.packets(group: UMPGroup(9), payload: second)
            #expect(firstPackets.count == 4 && secondPackets.count == 3)
            var statuses: [KernelStatus] = []
            for index in 0..<max(firstPackets.count, secondPackets.count) {
                if index < firstPackets.count {
                    statuses.append(fixture.assembler.accept(source: 0, packet: firstPackets[index]))
                }
                if index < secondPackets.count {
                    statuses.append(fixture.assembler.accept(source: 1, packet: secondPackets[index]))
                }
            }
            #expect(statuses.count == 7 && statuses.allSatisfy { $0 == .ok })
            let messages = fixture.drain()
            try #require(messages.count == 2)
            // Source 1's end arrives first (its third packet precedes source 0's fourth).
            #expect(messages.map(\.ref.source) == [1, 0])
            #expect(messages[0].bytes == second && messages[1].bytes == first)
            #expect(fixture.takeFaults().isEmpty)
        }

        /// The packet overload keeps the raw `accept` refusals: an unknown source changes nothing.
        @Test func packetOverloadKeepsRefusals() throws {
            let fixture = try SysExFixture(sources: 2)
            let packet = try UMPSysEx7Packet(group: UMPGroup(0), status: .complete, bytes: [1])
            #expect(fixture.assembler.accept(source: 2, packet: packet) == .refused(.slotOutOfRange))
            let orphan = try UMPSysEx7Packet(group: UMPGroup(0), status: .continue, bytes: [1])
            #expect(fixture.assembler.accept(source: 0, packet: orphan, frame: 8) == .refused(.notOwner))
            #expect(fixture.takeFaults() == [FaultRecord(scope: fixture.scope(0), kind: .sysexAborted, count: 1,
                                                         firstFrame: 8)])
            #expect(fixture.drain().isEmpty)
        }
    }
}
