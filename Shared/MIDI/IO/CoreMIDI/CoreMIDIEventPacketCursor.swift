/// CoreMIDI's four-byte-packed event list: protocol/count (8 bytes), then timestamp/wordCount (12 bytes)
/// and variable words. The SDK's words[64] is a template, not a receive limit.
/// Valid borrowed native headers/payloads are a platform precondition: no total allocation extent is supplied.
struct CoreMIDIEventPacketCursor: MIDIBorrowedPacketCursor {
    static let maximumWords = 16_383
    let packetCount: Int
    private(set) var isValid: Bool
    private var packet: UnsafeRawPointer
    private var remainingBytes = MIDICallbackIngress.maximumBytes

    init(_ list: UnsafeRawPointer) {
        isValid = list.loadUnaligned(as: Int32.self) == 1 // kMIDIProtocol_1_0
        packetCount = Int(list.loadUnaligned(fromByteOffset: 4, as: UInt32.self))
        packet = list.advanced(by: 8)
    }

    mutating func next() -> UnsafeBufferPointer<UInt8> {
        guard isValid else { return UnsafeBufferPointer(start: nil, count: 0) }
        let words = Int(packet.loadUnaligned(fromByteOffset: 8, as: UInt32.self))
        guard words <= Self.maximumWords, words <= remainingBytes / 4 else {
            isValid = false
            return UnsafeBufferPointer(start: nil, count: 0)
        }
        let count = words * 4
        let payload = packet.advanced(by: 12)
        packet = payload.advanced(by: count)
        remainingBytes -= count
        return UnsafeBufferPointer(start: payload.assumingMemoryBound(to: UInt8.self), count: count)
    }
}
