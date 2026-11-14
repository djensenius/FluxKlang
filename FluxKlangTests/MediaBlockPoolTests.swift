import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// The preallocated media block pool (#109 IO1). Creation and its bounds are here; leasing, copying, slot
/// generations, statistics and seeded random sequences are in the `MediaBlockPoolTests+...` extensions, which share
/// the builders below.
@Suite("Media block pool", .productionAccessAudit)
struct MediaBlockPoolTests {
    /// Everything a refused operation must leave untouched.
    struct Snapshot: Equatable {
        let statistics: MediaBlockPoolStatistics
        let freeOrder: [Int]
    }

    /// A pool of `blockCount` blocks of 64 frames and `channels` channels.
    static func makePool(
        blockCount: Int = 4,
        channels: Int = 2,
        maximumGeneration: Int = MediaBlockPool.defaultMaximumGeneration
    ) throws -> MediaBlockPool {
        let plan = try PrefetchPlan.make(blockFrames: 64, blockCount: blockCount, headFrames: 64)
        return try MediaBlockPool.make(plan: plan, channelCount: channels, maximumGeneration: maximumGeneration)
    }

    static func refusal(_ body: () throws -> some Any) -> MediaBlockPoolRefusal? {
        do {
            _ = try body()
            return nil
        } catch {
            return error as? MediaBlockPoolRefusal
        }
    }

    static func snapshot(_ pool: MediaBlockPool) -> Snapshot {
        Snapshot(statistics: pool.statistics, freeOrder: pool.freeSlotsInLeaseOrder())
    }

    /// `frames x channels` distinct, exactly representable samples: `first`, `first + 1`, ...
    static func ramp(frames: Int, channels: Int, first: Float = 1) -> [Float] {
        (0..<(frames * channels)).map { first + Float($0) }
    }

    /// Copies `samples` into `lease` as `frames` frames of `channels` channels (default: the pool's own).
    static func fill(
        _ pool: MediaBlockPool,
        _ samples: [Float],
        frames: Int,
        lease: MediaBlockLease,
        channels: Int? = nil
    ) throws {
        let width = channels ?? pool.channelCount
        try samples.withUnsafeBufferPointer { buffer in
            try pool.copyIn(buffer, frames: frames, channels: width, into: lease)
        }
    }

    static func leaseAll(_ pool: MediaBlockPool, count: Int) throws -> [MediaBlockLease] {
        var leases: [MediaBlockLease] = []
        for _ in 0..<count {
            try leases.append(pool.lease())
        }
        return leases
    }

    @Test
    func channelCountBoundsAreOneThroughSixteen() throws {
        #expect(MediaBlockPool.channelCountRange == 1...16)
        for channels in [1, 16] {
            let pool = try Self.makePool(channels: channels)
            #expect(pool.channelCount == channels)
        }
        for channels in [-1, 0, 17] {
            let refused = Self.refusal { try Self.makePool(channels: channels) }
            #expect(refused == .channelCountOutOfRange(channels))
        }
    }

    @Test
    func maximumGenerationBoundsAreZeroThroughUInt32Max() throws {
        #expect(MediaBlockPool.defaultMaximumGeneration == Int(UInt32.max))
        #expect(try Self.makePool().maximumGeneration == UInt32.max)
        for limit in [0, 1, Int(UInt32.max)] {
            let pool = try Self.makePool(maximumGeneration: limit)
            #expect(Int(pool.maximumGeneration) == limit)
        }
        for limit in [-1, Int(UInt32.max) + 1, Int.max, Int.min] {
            let refused = Self.refusal { try Self.makePool(maximumGeneration: limit) }
            #expect(refused == .maximumGenerationOutOfRange(limit))
        }
    }

    @Test
    func sampleCapacityAcceptsExactlyTheByteCapAndRefusesOneSampleMore() {
        let cap = MediaBlockPool.maximumSampleCapacity
        #expect(MediaBlockPool.maximumSampleBytes == 268_435_456)
        #expect(cap == 67_108_864)
        #expect(cap * MemoryLayout<Float>.stride == MediaBlockPool.maximumSampleBytes)
        // N: exactly the cap, however it factorises into frames and channels.
        #expect(MediaBlockPool.capacityRefusal(poolFrames: cap, channelCount: 1) == nil)
        #expect(MediaBlockPool.capacityRefusal(poolFrames: cap / 2, channelCount: 2) == nil)
        #expect(MediaBlockPool.capacityRefusal(poolFrames: cap / 16, channelCount: 16) == nil)
        #expect(MediaBlockPool.capacityRefusal(poolFrames: 0, channelCount: 16) == nil)
        // N+1: one sample more at one channel, and one frame more at two and at sixteen channels.
        let oneMore = MediaBlockPool.capacityRefusal(poolFrames: cap + 1, channelCount: 1)
        #expect(oneMore == .capacityExceedsCap(samples: cap + 1, maximum: cap))
        let twoMore = MediaBlockPool.capacityRefusal(poolFrames: cap / 2 + 1, channelCount: 2)
        #expect(twoMore == .capacityExceedsCap(samples: cap + 2, maximum: cap))
        let sixteenMore = MediaBlockPool.capacityRefusal(poolFrames: cap / 16 + 1, channelCount: 16)
        #expect(sixteenMore == .capacityExceedsCap(samples: cap + 16, maximum: cap))
    }

