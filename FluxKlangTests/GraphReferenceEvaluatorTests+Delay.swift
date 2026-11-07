import Testing
import Foundation
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension GraphReferenceEvaluatorTests {
    private static func delayBlock(_ index: Int, channels: Int, frames: Int) -> [Float] {
        (0..<(channels * frames)).map { Float(index * 10 + $0 + 1) }
    }

    /// Reads then stores each block in turn (the evaluator's order) and returns every read.
    private static func delayReads(
        channels: Int, frames: Int, delay: Int, blocks: Int
    ) throws -> [[Float]] {
        var line = try ReferenceDelayLine(channels: channels, blockFrames: frames, delayBlocks: delay)
        var reads: [[Float]] = []
        for index in 0..<blocks {
            reads.append(line.block(at: index))
            line = line.storing(delayBlock(index, channels: channels, frames: frames), at: index)
        }
        return reads
    }

    @Test("GC3 delay of one block returns the previous block and zeros first")
    func referenceEvaluatorDelayOfOneBlockIsExact() throws {
        let reads = try Self.delayReads(channels: 2, frames: 2, delay: 1, blocks: 4)
        #expect(reads == [[0, 0, 0, 0], [1, 2, 3, 4], [11, 12, 13, 14], [21, 22, 23, 24]])
    }

    @Test("GC3 delay of three blocks wraps over seven blocks and never returns the current block")
    func referenceEvaluatorDelayOfThreeBlocksWrapsExactly() throws {
        let reads = try Self.delayReads(channels: 2, frames: 2, delay: 3, blocks: 7)
        #expect(reads == [
            [0, 0, 0, 0], [0, 0, 0, 0], [0, 0, 0, 0],
            [1, 2, 3, 4], [11, 12, 13, 14], [21, 22, 23, 24], [31, 32, 33, 34]
        ])
    }

    @Test("GC3 reading and storing one index share a slot and a repeated read is stable")
    func referenceEvaluatorDelayReadIsStableAndSharesTheSlot() throws {
        let empty = try ReferenceDelayLine(channels: 1, blockFrames: 2, delayBlocks: 3)
        #expect(empty.block(at: 4) == [0, 0])
        #expect(empty.block(at: 4) == empty.block(at: 4))
        let stored = empty.storing([7, 8], at: 4)
        #expect(stored.block(at: 4) == [7, 8])
        #expect(stored.block(at: 7) == [7, 8])
        #expect(stored.block(at: 5) == [0, 0])
        #expect(stored.block(at: 3) == [0, 0])
        #expect(stored.block(at: 4) == stored.block(at: 4))
    }

    @Test("GC3 storing is pure and a wrong length or negative index returns the line unchanged")
    func referenceEvaluatorDelayStoringIsPureAndRefusesBadInputByIdentity() throws {
        let original = try ReferenceDelayLine(channels: 2, blockFrames: 2, delayBlocks: 2)
        let updated = original.storing([1, 2, 3, 4], at: 0)
        #expect(updated != original)
        #expect(original == (try ReferenceDelayLine(channels: 2, blockFrames: 2, delayBlocks: 2)))
        #expect(original.storing([1, 2, 3], at: 0) == original)
        #expect(original.storing([1, 2, 3, 4, 5], at: 0) == original)
        #expect(original.storing([], at: 0) == original)
        #expect(updated.storing([9, 9, 9, 9], at: -1) == updated)
        #expect(updated.block(at: -1) == [0, 0, 0, 0])
    }

    @Test("GC3 delay line storage is planar per channel like the plan's delay storage")
    func referenceEvaluatorDelayStorageLayoutIsChannelMajor() throws {
        var line = try ReferenceDelayLine(channels: 2, blockFrames: 2, delayBlocks: 2)
        #expect(line.storage == [0, 0, 0, 0, 0, 0, 0, 0])
        line = line.storing([1, 2, 3, 4], at: 0)
        #expect(line.storage == [1, 2, 0, 0, 3, 4, 0, 0])
        line = line.storing([5, 6, 7, 8], at: 1)
        #expect(line.storage == [1, 2, 5, 6, 3, 4, 7, 8])
        line = line.storing([9, 10, 11, 12], at: 2)
        #expect(line.storage == [9, 10, 5, 6, 11, 12, 7, 8])
    }

    @Test("GC3 delay line handles one and sixty-four channels")
    func referenceEvaluatorDelayHandlesChannelExtremes() throws {
        for channels in [1, 64] {
            let reads = try Self.delayReads(channels: channels, frames: 2, delay: 2, blocks: 3)
            try #require(reads.count == 3)
            #expect(reads[0] == [Float](repeating: 0, count: channels * 2))
            #expect(reads[1] == [Float](repeating: 0, count: channels * 2))
            #expect(reads[2] == Self.delayBlock(0, channels: channels, frames: 2))
            #expect(reads[2].count == channels * 2)
        }
        let wide = try Self.delayReads(channels: 64, frames: 2, delay: 1, blocks: 2)
        try #require(wide.count == 2)
        #expect(wide[1].last == 128)
    }

    @Test("GC3 delay line init refuses non-positive geometry before checking overflow")
    func referenceEvaluatorDelayInitRefusesBadGeometry() throws {
        let defect = ReferenceEvaluatorRefusal.scheduleDefect(.delayGeometry)
        #expect(throws: defect) { try ReferenceDelayLine(channels: 0, blockFrames: 1, delayBlocks: 1) }
        #expect(throws: defect) { try ReferenceDelayLine(channels: -1, blockFrames: 1, delayBlocks: 1) }
        #expect(throws: defect) { try ReferenceDelayLine(channels: 1, blockFrames: 0, delayBlocks: 1) }
        #expect(throws: defect) { try ReferenceDelayLine(channels: 1, blockFrames: -1, delayBlocks: 1) }
        #expect(throws: defect) { try ReferenceDelayLine(channels: 1, blockFrames: 1, delayBlocks: 0) }
        #expect(throws: defect) { try ReferenceDelayLine(channels: 1, blockFrames: 1, delayBlocks: -1) }
        #expect(throws: defect) { try ReferenceDelayLine(channels: 0, blockFrames: Int.max, delayBlocks: Int.max) }
        #expect(throws: defect) { try ReferenceDelayLine(channels: Int.max, blockFrames: Int.max, delayBlocks: 0) }
        #expect(throws: ReferenceEvaluatorRefusal.arithmeticOverflow(.stateFloats)) {
            try ReferenceDelayLine(channels: Int.max, blockFrames: Int.max, delayBlocks: Int.max)
        }
        _ = try ReferenceDelayLine(channels: 1, blockFrames: 1, delayBlocks: 1)
    }

    @Test("GC3 delay line size overflow is a typed refusal in either factor")
    func referenceEvaluatorDelayInitRefusesOverflowWithoutTrapping() {
        let overflow = ReferenceEvaluatorRefusal.arithmeticOverflow(.stateFloats)
        #expect(throws: overflow) { try ReferenceDelayLine(channels: Int.max, blockFrames: 2, delayBlocks: 1) }
        #expect(throws: overflow) { try ReferenceDelayLine(channels: 2, blockFrames: Int.max / 2 + 1, delayBlocks: 1) }
        #expect(throws: overflow) { try ReferenceDelayLine(channels: 1, blockFrames: Int.max, delayBlocks: 2) }
        #expect(throws: overflow) {
            try ReferenceDelayLine(restoring: [], channels: 1, blockFrames: Int.max, delayBlocks: 2)
        }
    }

    @Test("GC3 restoring a delay line checks the length exactly")
    func referenceEvaluatorDelayRestoringChecksLength() throws {
        let storage: [Float] = [1, 2, 5, 6, 3, 4, 7, 8]
        let restored = try ReferenceDelayLine(restoring: storage, channels: 2, blockFrames: 2, delayBlocks: 2)
        #expect(restored.storage == storage)
        #expect(restored.block(at: 0) == [1, 2, 3, 4])
        #expect(restored.block(at: 1) == [5, 6, 7, 8])
        #expect(throws: ReferenceEvaluatorRefusal.stateMismatch) {
            try ReferenceDelayLine(restoring: Array(storage.dropLast()), channels: 2, blockFrames: 2, delayBlocks: 2)
        }
        #expect(throws: ReferenceEvaluatorRefusal.stateMismatch) {
            try ReferenceDelayLine(restoring: storage + [0], channels: 2, blockFrames: 2, delayBlocks: 2)
        }
        #expect(throws: ReferenceEvaluatorRefusal.scheduleDefect(.delayGeometry)) {
            try ReferenceDelayLine(restoring: [], channels: 2, blockFrames: 2, delayBlocks: 0)
        }
    }
}
