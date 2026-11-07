/// Validated follower knobs. The only way to build one is `make`, so every instance is in range.
struct MTCFollowerPolicy: Equatable, Sendable {
    enum Field: Equatable, Hashable, Sendable {
        case lockPositions
        case toleranceFrames
        case dropoutFrames
        case freewheelNanoseconds
    }

    /// Consecutive continuous positions needed to lock.
    private(set) var lockPositions: Int
    /// Largest whole-frame deviation from the extrapolated position still counted as continuous.
    private(set) var toleranceFrames: Int
    /// Frames of quarter-frame silence tolerated before the follower freewheels.
    private(set) var dropoutFrames: Int
    /// Freewheel duration after the dropout instant before the follower is lost.
    private(set) var freewheelNanoseconds: Int64

    static let standard = MTCFollowerPolicy(lockPositions: 2, toleranceFrames: 1, dropoutFrames: 2,
                                            freewheelNanoseconds: 1_000_000_000)

    private init(lockPositions: Int, toleranceFrames: Int, dropoutFrames: Int, freewheelNanoseconds: Int64) {
        self.lockPositions = lockPositions
        self.toleranceFrames = toleranceFrames
        self.dropoutFrames = dropoutFrames
        self.freewheelNanoseconds = freewheelNanoseconds
    }

    static func make(
        lockPositions: Int = 2, toleranceFrames: Int = 1, dropoutFrames: Int = 2,
        freewheelNanoseconds: Int64 = 1_000_000_000
    ) throws(MTCFollowerError) -> MTCFollowerPolicy {
        try check(.lockPositions, Int64(lockPositions), 1...8)
        try check(.toleranceFrames, Int64(toleranceFrames), 0...4)
        try check(.dropoutFrames, Int64(dropoutFrames), 1...30)
        try check(.freewheelNanoseconds, freewheelNanoseconds, 1_000_000...60_000_000_000)
        return MTCFollowerPolicy(lockPositions: lockPositions, toleranceFrames: toleranceFrames,
                                 dropoutFrames: dropoutFrames, freewheelNanoseconds: freewheelNanoseconds)
    }

    private static func check(
        _ field: Field, _ value: Int64, _ range: ClosedRange<Int64>
    ) throws(MTCFollowerError) {
        guard range.contains(value) else { throw .policyOutOfRange(field: field, value: value) }
    }
}
