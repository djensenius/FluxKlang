import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// The one explicit, bounded capture copy of the media block pool: exact contents, exact bounds, no partial copies,
/// exact counters, and a content policy under which no earlier sample is ever visible.
extension MediaBlockPoolTests {
    @Test
    func copyInStoresExactInterleavedSamplesAndSetsUsedFrames() throws {
        let pool = try Self.makePool(blockCount: 2, channels: 2)
        let lease = try pool.lease()
        #expect(try pool.usedFrames(of: lease) == 0)
        #expect(try pool.copyOut(of: lease).isEmpty)
        // Three stereo frames: left and right alternate, so any channel mix-up or reordering is visible.
        let samples: [Float] = [0.5, -0.5, 0.25, -0.25, 1, -1]
        try Self.fill(pool, samples, frames: 3, lease: lease)
        #expect(try pool.usedFrames(of: lease) == 3)
        #expect(try pool.copyOut(of: lease) == samples)
        let viewed = try pool.withSamples(of: lease) { Array($0) }
        #expect(viewed == samples)
        // The pool keeps its own copy: changing the caller's array afterwards changes nothing.
        var callerOwned = samples
        try Self.fill(pool, callerOwned, frames: 3, lease: lease)
        callerOwned[0] = 99
        #expect(try pool.copyOut(of: lease) == samples)
    }

    @Test
    func blocksAreIsolatedAtEverySlot() throws {
        let pool = try Self.makePool(blockCount: 4, channels: 3)
        let leases = try Self.leaseAll(pool, count: 4)
        var expected: [[Float]] = []
        for (index, lease) in leases.enumerated() {
            // Every block is filled completely, each with its own value range, so a copy that strays into a
            // neighbouring block shows up as a changed sample there.
            let samples = Self.ramp(frames: 64, channels: 3, first: Float(1_000 * (index + 1)))
            try Self.fill(pool, samples, frames: 64, lease: lease)
            expected.append(samples)
        }
        for (index, lease) in leases.enumerated() {
            let intact = try pool.copyOut(of: lease) == expected[index]
            #expect(intact, "block \(index)")
        }
    }

    @Test
    func copyFrameCountBoundsAreZeroThroughBlockFrames() throws {
        let pool = try Self.makePool(blockCount: 2, channels: 2)
        let lease = try pool.lease()
        // N: zero frames and exactly the block's frames are accepted (an empty source may have no base address).
        try Self.fill(pool, [], frames: 0, lease: lease)
        #expect(try pool.usedFrames(of: lease) == 0)
        let full = Self.ramp(frames: 64, channels: 2)
        try Self.fill(pool, full, frames: 64, lease: lease)
        #expect(try pool.usedFrames(of: lease) == 64)
        // N+1 and beyond, with a source of exactly the matching length so only the frame count is wrong.
        var refused: UInt64 = 0
        for frames in [65, 66, 1_000] {
            let source = Self.ramp(frames: frames, channels: 2)
            let result = Self.refusal { try Self.fill(pool, source, frames: frames, lease: lease) }
            #expect(result == .framesOutOfRange(frames: frames, blockFrames: 64))
            refused += 1
        }
        // Negative and absurd counts are refused without ever reaching the length arithmetic.
        for frames in [-1, Int.min, Int.max] {
            let result = Self.refusal { try Self.fill(pool, [], frames: frames, lease: lease) }
            #expect(result == .framesOutOfRange(frames: frames, blockFrames: 64))
            refused += 1
        }
        #expect(pool.statistics.copiesRefused == refused)
        #expect(pool.statistics.copiesCompleted == 2 && pool.statistics.framesCopied == 64)
        #expect(try pool.usedFrames(of: lease) == 64)
        let intact = try pool.copyOut(of: lease) == full
        #expect(intact)
    }

