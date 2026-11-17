import Synchronization

/// No references or borrowed pointers cross the ring.
struct MIDIIngressDescriptor: BitwiseCopyable, Sendable {
    let byteStart: UInt64
    let lengthStart: UInt64
    let batchEnd: UInt64
    let byteCount: Int
    let packetCount: Int
    let rawToken: UInt
    let afterGap: Bool
}

/// One session's fixed storage. Producer access requires the ingress gate; consumer access is single-owner.
/// Payload is reclaimed by post-copy acknowledgements, NOT by popping a descriptor from SPSCRing.
final class MIDIIngressStorage: @unchecked Sendable {
    let format: MIDIPacketBatch.Format
    let descriptors: SPSCRing<MIDIIngressDescriptor>
    let byteCapacity: Int
    let lengthCapacity: Int
    private let bytes: UnsafeMutablePointer<UInt8>
    private let lengths: UnsafeMutablePointer<UInt16>
    private let copiedBytes: Atomic<UInt64>
    private let copiedLengths: Atomic<UInt64>
    private let copiedBatches: Atomic<UInt64>
    private(set) var byteEnd: UInt64
    private(set) var lengthEnd: UInt64
    private(set) var batchEnd: UInt64

    /// Smaller power-of-two capacities and a wrapping counter origin are pure-fixture seams.
    init(
        batches: Int = 1_024, bytes: Int = 1_048_576, lengths: Int = 4_096, startingAt: UInt64 = 0,
        format: MIDIPacketBatch.Format = .bytes
    ) throws {
        precondition(bytes > 0 && bytes.nonzeroBitCount == 1)
        precondition(lengths > 0 && lengths.nonzeroBitCount == 1)
        self.format = format
        descriptors = try SPSCRing(policy: HandoffPolicy(
            purpose: .events, producer: .midiReceive,
            producers: ProducerCardinality(maximum: 1, evidence: .verified),
            consumer: .control, consumers: 1, capacity: batches, ordering: .fifo,
            deadline: .none, overflow: .refuseProducer, lifetime: .session
        ), startingIndex: startingAt)
        byteCapacity = bytes
        lengthCapacity = lengths
        self.bytes = .allocate(capacity: bytes)
        self.lengths = .allocate(capacity: lengths)
        self.bytes.initialize(repeating: 0, count: bytes)
        self.lengths.initialize(repeating: 0, count: lengths)
        copiedBytes = Atomic(startingAt)
        copiedLengths = Atomic(startingAt)
        copiedBatches = Atomic(startingAt)
        byteEnd = startingAt
        lengthEnd = startingAt
        batchEnd = startingAt
    }

    deinit {
        bytes.deallocate()
        lengths.deallocate()
    }

    func hasRoom(bytes: Int, lengths: Int) -> Bool {
        byteEnd &- copiedBytes.load(ordering: .acquiring) + UInt64(bytes) <= UInt64(byteCapacity)
            && lengthEnd &- copiedLengths.load(ordering: .acquiring) + UInt64(lengths) <= UInt64(lengthCapacity)
            && batchEnd &- copiedBatches.load(ordering: .acquiring) < UInt64(descriptors.capacity)
    }

    /// Writes only free scratch space. A refused callback never commits these writes.
    func write(_ packet: UnsafeBufferPointer<UInt8>, byteOffset: Int, lengthOffset: Int) {
        let start = Int((byteEnd &+ UInt64(byteOffset)) & UInt64(byteCapacity - 1))
        let first = min(packet.count, byteCapacity - start)
        if let base = packet.baseAddress {
            bytes.advanced(by: start).update(from: base, count: first)
            bytes.update(from: base.advanced(by: first), count: packet.count - first)
        }
        let slot = Int((lengthEnd &+ UInt64(lengthOffset)) & UInt64(lengthCapacity - 1))
        lengths[slot] = UInt16(packet.count)
    }

    func publish(bytes: Int, lengths: Int, rawToken: UInt, afterGap: Bool) -> Bool {
        let descriptor = MIDIIngressDescriptor(
            byteStart: byteEnd, lengthStart: lengthEnd, batchEnd: batchEnd &+ 1,
            byteCount: bytes, packetCount: lengths, rawToken: rawToken, afterGap: afterGap
        )
        guard descriptors.tryPush(descriptor) == .ok else { return false }
        byteEnd &+= UInt64(bytes)
        lengthEnd &+= UInt64(lengths)
        batchEnd &+= 1
        return true
    }

    /// Consumer only; FIFO, including a descriptor carried to another turn. No handler runs during copying.
    func copyAndAcknowledge(
        _ descriptor: MIDIIngressDescriptor, beforeAcknowledgement: (() -> Void)? = nil
    ) -> MIDIPacketBatch {
        var packets: [[UInt8]] = []
        packets.reserveCapacity(descriptor.packetCount)
        var cursor = descriptor.byteStart
        for offset in 0..<descriptor.packetCount {
            let slot = Int((descriptor.lengthStart &+ UInt64(offset)) & UInt64(lengthCapacity - 1))
            let count = Int(lengths[slot])
            let start = Int(cursor & UInt64(byteCapacity - 1))
            let first = min(count, byteCapacity - start)
            var packet = Array(UnsafeBufferPointer(start: bytes.advanced(by: start), count: first))
            packet.append(contentsOf: UnsafeBufferPointer(start: bytes, count: count - first))
            packets.append(packet)
            cursor &+= UInt64(count)
        }
        let payload: MIDIPacketBatch.Payload
        switch format {
        case .bytes:
            payload = .bytes(packets)
        case .midi1UMP:
            payload = .midi1UMP(packets.map { packet in
                precondition(packet.count.isMultiple(of: 4))
                return packet.withUnsafeBytes { raw in
                    stride(from: 0, to: raw.count, by: 4).map {
                        raw.loadUnaligned(fromByteOffset: $0, as: UInt32.self)
                    }
                }
            })
        }
        beforeAcknowledgement?()
        copiedBytes.store(descriptor.byteStart &+ UInt64(descriptor.byteCount), ordering: .releasing)
        copiedLengths.store(descriptor.lengthStart &+ UInt64(descriptor.packetCount), ordering: .releasing)
        copiedBatches.store(descriptor.batchEnd, ordering: .releasing)
        return MIDIPacketBatch(
            payload: payload, afterGap: descriptor.afterGap,
            source: MIDIConnectionToken(rawValue: descriptor.rawToken)
        )
    }
}
