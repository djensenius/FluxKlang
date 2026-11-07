/// Whole-block feedback delay over a planar ring. Contract: a block stored at index `k` is read back at index
/// `k + delayBlocks`, so the delay is exactly `delayBlocks >= 1` blocks and never 0; unwritten history is `+0.0`.
/// Reading and storing the same index use the same ring slot (`index % delayBlocks`), so the read must happen before
/// the store. The ring uses the layout of the plan's delay storage and of `ReferenceEvaluatorState.lines`: channel
/// `c` occupies `c * delayFrames ..< (c + 1) * delayFrames` and each block slot is `blockFrames` floats wide.
/// Storage is private; values are built only through the validating initializers.
struct ReferenceDelayLine: Equatable, Sendable {
    private let channels: Int
    private let blockFrames: Int
    private let delayBlocks: Int
    private let ring: [Float]

    /// The ring in state-line layout.
    var storage: [Float] { ring }

    init(channels: Int, blockFrames: Int, delayBlocks: Int) throws(ReferenceEvaluatorRefusal) {
        let floats = try Self.floatCount(channels: channels, blockFrames: blockFrames, delayBlocks: delayBlocks)
        self.channels = channels
        self.blockFrames = blockFrames
        self.delayBlocks = delayBlocks
        ring = [Float](repeating: 0, count: floats)
    }

    /// Rebuilds a line from a state line; a wrong length is `.stateMismatch`.
    init(
        restoring storage: [Float], channels: Int, blockFrames: Int, delayBlocks: Int
    ) throws(ReferenceEvaluatorRefusal) {
        let floats = try Self.floatCount(channels: channels, blockFrames: blockFrames, delayBlocks: delayBlocks)
        guard storage.count == floats else { throw .stateMismatch }
        self.channels = channels
        self.blockFrames = blockFrames
        self.delayBlocks = delayBlocks
        ring = storage
    }

    private init(like line: ReferenceDelayLine, ring: [Float]) {
        channels = line.channels
        blockFrames = line.blockFrames
        delayBlocks = line.delayBlocks
        self.ring = ring
    }

    private static func floatCount(
        channels: Int, blockFrames: Int, delayBlocks: Int
    ) throws(ReferenceEvaluatorRefusal) -> Int {
        guard channels >= 1, blockFrames >= 1, delayBlocks >= 1 else { throw .scheduleDefect(.delayGeometry) }
        let blockFloats = try ReferenceChecked.multiply(channels, blockFrames, .stateFloats)
        return try ReferenceChecked.multiply(blockFloats, delayBlocks, .stateFloats)
    }

    /// The planar `channels * blockFrames` samples stored `delayBlocks` blocks earlier; zeros until then and for a
    /// negative index.
    func block(at blockIndex: Int) -> [Float] {
        let count = channels * blockFrames
        guard blockIndex >= 0 else { return [Float](repeating: 0, count: count) }
        var result = [Float]()
        result.reserveCapacity(count)
        let delayFrames = delayBlocks * blockFrames
        let slotStart = (blockIndex % delayBlocks) * blockFrames
        for channel in 0..<channels {
            let start = channel * delayFrames + slotStart
            result.append(contentsOf: ring[start..<(start + blockFrames)])
        }
        return result
    }

    /// A copy with `block` stored in the slot of `blockIndex`. A block of the wrong length or a negative index
    /// returns `self` unchanged; the caller checks the precondition.
    func storing(_ block: [Float], at blockIndex: Int) -> ReferenceDelayLine {
        guard blockIndex >= 0, block.count == channels * blockFrames else { return self }
        var updated = ring
        let delayFrames = delayBlocks * blockFrames
        let slotStart = (blockIndex % delayBlocks) * blockFrames
        for channel in 0..<channels {
            let start = channel * delayFrames + slotStart
            for frame in 0..<blockFrames {
                updated[start + frame] = block[channel * blockFrames + frame]
            }
        }
        return ReferenceDelayLine(like: self, ring: updated)
    }
}