    @Test
    func oversizeCopyIsRefusedWithoutAnyPartialCopy() throws {
        let pool = try Self.makePool(blockCount: 2, channels: 2)
        let first = try pool.lease()
        let second = try pool.lease()
        let neighbour = Self.ramp(frames: 64, channels: 2, first: 5_000)
        try Self.fill(pool, neighbour, frames: 64, lease: second)
        // The block is completely full, so even one stray sample of a partial copy would be visible.
        let original = Self.ramp(frames: 64, channels: 2)
        try Self.fill(pool, original, frames: 64, lease: first)
        let before = pool.statistics
        let oversize = Self.ramp(frames: 65, channels: 2, first: -9_000)
        let result = Self.refusal { try Self.fill(pool, oversize, frames: 65, lease: first) }
        #expect(result == .framesOutOfRange(frames: 65, blockFrames: 64))
        let firstIntact = try pool.copyOut(of: first) == original
        let secondIntact = try pool.copyOut(of: second) == neighbour
        #expect(firstIntact && secondIntact)
        #expect(try pool.usedFrames(of: first) == 64)
        #expect(pool.statistics.copiesRefused == before.copiesRefused + 1)
        #expect(pool.statistics.copiesCompleted == before.copiesCompleted)
        #expect(pool.statistics.framesCopied == before.framesCopied)
    }

    @Test
    func copyChannelMismatchIsRefusedCountedAndChangesNothingElse() throws {
        let pool = try Self.makePool(blockCount: 2, channels: 2)
        let lease = try pool.lease()
        let original = Self.ramp(frames: 3, channels: 2)
        try Self.fill(pool, original, frames: 3, lease: lease)
        let before = Self.snapshot(pool)
        var refused: UInt64 = 0
        for channels in [1, 3, 0, -1, 16] {
            // The source matches the (wrong) channel count, so only the channel count is at fault.
            let source = Self.ramp(frames: 3, channels: Swift.max(channels, 0))
            let result = Self.refusal {
                try Self.fill(pool, source, frames: 3, lease: lease, channels: channels)
            }
            #expect(result == .channelCountMismatch(expected: 2, found: channels))
            refused += 1
            #expect(pool.statistics.copiesRefused == refused)
        }
        #expect(try pool.copyOut(of: lease) == original)
        #expect(try pool.usedFrames(of: lease) == 3)
        #expect(pool.statistics.copiesCompleted == before.statistics.copiesCompleted)
        #expect(pool.statistics.framesCopied == before.statistics.framesCopied)
        #expect(pool.freeSlotsInLeaseOrder() == before.freeOrder)
    }

    @Test
    func sourceLengthMustEqualFramesTimesChannelsExactly() throws {
        let pool = try Self.makePool(blockCount: 2, channels: 2)
        let lease = try pool.lease()
        let original = Self.ramp(frames: 3, channels: 2)
        try Self.fill(pool, original, frames: 3, lease: lease)
        // Three stereo frames need exactly six samples: one fewer, one more and none are all refused.
        let cases: [(count: Int, frames: Int)] = [(5, 3), (7, 3), (0, 3), (1, 0), (130, 64), (127, 64)]
        for (count, frames) in cases {
            let source = [Float](repeating: 1, count: count)
            let result = Self.refusal { try Self.fill(pool, source, frames: frames, lease: lease) }
            #expect(result == .sourceLengthMismatch(expected: frames * 2, found: count))
        }
        #expect(pool.statistics.copiesRefused == 6)
        #expect(try pool.copyOut(of: lease) == original)
        // The exact lengths are accepted.
        try Self.fill(pool, Self.ramp(frames: 3, channels: 2, first: 40), frames: 3, lease: lease)
        try Self.fill(pool, [], frames: 0, lease: lease)
        #expect(pool.statistics.copiesCompleted == 3)
    }

    @Test
    func copyShapeChecksRunChannelsThenFramesThenLength() throws {
        let pool = try Self.makePool(blockCount: 2, channels: 2)
        let lease = try pool.lease()
        let dead = try pool.lease()
        try pool.release(dead)
        // A lease problem is reported before any shape problem, and is not counted as a refused copy.
        let deadShape = Self.refusal { try Self.fill(pool, [1], frames: 99, lease: dead, channels: 5) }
        #expect(deadShape == .leaseAlreadyReleased(slot: 1))
        #expect(pool.statistics.copiesRefused == 0)
        // Channels before frames: with both wrong, the channel count is reported.
        let channelsFirst = Self.refusal {
            try Self.fill(pool, [1, 2, 3], frames: 65, lease: lease, channels: 3)
        }
        #expect(channelsFirst == .channelCountMismatch(expected: 2, found: 3))
        // Frames before length: with the frame count out of range and a source of the wrong length, the frame
        // count is reported.
        let framesFirst = Self.refusal { try Self.fill(pool, [1, 2, 3], frames: 65, lease: lease) }
        #expect(framesFirst == .framesOutOfRange(frames: 65, blockFrames: 64))
        // The length is checked last.
        let lengthLast = Self.refusal { try Self.fill(pool, [1, 2, 3], frames: 2, lease: lease) }
        #expect(lengthLast == .sourceLengthMismatch(expected: 4, found: 3))
        // All three wrong: the channel count.
        let allWrong = Self.refusal { try Self.fill(pool, [1], frames: -4, lease: lease, channels: 7) }
        #expect(allWrong == .channelCountMismatch(expected: 2, found: 7))
        #expect(pool.statistics.copiesRefused == 4)
    }

