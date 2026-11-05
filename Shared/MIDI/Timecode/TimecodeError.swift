/// Typed refusals for MTC/MMC decoding, encoding and SMPTE arithmetic. Malformed input never traps.
enum TimecodeError: Error, Equatable, Hashable, Sendable {
    enum Field: Equatable, Hashable, Sendable {
        case hours
        case minutes
        case seconds
        case frames
        case subframes
    }

    case fieldOutOfRange(Field, value: Int)
    /// Drop-frame skips labels ;00 and ;01 at second 0 of every minute not divisible by ten.
    case droppedFrameLabel(minutes: Int, frames: Int)
    case frameCountOutOfRange(Int, framesPerDay: Int)
    case invalidRateCode(UInt8)
    case deviceIDOutOfRange(UInt8)
    case dataByteOutOfRange(UInt8)
    /// Not a single-data-byte F1 System Common event.
    case notQuarterFrame
    /// A piece index above 7 or a value that is not a nibble (0...15).
    case invalidPiece(piece: UInt8, nibble: UInt8)
    /// A quarter-frame nibble carried bits the MTC piece defines as zero.
    case reservedBitsSet(piece: UInt8, nibble: UInt8)
    /// The SysEx header does not identify the expected Universal Real Time message.
    case notTimecodeMessage
    case notMMCCommand
    case lengthMismatch(expected: Int, actual: Int)
    case unsupportedMMCCommand(UInt8)
    /// Bytes follow a complete MMC command; multi-command messages are refused whole, never partially parsed.
    case multipleMMCCommands(firstCommandLength: Int, totalLength: Int)
    case unsupportedLocateForm(UInt8)
    case reservedFlagsSet(byte: UInt8)
}
