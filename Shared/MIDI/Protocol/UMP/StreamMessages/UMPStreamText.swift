/// What `UMPStreamTextAssembler.feed` produced.
enum UMPStreamTextEvent: Equatable, Sendable {
    /// The packet was accepted; more packets of the same text are needed.
    case partial
    /// The text is finished.
    case complete(UMPStreamMessage)
}

/// Splits texts into packets and unpacks text packets. A text packet holds 14 bytes in a 14-byte lane: word 0 bits
/// 15...8 and 7...0, then words 1...3 most significant byte first. Function Block Name uses lane byte 0 for the
/// function block index, leaving 13 text bytes.
enum UMPStreamText {
    static let laneBytes = 14

    /// A Product Instance Id holds printable ASCII only (0x20...0x7E); the offset is that of the first other byte.
    static func requirePrintableASCII(_ bytes: some Sequence<UInt8>) throws(UMPStreamRefusal) {
        for (offset, byte) in bytes.enumerated() where !(0x20...0x7E).contains(byte) {
            throw .productInstanceIDNotPrintableASCII(offset: offset)
        }
    }

    /// Canonical packets of one text: validated block index, then length, then trailing zero, then (Product
    /// Instance Id only) printable ASCII.
    static func packets(
        kind: UMPStreamTextKind,
        index: Int,
        text: UMPStreamString,
        limits: UMPStreamLimits
    ) throws(UMPStreamRefusal) -> [UMPPacket] {
        if kind == .functionBlockName { try UMPStreamFunctionBlockInfo.validateIndex(index) }
        let byteCount = text.value.utf8.count
        guard byteCount <= limits.maximumBytes(for: kind) else { throw .textTooLong(byteCount) }
        let bytes = Array(text.value.utf8)
        guard bytes.last != 0 else { throw .trailingZeroByte }
        if kind == .productInstanceID { try requirePrintableASCII(bytes) }
        let size = kind.bytesPerPacket
        let count = max(1, (bytes.count + size - 1) / size)
        var result: [UMPPacket] = []
        for position in 0..<count {
            let format: UMPStreamFormat
            switch position {
            case _ where count == 1: format = .complete
            case 0: format = .start
            case count - 1: format = .end
            default: format = .continuation
            }
            let chunk = bytes[(position * size)..<min(bytes.count, (position + 1) * size)]
            do {
                result.append(try UMPPacket(words: words(format: format, kind: kind, index: index, chunk: chunk)))
            } catch {
                throw .packet(error)
            }
        }
        return result
    }

    static func words(
        format: UMPStreamFormat,
        kind: UMPStreamTextKind,
        index: Int,
        chunk: ArraySlice<UInt8>
    ) -> [UInt32] {
        var lane = [UInt8](repeating: 0, count: laneBytes)
        let offset = kind == .functionBlockName ? 1 : 0
        if offset == 1 { lane[0] = UInt8(truncatingIfNeeded: index) }
        for (position, byte) in chunk.enumerated() { lane[offset + position] = byte }
        let first = 0xF000_0000 | UInt32(format.rawValue) << 26 | UInt32(kind.status) << 16
            | UInt32(lane[0]) << 8 | UInt32(lane[1])
        var result = [first]
        for word in 0..<3 {
            let base = 2 + word * 4
            result.append(
                UInt32(lane[base]) << 24 | UInt32(lane[base + 1]) << 16 | UInt32(lane[base + 2]) << 8
                    | UInt32(lane[base + 3])
            )
        }
        return result
    }

    /// The 14 lane bytes of a text packet.
    static func lane(of words: [UInt32]) -> [UInt8] {
        var lane = [UInt8(truncatingIfNeeded: words[0] >> 8), UInt8(truncatingIfNeeded: words[0])]
        for word in words[1...3] {
            for shift in [24, 16, 8, 0] as [UInt32] {
                lane.append(UInt8(truncatingIfNeeded: word >> shift))
            }
        }
        return lane
    }
}