    @Test
    func emptySourceWithoutABaseAddressIsAnAcceptedZeroFrameCopy() throws {
        let pool = try Self.makePool(blockCount: 2, channels: 2)
        let lease = try pool.lease()
        let original = Self.ramp(frames: 3, channels: 2)
        try Self.fill(pool, original, frames: 3, lease: lease)
        #expect(pool.statistics.copiesCompleted == 1 && pool.statistics.framesCopied == 3)
        // A buffer with no base address and no samples is a valid source for a zero-frame copy, which copies
        // nothing but still replaces the block's visible content.
        let empty = UnsafeBufferPointer<Float>(start: nil, count: 0)
        #expect(empty.baseAddress == nil && empty.isEmpty)
        try pool.copyIn(empty, frames: 0, channels: 2, into: lease)
        #expect(try pool.usedFrames(of: lease) == 0)
        #expect(try pool.copyOut(of: lease).isEmpty)
        #expect(pool.statistics.copiesCompleted == 2 && pool.statistics.framesCopied == 3)
        #expect(pool.statistics.copiesRefused == 0)
        // The same buffer cannot supply any frame: refused for its length, counted once, nothing else changes.
        let before = Self.snapshot(pool)
        let refused = Self.refusal { try pool.copyIn(empty, frames: 1, channels: 2, into: lease) }
        #expect(refused == .sourceLengthMismatch(expected: 2, found: 0))
        #expect(pool.statistics.copiesRefused == before.statistics.copiesRefused + 1)
        #expect(pool.statistics.copiesCompleted == before.statistics.copiesCompleted)
        #expect(pool.statistics.framesCopied == before.statistics.framesCopied)
        #expect(pool.freeSlotsInLeaseOrder() == before.freeOrder)
        #expect(try pool.usedFrames(of: lease) == 0)
    }

    #if !DEBUG
    /// Release only: a debug build traps inside the standard library when it builds a buffer with no base address
    /// and a non-zero count, so this case can only be reached from an optimized build (`swift test -c release`).
    @Test
    func sourceWithoutABaseAddressHoldsNoSamplesAndIsRefusedBeforeAnyCopy() throws {
        let pool = try Self.makePool(blockCount: 2, channels: 2)
        let lease = try pool.lease()
        let original = Self.ramp(frames: 3, channels: 2)
        try Self.fill(pool, original, frames: 3, lease: lease)
        let before = Self.snapshot(pool)
        // The buffer claims 128 samples (64 stereo frames) but has no storage behind it.
        let phantom = UnsafeBufferPointer<Float>(start: nil, count: 128)
        #expect(phantom.baseAddress == nil)
        let refused = Self.refusal { try pool.copyIn(phantom, frames: 64, channels: 2, into: lease) }
        #expect(refused == .sourceLengthMismatch(expected: 128, found: 0))
        #expect(pool.statistics.copiesRefused == before.statistics.copiesRefused + 1)
        #expect(pool.statistics.copiesCompleted == before.statistics.copiesCompleted)
        #expect(pool.statistics.framesCopied == before.statistics.framesCopied)
        #expect(pool.freeSlotsInLeaseOrder() == before.freeOrder)
        #expect(try pool.usedFrames(of: lease) == 3)
        #expect(try pool.copyOut(of: lease) == original)
        // With no frame to copy nothing is read from the buffer, so a zero-frame copy is accepted.
        try pool.copyIn(phantom, frames: 0, channels: 2, into: lease)
        #expect(try pool.usedFrames(of: lease) == 0)
        #expect(pool.statistics.copiesCompleted == before.statistics.copiesCompleted + 1)
        #expect(pool.statistics.copiesRefused == before.statistics.copiesRefused + 1)
    }
    #endif

