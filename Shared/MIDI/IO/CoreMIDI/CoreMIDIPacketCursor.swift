import CoreMIDI

/// Walks the platform-owned variable-length list in place. Never loads/copies the fixed 256-byte data tuple.
/// MIDIPacketNext supplies the architecture-dependent alignment; length can be the full UInt16 range.
struct CoreMIDIPacketCursor: MIDIBorrowedPacketCursor {
    let packetCount: Int
    private var packet: UnsafePointer<MIDIPacket>

    init(_ list: UnsafePointer<MIDIPacketList>) {
        let raw = UnsafeRawPointer(list)
        packetCount = Int(raw.loadUnaligned(
            fromByteOffset: MemoryLayout<MIDIPacketList>.offset(of: \.numPackets)!, as: UInt32.self
        ))
        packet = raw.advanced(by: MemoryLayout<MIDIPacketList>.offset(of: \.packet)!)
            .assumingMemoryBound(to: MIDIPacket.self)
    }

    mutating func next() -> UnsafeBufferPointer<UInt8> {
        let raw = UnsafeRawPointer(packet)
        let count = Int(raw.loadUnaligned(
            fromByteOffset: MemoryLayout<MIDIPacket>.offset(of: \.length)!, as: UInt16.self
        ))
        let data = raw.advanced(by: MemoryLayout<MIDIPacket>.offset(of: \.data)!)
            .assumingMemoryBound(to: UInt8.self)
        packet = UnsafePointer(MIDIPacketNext(packet))
        return UnsafeBufferPointer(start: data, count: count)
    }
}
