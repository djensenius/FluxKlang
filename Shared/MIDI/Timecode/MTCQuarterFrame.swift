/// One MTC quarter frame: System Common `F1 0nnndddd`, piece `nnn` carrying nibble `dddd`.
struct MTCQuarterFrame: Equatable, Hashable, Sendable {
    static let status: UInt8 = 0xF1
    static let pieceCount = 8

    /// Piece index 0...7.
    let piece: UInt8
    let nibble: UInt8

    init(piece: UInt8, nibble: UInt8) throws(TimecodeError) {
        guard piece < 8, nibble < 0x10 else { throw .invalidPiece(piece: piece, nibble: nibble) }
        guard nibble & ~Self.allowedBits[Int(piece)] == 0 else {
            throw .reservedBitsSet(piece: piece, nibble: nibble)
        }
        self.piece = piece
        self.nibble = nibble
    }

    init(dataByte: UInt8) throws(TimecodeError) {
        guard dataByte < 0x80 else { throw .dataByteOutOfRange(dataByte) }
        try self.init(piece: dataByte >> 4, nibble: dataByte & 0x0F)
    }

    /// Accepts the event exactly as `MIDI1Parser` delivers an F1 message.
    init(event: MIDI1Event) throws(TimecodeError) {
        guard case let .systemCommon(status, data1, data2) = event, status == Self.status,
              let data1, data2 == nil else { throw .notQuarterFrame }
        try self.init(dataByte: data1)
    }

    var dataByte: UInt8 { (piece << 4) | nibble }
    var event: MIDI1Event { .systemCommon(status: Self.status, data1: dataByte, data2: nil) }
    var bytes: [UInt8] { [Self.status, dataByte] }

    /// The eight pieces for `time` in transmission order 0...7 (reverse playback sends them 7...0).
    static func pieces(for time: SMPTETime) -> [MTCQuarterFrame] {
        let hoursHigh = UInt8(time.hours >> 4) | (time.rate.rawValue << 1)
        let nibbles: [UInt8] = [
            UInt8(time.frames & 0x0F), UInt8(time.frames >> 4),
            UInt8(time.seconds & 0x0F), UInt8(time.seconds >> 4),
            UInt8(time.minutes & 0x0F), UInt8(time.minutes >> 4),
            UInt8(time.hours & 0x0F), hoursHigh
        ]
        return nibbles.enumerated().map { MTCQuarterFrame(validated: UInt8($0.offset), nibble: $0.element) }
    }

    /// Joins eight nibbles indexed by piece into a validated time. Every element passes the same piece-level
    /// validation as `init(piece:nibble:)` first, so the field extraction below never masks away bad bits.
    static func time(fromNibbles nibbles: [UInt8]) throws(TimecodeError) -> SMPTETime {
        guard nibbles.count == pieceCount else { throw .lengthMismatch(expected: pieceCount, actual: nibbles.count) }
        for (piece, nibble) in nibbles.enumerated() {
            _ = try MTCQuarterFrame(piece: UInt8(piece), nibble: nibble)
        }
        func join(_ low: Int) -> Int { Int(nibbles[low]) | Int(nibbles[low + 1]) << 4 }
        let rate = try SMPTEFrameRate(code: (nibbles[7] >> 1) & 0x03)
        let hours = Int(nibbles[6]) | Int(nibbles[7] & 0x01) << 4
        return try SMPTETime(hours: hours, minutes: join(4), seconds: join(2), frames: join(0), rate: rate)
    }

    private init(validated piece: UInt8, nibble: UInt8) {
        self.piece = piece
        self.nibble = nibble
    }

    /// Frames < 32, seconds/minutes < 64, hours < 32 plus a two-bit rate; bit 3 of piece 7 is reserved.
    private static let allowedBits: [UInt8] = [0x0F, 0x01, 0x0F, 0x03, 0x0F, 0x03, 0x0F, 0x07]
}