    @Test
    func sampleCapacityOverflowIsRefusedNotTrapped() {
        let cap = MediaBlockPool.maximumSampleCapacity
        let overflowing: [(frames: Int, channels: Int)] = [
            (Int.max, 2), (Int.max / 2 + 1, 2), (Int.max, 16), (1 << 62, 4), (Int.max / 16 + 1, 16)
        ]
        for (frames, channels) in overflowing {
            let refused = MediaBlockPool.capacityRefusal(poolFrames: frames, channelCount: channels)
            #expect(refused == .capacityExceedsCap(samples: Int.max, maximum: cap))
        }
        // The largest product that does not overflow is reported exactly, not as the overflow sentinel.
        let largest = MediaBlockPool.capacityRefusal(poolFrames: Int.max / 2, channelCount: 2)
        #expect(largest == .capacityExceedsCap(samples: Int.max - 1, maximum: cap))
    }

    @Test
    func makeRefusesAPlanAboveTheCapBeforeAllocatingAnything() throws {
        let cap = MediaBlockPool.maximumSampleCapacity
        // 32_769 x 1_024 frames at two channels is 67_110_912 samples: 2_048 over the cap.
        let justOver = try PrefetchPlan.make(blockFrames: 32_769, blockCount: 1_024, headFrames: 1)
        #expect(justOver.poolFrames == 33_555_456)
        let refused = Self.refusal { try MediaBlockPool.make(plan: justOver, channelCount: 2) }
        #expect(refused == .capacityExceedsCap(samples: 67_110_912, maximum: cap))
        // The largest plan the prefetch bounds allow is exactly the cap at one channel, and double it at two.
        let largest = try PrefetchPlan.make(blockFrames: 65_536, blockCount: 1_024, headFrames: 1)
        #expect(largest.poolFrames == cap)
        #expect(MediaBlockPool.capacityRefusal(poolFrames: largest.poolFrames, channelCount: 1) == nil)
        let doubled = MediaBlockPool.capacityRefusal(poolFrames: largest.poolFrames, channelCount: 2)
        #expect(doubled == .capacityExceedsCap(samples: 2 * cap, maximum: cap))
    }

    @Test
    func makeChecksChannelsThenMaximumGenerationThenCapacity() throws {
        let cap = MediaBlockPool.maximumSampleCapacity
        let tooBig = try PrefetchPlan.make(blockFrames: 32_769, blockCount: 1_024, headFrames: 1)
        // All three wrong: the channel count is reported first.
        let allWrong = Self.refusal {
            try MediaBlockPool.make(plan: tooBig, channelCount: 0, maximumGeneration: -1)
        }
        #expect(allWrong == .channelCountOutOfRange(0))
        // Channels fine, generation and capacity wrong: the generation is reported before the capacity.
        let generationFirst = Self.refusal {
            try MediaBlockPool.make(plan: tooBig, channelCount: 2, maximumGeneration: -1)
        }
        #expect(generationFirst == .maximumGenerationOutOfRange(-1))
        // Only the capacity is wrong.
        let capacityOnly = Self.refusal { try MediaBlockPool.make(plan: tooBig, channelCount: 2) }
        #expect(capacityOnly == .capacityExceedsCap(samples: 67_110_912, maximum: cap))
    }

    @Test
    func freshPoolHasExactShapeStatisticsAndLeaseOrder() throws {
        let plan = try PrefetchPlan.make(blockFrames: 128, blockCount: 5, headFrames: 200)
        let pool = try MediaBlockPool.make(plan: plan, channelCount: 3)
        #expect(pool.plan == plan)
        #expect(pool.channelCount == 3)
        #expect(pool.samplesPerBlock == 384)
        #expect(pool.sampleCapacity == 1_920)
        #expect(pool.maximumGeneration == UInt32.max)
        #expect(pool.statistics == MediaBlockPoolStatistics(blockCount: 5))
        #expect(pool.statistics.freeCount == 5)
        #expect(pool.freeSlotsInLeaseOrder() == [0, 1, 2, 3, 4])
        var slots: [Int] = []
        for _ in 0..<5 {
            try slots.append(pool.lease().slot)
        }
        #expect(slots == [0, 1, 2, 3, 4])
    }

    @Test
    func largestBlockShapeIsAcceptedAndUsable() throws {
        // The widest block the plan bounds allow: 65_536 frames x 16 channels, in a pool of two (8 MiB of samples).
        let plan = try PrefetchPlan.make(blockFrames: 65_536, blockCount: 2, headFrames: 65_536)
        let pool = try MediaBlockPool.make(plan: plan, channelCount: 16)
        #expect(pool.samplesPerBlock == 1_048_576)
        #expect(pool.sampleCapacity == 2_097_152)
        let first = try pool.lease()
        let second = try pool.lease()
        let secondSamples = Self.ramp(frames: 65_536, channels: 16)
        try Self.fill(pool, secondSamples, frames: 65_536, lease: second)
        #expect(try pool.usedFrames(of: second) == 65_536)
        #expect(try pool.usedFrames(of: first) == 0)
        let firstSamples = Self.ramp(frames: 65_536, channels: 16, first: 2_000_000)
        try Self.fill(pool, firstSamples, frames: 65_536, lease: first)
        // Full blocks next to each other do not bleed into one another. The comparison is reduced to a Bool so a
        // failure does not print a million samples.
        let secondIntact = try pool.copyOut(of: second) == secondSamples
        #expect(secondIntact)
        let firstOut = try pool.copyOut(of: first)
        #expect(firstOut.count == 1_048_576)
        #expect(firstOut.first == 2_000_000 && firstOut.last == 3_048_575)
    }
}