/// Joins the packets of one text. Accepts one complete packet, or start, continues, end. A refused packet leaves the
/// assembler equal to what it was (the caller decides whether to `reset()`); bounds are checked before a packet is
/// appended. Trailing zero padding is stripped only when the text is finished; a zero before the end is kept.
struct UMPStreamTextAssembler: Equatable, Sendable {
    private struct Pending: Equatable, Sendable {
        let kind: UMPStreamTextKind
        let index: Int
        var bytes: [UInt8]
        var packets: Int
    }

    let limits: UMPStreamLimits
    private var pending: Pending?

    init(limits: UMPStreamLimits) {
        self.limits = limits
    }

    var isAssembling: Bool { pending != nil }
    /// Bytes held so far, zero padding included.
    var pendingByteCount: Int { pending?.bytes.count ?? 0 }
    var pendingPacketCount: Int { pending?.packets ?? 0 }

    mutating func reset() {
        pending = nil
    }

    mutating func feed(_ packet: UMPPacket) throws(UMPStreamRefusal) -> UMPStreamTextEvent {
        let header = try UMPStreamHeader(packet)
        guard UMPStreamStatus(rawValue: header.status) != nil else { throw .unknownStatus(header.status) }
        guard let kind = UMPStreamTextKind(status: header.status) else { throw .notTextStatus(header.status) }
        let lane = UMPStreamText.lane(of: header.words)
        let index = kind == .functionBlockName ? Int(lane[0]) : 0
        if kind == .functionBlockName { try UMPStreamFunctionBlockInfo.validateIndex(index) }
        var next = try startingPoint(format: header.format, kind: kind, index: index)
        next.packets += 1
        guard next.packets <= kind.maximumPackets else { throw .tooManyPackets(limit: kind.maximumPackets) }
        next.bytes += lane[(kind == .functionBlockName ? 1 : 0)...]
        let length = Self.length(withoutTrailingZeros: next.bytes)
        guard length <= limits.maximumBytes(for: kind) else { throw .textTooLong(length) }
        switch header.format {
        case .start, .continuation:
            pending = next
            return .partial
        case .complete, .end:
            let message = try Self.message(kind: kind, index: index, bytes: next.bytes[..<length])
            pending = nil
            return .complete(message)
        }
    }

    /// The text this packet extends (or a fresh one), after the sequence checks.
    private func startingPoint(
        format: UMPStreamFormat,
        kind: UMPStreamTextKind,
        index: Int
    ) throws(UMPStreamRefusal) -> Pending {
        switch format {
        case .start, .complete:
            if let pending { throw .unexpectedStart(pendingStatus: pending.kind.status) }
            return Pending(kind: kind, index: index, bytes: [], packets: 0)
        case .continuation, .end:
            guard let pending else { throw .orphanContinue(status: kind.status) }
            guard pending.kind == kind else {
                throw .mismatchedStatus(expected: pending.kind.status, actual: kind.status)
            }
            guard pending.index == index else {
                throw .mismatchedFunctionBlock(expected: pending.index, actual: index)
            }
            return pending
        }
    }

    private static func length(withoutTrailingZeros bytes: [UInt8]) -> Int {
        var length = bytes.count
        while length > 0, bytes[length - 1] == 0 { length -= 1 }
        return length
    }

    private static func message(
        kind: UMPStreamTextKind,
        index: Int,
        bytes: ArraySlice<UInt8>
    ) throws(UMPStreamRefusal) -> UMPStreamMessage {
        if kind == .productInstanceID { try UMPStreamText.requirePrintableASCII(bytes) }
        guard let text = String(validating: bytes, as: UTF8.self) else { throw .invalidUTF8 }
        switch kind {
        case .endpointName: return .endpointName(UMPStreamString(text))
        case .productInstanceID: return .productInstanceID(UMPStreamString(text))
        case .functionBlockName: return .functionBlockName(index: index, name: UMPStreamString(text))
        }
    }
}