    @Test
    func copyCountersAreExactAcrossAcceptedAndRefusedCopies() throws {
        let pool = try Self.makePool(blockCount: 2, channels: 2)
        let lease = try pool.lease()
        let fresh = pool.statistics
        #expect(fresh.framesCopied == 0 && fresh.copiesCompleted == 0 && fresh.copiesRefused == 0)
        try Self.fill(pool, Self.ramp(frames: 3, channels: 2), frames: 3, lease: lease)
        #expect(pool.statistics.framesCopied == 3 && pool.statistics.copiesCompleted == 1)
        try Self.fill(pool, Self.ramp(frames: 64, channels: 2), frames: 64, lease: lease)
        #expect(pool.statistics.framesCopied == 67 && pool.statistics.copiesCompleted == 2)
        try Self.fill(pool, [], frames: 0, lease: lease)
        #expect(pool.statistics.framesCopied == 67 && pool.statistics.copiesCompleted == 3)
        #expect(pool.statistics.copiesRefused == 0)
        // One refusal of each kind: each adds exactly one to the refused count and nothing to the others.
        let channels = Self.refusal { try Self.fill(pool, [1], frames: 1, lease: lease, channels: 1) }
        #expect(channels == .channelCountMismatch(expected: 2, found: 1))
        #expect(pool.statistics.copiesRefused == 1)
        let frames = Self.refusal { try Self.fill(pool, [], frames: 65, lease: lease) }
        #expect(frames == .framesOutOfRange(frames: 65, blockFrames: 64))
        #expect(pool.statistics.copiesRefused == 2)
        let length = Self.refusal { try Self.fill(pool, [1], frames: 1, lease: lease) }
        #expect(length == .sourceLengthMismatch(expected: 2, found: 1))
        #expect(pool.statistics.copiesRefused == 3)
        #expect(pool.statistics.framesCopied == 67 && pool.statistics.copiesCompleted == 3)
        // The block counts are unaffected by any copy.
        #expect(pool.statistics.leasedCount == 1 && pool.statistics.freeCount == 1)
    }

    @Test
    func copyRefusedForALeaseProblemIsNotCountedAsARefusedCopy() throws {
        let pool = try Self.makePool(blockCount: 3, channels: 2)
        let other = try Self.makePool(blockCount: 3, channels: 2)
        let live = try pool.lease()
        let old = try pool.lease()
        try pool.release(old)
        let again = try pool.lease()
        let foreign = try other.lease()
        let stale = MediaBlockPoolRefusal.staleLease(slot: 1, leaseGeneration: 0, currentGeneration: 1)
        // Every one of these has a wrong shape too (a single sample for three frames): the lease problem wins.
        let wrongShape: [Float] = [1]
        let staleResult = Self.refusal { try Self.fill(pool, wrongShape, frames: 3, lease: old) }
        #expect(staleResult == stale)
        let foreignResult = Self.refusal { try Self.fill(pool, wrongShape, frames: 3, lease: foreign) }
        #expect(foreignResult == .foreignLease)
        #expect(pool.statistics.copiesRefused == 0 && pool.statistics.copiesCompleted == 0)
        // A scoped read in progress also wins over a wrong shape.
        var duringRead: MediaBlockPoolRefusal?
        try pool.withSamples(of: live) { (_: UnsafeBufferPointer<Float>) in
            duringRead = Self.refusal { try Self.fill(pool, wrongShape, frames: 3, lease: again) }
        }
        #expect(duringRead == .accessInProgress)
        #expect(pool.statistics.copiesRefused == 0 && pool.statistics.copiesCompleted == 0)
        #expect(pool.statistics.framesCopied == 0)
    }

    @Test
    func copyInReplacesEarlierContentWithoutAppending() throws {
        let pool = try Self.makePool(blockCount: 2, channels: 2)
        let lease = try pool.lease()
        let first = Self.ramp(frames: 3, channels: 2, first: 10)
        try Self.fill(pool, first, frames: 3, lease: lease)
        let second = Self.ramp(frames: 2, channels: 2, first: 100)
        try Self.fill(pool, second, frames: 2, lease: lease)
        #expect(try pool.usedFrames(of: lease) == 2)
        #expect(try pool.copyOut(of: lease) == second)
        let third = Self.ramp(frames: 5, channels: 2, first: 200)
        try Self.fill(pool, third, frames: 5, lease: lease)
        #expect(try pool.usedFrames(of: lease) == 5)
        #expect(try pool.copyOut(of: lease) == third)
        // A zero-frame copy empties the visible content.
        try Self.fill(pool, [], frames: 0, lease: lease)
        #expect(try pool.usedFrames(of: lease) == 0)
        #expect(try pool.copyOut(of: lease).isEmpty)
        #expect(pool.statistics.framesCopied == 10 && pool.statistics.copiesCompleted == 4)
    }

