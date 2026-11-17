import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension CoreMIDIAdapterTests {
    /// Owned synthetic four-byte-packed event-list memory, deliberately unaligned. No CoreMIDI API executes.
    final class EventList {
        private let allocation: UnsafeMutableRawPointer
        let raw: UnsafeMutableRawPointer

        init(_ packets: [[UInt32]], protocolID: Int32 = 1) {
            let size = 8 + packets.reduce(0) { $0 + 12 + $1.count * 4 }
            allocation = .allocate(byteCount: size + 1, alignment: 8)
            allocation.initializeMemory(as: UInt8.self, repeating: 0, count: size + 1)
            raw = allocation.advanced(by: 1)
            raw.storeBytes(of: protocolID, as: Int32.self)
            raw.storeBytes(of: UInt32(packets.count), toByteOffset: 4, as: UInt32.self)
            var offset = 8
            for packet in packets {
                raw.storeBytes(of: UInt64(123), toByteOffset: offset, as: UInt64.self)
                raw.storeBytes(of: UInt32(packet.count), toByteOffset: offset + 8, as: UInt32.self)
                for (index, word) in packet.enumerated() {
                    raw.storeBytes(of: word, toByteOffset: offset + 12 + index * 4, as: UInt32.self)
                }
                offset += 12 + packet.count * 4
            }
        }

        deinit { allocation.deallocate() }

        @discardableResult
        func send(to ingress: MIDICallbackIngress, token: UInt = 0) -> Bool {
            var cursor = CoreMIDIEventPacketCursor(UnsafeRawPointer(raw))
            return ingress.receive(&cursor, rawToken: token)
        }
    }

    static func umpIngress() throws -> MIDICallbackIngress {
        try MIDICallbackIngress(format: .midi1UMP)
    }

    @Test func typedBatchPreservesByteAPIAndOwnsWordsAfterCallback() throws {
        var bytes = MIDIPacketBatch(packets: [[0xBF, 5, 127]], afterGap: true, source: try Self.token(1))
        #expect(bytes.payload == .bytes([[0xBF, 5, 127]]))
        bytes.packets = [[0xBF, 6, 64]]
        #expect(bytes.packets == [[0xBF, 6, 64]])
        #expect(bytes.payload.format == .bytes)
        let ingress = try Self.umpIngress()
        let words: [UInt32] = [0x2FBF_057F, 0x3001_0100, 0]
        do {
            let list = EventList([words])
            #expect(list.send(to: ingress, token: 9))
            list.raw.storeBytes(of: UInt32(0), toByteOffset: 20, as: UInt32.self)
        }
        let descriptor = try #require(ingress.storage.descriptors.tryPop())
        let batch = ingress.storage.copyAndAcknowledge(descriptor) {
            #expect(ingress.storage.byteEnd == UInt64(words.count * 4))
        }
        #expect(batch == MIDIPacketBatch(payload: .midi1UMP([words]), source: try Self.token(9)))
        #expect(batch.payload.format == .midi1UMP)
    }

    @Test func dynamicEventLayoutTraversesLargeMixedAndEmptyPackets() throws {
        let ingress = try Self.umpIngress()
        let large = (0..<65).map { UInt32(0x20BF_0500) | UInt32($0) }
        let packets: [[UInt32]] = [[], large, [], [0x13F8_0000], [0x3001_7E00, 0], []]
        #expect(EventList(packets).send(to: ingress))
        #expect(try Self.pop(ingress).payload == .midi1UMP(packets.filter { !$0.isEmpty }))
        #expect(ingress.storage.descriptors.tryPop() == nil)
    }

    @Test func exactEventWordAndCallbackByteBoundsRefuseWhole() throws {
        let full = Array(repeating: UInt32(0x20BF_057F), count: 16_383)
        for packets in [[full], [full, [0x10F8_0000]]] {
            let ingress = try Self.umpIngress()
            #expect(EventList(packets).send(to: ingress))
            #expect(try Self.pop(ingress).payload == .midi1UMP(packets))
        }
        for packets in [[full + [0]], [full, [0x10F8_0000, 0x10F8_0000]]] {
            let ingress = try Self.umpIngress()
            #expect(!EventList(packets).send(to: ingress))
            #expect(ingress.storage.byteEnd == 0)
            #expect(ingress.storage.lengthEnd == 0)
            #expect(ingress.storage.descriptors.tryPop() == nil)
            #expect(EventList([[], []]).send(to: ingress))
            #expect(ingress.storage.descriptors.tryPop() == nil)
            #expect(EventList([[0x20BF_067F]]).send(to: ingress))
            #expect(try Self.pop(ingress) == MIDIPacketBatch(payload: .midi1UMP([[0x20BF_067F]]), afterGap: true))
        }
    }

    @Test func emptyEntriesCountAndProtocolMismatchCannotPublishScratch() throws {
        let ingress = try Self.umpIngress()
        let empty = Array(repeating: [UInt32](), count: 1_024)
        #expect(EventList(empty).send(to: ingress))
        #expect(!EventList(empty + [[]]).send(to: ingress))
        #expect(EventList(empty).send(to: ingress))
        #expect(EventList([[0x20BF_057F]]).send(to: ingress))
        #expect(try Self.pop(ingress).afterGap)
        #expect(!EventList([[0x20BF_067F]], protocolID: 2).send(to: ingress))
        #expect(ingress.storage.descriptors.tryPop() == nil)
        #expect(!EventList([[]], protocolID: 0).send(to: ingress))
        #expect(EventList([[0x20BF_077F]]).send(to: ingress))
        #expect(try Self.pop(ingress).afterGap)

        let before = ingress.storage.byteEnd
        let oversized = Array(repeating: UInt32(0), count: 16_384)
        #expect(!EventList([[0x20BF_057F], oversized]).send(to: ingress))
        #expect(ingress.storage.byteEnd == before)
        #expect(ingress.storage.descriptors.tryPop() == nil, "valid scratch prefix must remain unpublished")
        #expect(EventList([[0x20BF_087F]]).send(to: ingress))
        #expect(try Self.pop(ingress) == MIDIPacketBatch(payload: .midi1UMP([[0x20BF_087F]]), afterGap: true))
    }

    @Test func umpWordsRemainOwnedAcrossWrappingStorageAndReclamation() throws {
        let ingress = try MIDICallbackIngress(
            batches: 2, bytes: 16, lengths: 4, startingAt: UInt64.max - 1, format: .midi1UMP
        )
        #expect(EventList([[0x21BF_057F, 0x2FBF_0601], [0x10F8_0000]]).send(to: ingress))
        let descriptor = try #require(ingress.storage.descriptors.tryPop())
        #expect(!EventList([[0, 0]]).send(to: ingress), "popping did not reclaim the twelve payload bytes")
        let batch = ingress.storage.copyAndAcknowledge(descriptor)
        #expect(batch.payload == .midi1UMP([[0x21BF_057F, 0x2FBF_0601], [0x10F8_0000]]))
        #expect(EventList([[1, 2, 3, 4]]).send(to: ingress))
        #expect(try Self.pop(ingress).payload == .midi1UMP([[1, 2, 3, 4]]))
        #expect(batch.payload == .midi1UMP([[0x21BF_057F, 0x2FBF_0601], [0x10F8_0000]]))
    }

    @MainActor
    @Test func typedSessionsReuseOneDriverAndCannotLeakOldTokenOne() async throws {
        let driver = MIDICallbackDelivery()
        #expect(await Self.eventually { driver.isIdleWaiting })
        var batches: [MIDIPacketBatch] = []
        var old: MIDICallbackIngress?
        for format: MIDIPacketBatch.Format in [.bytes, .midi1UMP, .bytes, .midi1UMP] {
            let ingress = try MIDICallbackIngress(format: format)
            driver.start(ingress, reconcile: {}, handler: { batches.append($0) })
            if let old {
                #expect(!EventList([[0x20BF_7F7F]]).send(to: old, token: 1))
                old.sourcesChanged()
            }
            let expected: MIDIPacketBatch.Payload
            if format == .bytes {
                #expect(Self.send([[0xBF, 5, 127]], to: ingress, token: 1))
                expected = .bytes([[0xBF, 5, 127]])
            } else {
                #expect(EventList([[0x20BF_057F]]).send(to: ingress, token: 1))
                expected = .midi1UMP([[0x20BF_057F]])
            }
            let count = batches.count
            #expect(await Self.eventually { batches.count == count + 1 })
            #expect(batches.last == MIDIPacketBatch(payload: expected, source: try Self.token(1)))
            driver.stop()
            #expect(await Self.eventually { driver.isIdleWaiting })
            old = ingress
        }
        #expect(batches.count == 4)
        driver.stop()
    }
}
