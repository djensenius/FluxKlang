import Synchronization

/// Borrowed storage is valid only during `receive`. Each next() exposes one packet, including empty packets.
protocol MIDIBorrowedPacketCursor {
    var packetCount: Int { get }
    var isValid: Bool { get }
    mutating func next() -> UnsafeBufferPointer<UInt8>
}

extension MIDIBorrowedPacketCursor {
    var isValid: Bool { true }
}

/// Application-enforced exclusive producer role; not a claim that Apple serializes read callbacks.
/// Gate release/acquire transfers all producer state, including SPSCRing's non-atomic write cursor.
final class MIDICallbackIngress: @unchecked Sendable {
    static let maximumEntries = 1_024
    static let maximumBytes = 65_536
    private let gate = Atomic<UInt8>(0)
    private let gap = Atomic<Bool>(false)
    private let sourceDirty = Atomic<Bool>(false)
    let storage: MIDIIngressStorage

    init(
        batches: Int = 1_024, bytes: Int = 1_048_576, lengths: Int = 4_096, startingAt: UInt64 = 0,
        format: MIDIPacketBatch.Format = .bytes
    ) throws {
        storage = try MIDIIngressStorage(
            batches: batches, bytes: bytes, lengths: lengths, startingAt: startingAt, format: format
        )
    }

    /// Bits: busy = 1, permanently closed = 2. Exactly one strong CAS; no retry on overlap or reentry.
    @discardableResult
    func receive<Cursor: MIDIBorrowedPacketCursor>(
        _ cursor: inout Cursor, rawToken: UInt = 0,
        beforeExchange: (() -> Void)? = nil, afterExchange: (() -> Void)? = nil
    ) -> Bool {
        guard gate.compareExchange(expected: 0, desired: 1, ordering: .acquiring).exchanged else {
            return refuse()
        }
        defer { gate.bitwiseAnd(~UInt8(1), ordering: .releasing) }
        guard cursor.isValid, (0...Self.maximumEntries).contains(cursor.packetCount) else { return refuse() }
        var byteCount = 0
        var packetCount = 0
        for _ in 0..<cursor.packetCount {
            let packet = cursor.next()
            guard cursor.isValid, packet.count <= Int(UInt16.max),
                  packet.count <= Self.maximumBytes - byteCount else { return refuse() }
            if storage.format == .midi1UMP, !packet.count.isMultiple(of: 4) { return refuse() }
            if packet.isEmpty { continue }
            guard storage.hasRoom(bytes: byteCount + packet.count, lengths: packetCount + 1) else {
                return refuse()
            }
            storage.write(packet, byteOffset: byteCount, lengthOffset: packetCount)
            byteCount += packet.count
            packetCount += 1
        }
        guard packetCount > 0 else { return true }
        // Fixture hooks are nil in the native callback. Empty input must never consume the pending gap.
        beforeExchange?()
        let afterGap = gap.exchange(false, ordering: .acquiringAndReleasing)
        afterExchange?()
        guard storage.publish(bytes: byteCount, lengths: packetCount, rawToken: rawToken, afterGap: afterGap) else {
            return refuse()
        }
        return true
    }

    private func refuse() -> Bool {
        gap.store(true, ordering: .releasing)
        return false
    }

    func close() {
        gate.bitwiseOr(2, ordering: .acquiringAndReleasing)
    }

    func sourcesChanged() {
        sourceDirty.store(true, ordering: .releasing)
    }

    func takeSourcesChanged() -> Bool {
        sourceDirty.exchange(false, ordering: .acquiringAndReleasing)
    }
}
