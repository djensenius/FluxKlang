// #83 UKB1: bridges the UMP SysEx7 codec (`UMPSysEx7Packet`, MT 0x3) to `SysExAssembler`. The bridge lives on the
// kernel side because the kernel may depend on the protocol layer, never the reverse. A UMP group is not a kernel
// source: sources are endpoint or slot indices the caller owns, so every entry point here takes `source` explicitly
// and never derives it from the packet's group. Reference model; not RT-certified.

extension SysExChunkStatus {
    /// The kernel status for a UMP SysEx7 status nibble.
    init(_ status: UMPSysEx7Status) {
        switch status {
        case .complete: self = .complete
        case .start: self = .start
        case .continue: self = .continue
        case .end: self = .end
        }
    }
}

extension UMPSysEx7Status {
    /// The UMP SysEx7 status nibble for a kernel chunk status. Kept here, not in the codec, so the protocol layer
    /// does not depend on the kernel.
    init(_ status: SysExChunkStatus) {
        switch status {
        case .complete: self = .complete
        case .start: self = .start
        case .continue: self = .continue
        case .end: self = .end
        }
    }
}

/// One `UMPSysEx7Packet` in the form `SysExAssembler.accept` takes: its status, its data bytes in the first `count`
/// lanes of a zero-filled six-byte tuple, and `count` (0...6). The packet's group is dropped on purpose (see the
/// file header). Reference model; not RT-certified.
///
/// Building one reads the packet's existing byte array; it does not allocate. Decoding a `UMPSysEx7Packet` from
/// words does allocate (its `bytes` is an array), so the codec half of this path is not allocation-free.
struct SysExChunk: Sendable, BitwiseCopyable {
    let status: SysExChunkStatus
    /// Lanes at and past `count` are zero.
    let bytes: SysExChunkBytes
    let count: UInt8

    init(_ packet: UMPSysEx7Packet) {
        let source = packet.bytes
        // `UMPSysEx7Packet` holds at most six bytes, so `count` fits and every used lane is copied.
        let used = min(source.count, SysExAssembler.maximumChunkBytes)
        func lane(_ index: Int) -> UInt8 { index < used ? source[index] : 0 }
        status = SysExChunkStatus(packet.status)
        bytes = (lane(0), lane(1), lane(2), lane(3), lane(4), lane(5))
        count = UInt8(used)
    }
}

extension SysExAssembler {
    /// Producer only. Accepts one UMP SysEx7 packet from `source`, forwarding to
    /// `accept(source:status:bytes:count:frame:)` with the same state table and refusals. `source` is the
    /// caller's endpoint or slot index; the packet's group is not consulted.
    func accept(source: UInt32, packet: UMPSysEx7Packet, frame: Int64 = 0) -> KernelStatus {
        let chunk = SysExChunk(packet)
        return accept(source: source, status: chunk.status, bytes: chunk.bytes, count: chunk.count, frame: frame)
    }
}
