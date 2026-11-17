import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension CoreMIDIAdapterTests {
    @Test func ingressDefaultsAndExclusivePolicy() throws {
        let ingress = try MIDICallbackIngress()
        #expect(ingress.storage.byteCapacity == 1_048_576)
        #expect(ingress.storage.lengthCapacity == 4_096)
        #expect(ingress.storage.descriptors.capacity == 1_024)
        #expect(ingress.storage.descriptors.policy.producer == .midiReceive)
        #expect(ingress.storage.descriptors.policy.producers == ProducerCardinality(maximum: 1, evidence: .verified))
    }

    @Test func independentCapacitiesIncludePoppedUncopiedBatch() throws {
        // Only the named capacity can be exhausted; the ring has already freed the popped descriptor.
        let configurations = [(1, 8, 8), (8, 1, 8), (8, 8, 1)]
        for (batches, bytes, lengths) in configurations {
            let ingress = try MIDICallbackIngress(batches: batches, bytes: bytes, lengths: lengths)
            #expect(Self.send([[42]], to: ingress))
            let held = try #require(ingress.storage.descriptors.tryPop())
            #expect(!Self.send([[99]], to: ingress), "popping is not copying: \(configurations)")
            #expect(ingress.storage.descriptors.tryPop() == nil)
            #expect(ingress.storage.copyAndAcknowledge(held).packets == [[42]])
            #expect(Self.send([[7]], to: ingress))
            let next = try Self.pop(ingress)
            #expect(next.packets == [[7]] && next.afterGap)
        }
    }

    @Test func refusalRollsBackEveryCursorWithoutPublishingAPrefix() throws {
        let ingress = try MIDICallbackIngress(batches: 4, bytes: 4, lengths: 4)
        #expect(Self.send([[9]], to: ingress))
        #expect(!Self.send([[1, 2], [3, 4]], to: ingress))
        #expect(ingress.storage.byteEnd == 1 && ingress.storage.lengthEnd == 1 && ingress.storage.batchEnd == 1)
        #expect(try Self.pop(ingress).packets == [[9]])
        #expect(ingress.storage.descriptors.tryPop() == nil)
        #expect(Self.send([[5, 6, 7, 8]], to: ingress))
        let recovered = try Self.pop(ingress)
        #expect(recovered.packets == [[5, 6, 7, 8]] && recovered.afterGap)
    }

    @Test func acknowledgementOnlyAfterConsumerCopyCompletes() throws {
        let ingress = try MIDICallbackIngress(batches: 1, bytes: 1, lengths: 1)
        #expect(Self.send([[42]], to: ingress))
        let held = try #require(ingress.storage.descriptors.tryPop())
        var paused = false
        let copied = ingress.storage.copyAndAcknowledge(held, beforeAcknowledgement: {
            paused = true
            #expect(!Self.send([[99]], to: ingress))
        })
        #expect(paused && copied.packets == [[42]])
        #expect(Self.send([[7]], to: ingress))
        #expect(try Self.pop(ingress).afterGap)
    }

    @Test func failedDescriptorPushRestoresGapWithoutCommit() throws {
        let ingress = try MIDICallbackIngress(batches: 1)
        // Force the otherwise unreachable push failure without touching ingress's committed cursors.
        let sentinel = MIDIIngressDescriptor(
            byteStart: 0, lengthStart: 0, batchEnd: 0, byteCount: 0, packetCount: 0, rawToken: 0, afterGap: false
        )
        #expect(ingress.storage.descriptors.tryPush(sentinel) == .ok)
        #expect(!Self.send([[1]], to: ingress))
        #expect(ingress.storage.byteEnd == 0 && ingress.storage.lengthEnd == 0 && ingress.storage.batchEnd == 0)
        #expect(ingress.storage.descriptors.tryPop()?.packetCount == 0)
        #expect(Self.send([[2]], to: ingress))
        let next = try Self.pop(ingress)
        #expect(next.afterGap && next.packets == [[2]])
    }

    @Test func wrappingCursorsPreservePacketBoundariesAndBorrowedBytes() throws {
        let ingress = try MIDICallbackIngress(batches: 4, bytes: 8, lengths: 4, startingAt: .max - 1)
        for index in 0..<20 {
            let packets: [[UInt8]] = [[], [UInt8(index), 2, 3], [4], []]
            let borrowed = BorrowedPackets(packets)
            #expect(borrowed.send(to: ingress, token: 17))
            borrowed.bytes.update(repeating: 0, count: borrowed.count)
            let batch = try Self.pop(ingress)
            #expect(batch.packets == [[UInt8(index), 2, 3], [4]])
            #expect(batch.source?.rawValue == 17 && !batch.afterGap)
        }
        #expect(ingress.storage.byteEnd == 78)
        #expect(ingress.storage.lengthEnd == 38)
        #expect(ingress.storage.batchEnd == 18)
    }

    @Test func fullUInt16PacketAndExactCallbackByteLimitAreNotTruncated() throws {
        let ingress = try MIDICallbackIngress()
        let large = (0..<65_535).map { UInt8(truncatingIfNeeded: $0) }
        #expect(Self.send([large, [255]], to: ingress))
        #expect(try Self.pop(ingress).packets == [large, [255]])
        #expect(!Self.send([large, [1, 2]], to: ingress))
        #expect(!Self.send([Array(repeating: 7, count: 65_536)], to: ingress))
        #expect(ingress.storage.descriptors.tryPop() == nil)
        #expect(Self.send([[8]], to: ingress))
        #expect(try Self.pop(ingress).afterGap)
    }

    @Test func inspectionLimitCountsEmptyEntriesAndEmptyCannotConsumeGap() throws {
        let ingress = try MIDICallbackIngress()
        #expect(!Self.send(Array(repeating: [], count: 1_025), to: ingress))
        #expect(Self.send(Array(repeating: [], count: 1_024), to: ingress))
        #expect(Self.send([], to: ingress))
        #expect(ingress.storage.descriptors.tryPop() == nil)
        #expect(Self.send([[3]], to: ingress))
        #expect(try Self.pop(ingress).afterGap)
        let exact = Array(repeating: [UInt8(4)], count: 1_024)
        #expect(Self.send(exact, to: ingress))
        #expect(try Self.pop(ingress).packets == exact)
        #expect(!Self.send(exact + [[]], to: ingress))
        #expect(ingress.storage.descriptors.tryPop() == nil)
    }
}
