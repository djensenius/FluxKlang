enum MTCDirection: Equatable, Hashable, Sendable {
    /// Pieces arrive 0, 1, …, 7.
    case forward
    /// Pieces arrive 7, 6, …, 0.
    case reverse

    var opposite: MTCDirection { self == .forward ? .reverse : .forward }
    var startPiece: UInt8 { self == .forward ? 0 : 7 }
    var finalPiece: UInt8 { self == .forward ? 7 : 0 }

    /// A completed sequence describes the frame at which its first piece was sent; two frames have passed since.
    var completionOffset: Int { self == .forward ? MTCAssembler.completionFrames : -MTCAssembler.completionFrames }

    func next(after piece: UInt8) -> UInt8 {
        self == .forward ? (piece + 1) & 0x07 : (piece + 7) & 0x07
    }
}

/// A timecode decoded from eight consecutive quarter frames. Only the assembler builds one, so `current`
/// is always `encoded` corrected by the offset for `direction`.
struct MTCPosition: Equatable, Hashable, Sendable {
    /// The time carried by the pieces.
    let encoded: SMPTETime
    /// `encoded` corrected by the two-frame transmission offset in the direction of travel.
    let current: SMPTETime
    let direction: MTCDirection

    fileprivate init(encoded: SMPTETime, direction: MTCDirection) {
        self.encoded = encoded
        current = encoded.adding(frames: direction.completionOffset)
        self.direction = direction
    }
}

enum MTCAssemblerDiagnostic: Equatable, Hashable, Sendable {
    /// A missing, duplicate or out-of-order piece; the partial sequence is discarded.
    case gap(expected: UInt8, received: UInt8)
    /// The piece order reversed mid-sequence; mixed-direction assembly is refused.
    case directionChange(from: MTCDirection)
    /// A piece arrived before any sequence start (0 forward, 7 reverse) was seen.
    case unsynchronized(piece: UInt8)
    /// Eight in-order pieces did not form a valid time.
    case invalidTime(TimecodeError)
}

enum MTCAssemblerOutput: Equatable, Hashable, Sendable {
    case pending
    case position(MTCPosition)
    case reset(MTCAssemblerDiagnostic)
}

struct MTCAssemblerCounters: Equatable, Hashable, Sendable {
    var gaps = 0
    var directionChanges = 0
    var unsynchronized = 0
    var invalidTimes = 0
}

/// Pure eight-piece quarter-frame assembler. No clock, chase or transport behaviour.
struct MTCAssembler: Sendable {
    static let completionFrames = 2

    private enum State: Sendable {
        case idle
        case collecting(direction: MTCDirection, expected: UInt8, nibbles: [UInt8], count: Int)
    }

    private var state = State.idle
    private(set) var counters = MTCAssemblerCounters()

    mutating func reset() {
        state = .idle
    }

    mutating func consume(_ frame: MTCQuarterFrame) -> MTCAssemblerOutput {
        guard case let .collecting(direction, expected, nibbles, count) = state else {
            return start(frame) ?? report(.unsynchronized(piece: frame.piece))
        }
        if frame.piece == expected {
            return accept(frame, direction: direction, nibbles: nibbles, count: count)
        }
        // A lone start piece followed by the other direction's start reveals the true direction.
        if count == 1, frame.piece == direction.finalPiece, let restarted = start(frame) {
            return restarted
        }
        let last = direction.opposite.next(after: expected)
        let diagnostic: MTCAssemblerDiagnostic = frame.piece == direction.opposite.next(after: last)
            ? .directionChange(from: direction)
            : .gap(expected: expected, received: frame.piece)
        state = .idle
        _ = start(frame)
        return report(diagnostic)
    }

    private mutating func start(_ frame: MTCQuarterFrame) -> MTCAssemblerOutput? {
        let direction: MTCDirection
        switch frame.piece {
        case MTCDirection.forward.startPiece: direction = .forward
        case MTCDirection.reverse.startPiece: direction = .reverse
        default: return nil
        }
        var nibbles = [UInt8](repeating: 0, count: MTCQuarterFrame.pieceCount)
        nibbles[Int(frame.piece)] = frame.nibble
        state = .collecting(direction: direction, expected: direction.next(after: frame.piece), nibbles: nibbles,
                            count: 1)
        return .pending
    }

    private mutating func accept(
        _ frame: MTCQuarterFrame, direction: MTCDirection, nibbles: [UInt8], count: Int
    ) -> MTCAssemblerOutput {
        var nibbles = nibbles
        nibbles[Int(frame.piece)] = frame.nibble
        guard count + 1 == MTCQuarterFrame.pieceCount else {
            state = .collecting(direction: direction, expected: direction.next(after: frame.piece),
                                nibbles: nibbles, count: count + 1)
            return .pending
        }
        state = .idle
        do {
            let encoded = try MTCQuarterFrame.time(fromNibbles: nibbles)
            return .position(MTCPosition(encoded: encoded, direction: direction))
        } catch {
            return report(.invalidTime(error))
        }
    }

    private mutating func report(_ diagnostic: MTCAssemblerDiagnostic) -> MTCAssemblerOutput {
        switch diagnostic {
        case .gap: counters.gaps += 1
        case .directionChange: counters.directionChanges += 1
        case .unsynchronized: counters.unsynchronized += 1
        case .invalidTime: counters.invalidTimes += 1
        }
        return .reset(diagnostic)
    }
}