    @Test
    func newLeaseOfAReusedBlockExposesNoEarlierSamples() throws {
        let pool = try Self.makePool(blockCount: 2, channels: 2)
        let first = try pool.lease()
        try Self.fill(pool, Self.ramp(frames: 64, channels: 2, first: 7), frames: 64, lease: first)
        try pool.release(first)
        // Blocks are handed out most-recently-released first, so this is the very same block, still holding the
        // earlier samples in storage; none of them may be visible.
        let reused = try pool.lease()
        #expect(reused.slot == first.slot)
        #expect(try pool.usedFrames(of: reused) == 0)
        #expect(try pool.copyOut(of: reused).isEmpty)
        let viewCount = try pool.withSamples(of: reused) { $0.count }
        #expect(viewCount == 0)
        // An untouched block never shows its zero-filled storage either.
        let untouched = try pool.lease()
        #expect(try pool.usedFrames(of: untouched) == 0)
        #expect(try pool.copyOut(of: untouched).isEmpty)
    }

    @Test
    func shorterCopyIntoAReusedBlockNeverExposesTheEarlierTail() throws {
        let pool = try Self.makePool(blockCount: 2, channels: 2)
        let first = try pool.lease()
        try Self.fill(pool, Self.ramp(frames: 64, channels: 2, first: 7), frames: 64, lease: first)
        try pool.release(first)
        let reused = try pool.lease()
        #expect(reused.slot == first.slot)
        let shorter = Self.ramp(frames: 2, channels: 2, first: 500)
        try Self.fill(pool, shorter, frames: 2, lease: reused)
        // Four samples, not 128: the earlier tail is in storage but not in the view.
        let viewCount = try pool.withSamples(of: reused) { $0.count }
        #expect(viewCount == 4)
        #expect(try pool.copyOut(of: reused) == shorter)
        // The same holds for a shorter copy into a block that stays leased.
        try Self.fill(pool, Self.ramp(frames: 64, channels: 2, first: 900), frames: 64, lease: reused)
        let shortest = Self.ramp(frames: 1, channels: 2, first: 33)
        try Self.fill(pool, shortest, frames: 1, lease: reused)
        let shortestCount = try pool.withSamples(of: reused) { $0.count }
        #expect(shortestCount == 2)
        #expect(try pool.copyOut(of: reused) == shortest)
    }

    @Test
    func scopedReadExposesExactlyUsedFramesTimesChannels() throws {
        for channels in [1, 2, 5] {
            for frames in [0, 1, 7, 64] {
                let pool = try Self.makePool(blockCount: 2, channels: channels)
                let lease = try pool.lease()
                let samples = Self.ramp(frames: frames, channels: channels, first: 3)
                try Self.fill(pool, samples, frames: frames, lease: lease)
                let viewed = try pool.withSamples(of: lease) { Array($0) }
                #expect(viewed.count == frames * channels)
                #expect(viewed == samples)
                #expect(try pool.usedFrames(of: lease) == frames)
            }
        }
    }

    @Test
    func refusedScopedReadNeverRunsItsBody() throws {
        let pool = try Self.makePool(blockCount: 3, channels: 2)
        let other = try Self.makePool(blockCount: 3, channels: 2)
        let gone = try pool.lease()
        try pool.release(gone)
        let replacement = try pool.lease()
        let foreign = try other.lease()
        var ran = false
        let released = Self.refusal { try pool.withSamples(of: gone) { _ in ran = true } }
        #expect(released == .staleLease(slot: 0, leaseGeneration: 0, currentGeneration: 1))
        let foreigner = Self.refusal { try pool.withSamples(of: foreign) { _ in ran = true } }
        #expect(foreigner == .foreignLease)
        try pool.release(replacement)
        let dead = Self.refusal { try pool.withSamples(of: replacement) { _ in ran = true } }
        #expect(dead == .leaseAlreadyReleased(slot: 0))
        #expect(!ran)
        // A valid lease does run it, exactly once.
        let live = try pool.lease()
        var runs = 0
        try pool.withSamples(of: live) { _ in runs += 1 }
        #expect(runs == 1)
    }
}
