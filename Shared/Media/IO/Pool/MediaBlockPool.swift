//
//  MediaBlockPool.swift
//  FluxKlang
//
//  A fixed set of preallocated media sample blocks with explicit lease and
//  release and one explicit, bounded capture copy (#109 IO1,
//  media-contract.md §8.2). Pure Swift: no files, no threads, no clocks, no
//  locks and no atomics.
//

/// The unforgeable token that ties a `MediaBlockLease` to the pool that issued it.
///
/// Only this file can create one (the initialiser is `fileprivate`), so a lease cannot be forged outside the pool.
/// A lease retains its token, so a token's address is never reused while a lease can still be presented: a lease
/// from a deallocated pool can never be mistaken for a lease from a newer pool.
final class MediaBlockPoolIdentity: Hashable, Sendable {
    fileprivate init() {}

    static func == (lhs: MediaBlockPoolIdentity, rhs: MediaBlockPoolIdentity) -> Bool {
        lhs === rhs
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }
}

/// One block's bookkeeping. A slot is free exactly when it is on the free stack, leased when `isLeased`, and retired
/// when it is neither (its generation reached the pool's maximum when it was released).
private struct MediaBlockSlot {
    var isLeased = false
    var generation: UInt32 = 0
    var usedFrames = 0
}

/// A fixed set of preallocated media sample blocks for off-render I/O: explicit lease and release, one bounded
/// capture copy, and typed refusals instead of allocation or blocking.
///
/// **Shape.** `make(plan:channelCount:maximumGeneration:)` builds the pool once from a `PrefetchPlan` (every block
/// holds `plan.blockFrames` frames, there are `plan.blockCount` blocks) and a channel count in `1...16`. Samples are
/// interleaved `Float`. All sample storage, the slot table and the free stack are allocated there and released in
/// `deinit`; `lease`, `release`, `copyIn`, `withSamples` and `usedFrames(of:)` never allocate and the pool never
/// grows. Sample storage is capped at `maximumSampleBytes` (256 MiB, 67_108_864 samples); a plan that would exceed
/// the cap is refused before anything is allocated.
///
/// **Threading.** Single owner, not thread-safe: every call must come from the pool's owning execution context. The
/// class is deliberately not `Sendable` and uses no locks or atomics; moving leases between threads is the I/O
/// worker layer's job, not this type's.
///
/// **Leases.** A `MediaBlockLease` names one block and the slot generation it was issued at. Releasing a block
/// bumps its slot generation by exactly one, so every older lease of that block becomes stale and is refused.
/// A slot whose generation has reached `maximumGeneration` is retired when its lease is released: it is counted,
/// reported as `.retired`, and never leased again, so a generation can never wrap. A slot therefore offers
/// `maximumGeneration + 1` leases; the default limit is `UInt32.max`.
///
/// **Order.** Blocks are handed out last-in, first-out from a fixed free stack. A fresh pool leases slots
/// `0, 1, 2, ...`; after that the most recently released block is leased next. Retired blocks never return.
///
/// **Content.** Blocks are never cleared (leasing is O(1)); instead no earlier sample is ever observable. A new
/// lease has `usedFrames == 0`, `copyIn` replaces the block's visible content from its first frame (it never
/// appends), and the accessors expose only the first `usedFrames x channelCount` samples. Storage is zero-filled
/// once at creation.
///
/// **Access.** No mutable pointer escapes this type: samples are read through `withSamples(of:_:)`, which limits
/// the view to the used frames and refuses pool changes while it runs, or copied out with `copyOut(of:)`.
final class MediaBlockPool {
    // MARK: - Limits

    /// Supported channel counts: `1...16`.
    static let channelCountRange = 1...16
    /// The cap on the pool's sample storage, in bytes: 256 MiB.
    static let maximumSampleBytes = 256 * 1_048_576
    /// The cap on the pool's sample storage, in `Float` samples (`poolFrames x channelCount`): 67_108_864.
    static let maximumSampleCapacity = maximumSampleBytes / MemoryLayout<Float>.stride
    /// The default, and largest accepted, per-slot generation limit: `UInt32.max`.
    static let defaultMaximumGeneration = Int(UInt32.max)

    // MARK: - Shape

    /// The block geometry: `plan.blockFrames` frames per block, `plan.blockCount` blocks.
    let plan: PrefetchPlan
    /// Interleaved channels per frame, `1...16`.
    let channelCount: Int
    /// The slot generation at which a released block is retired instead of returned.
    let maximumGeneration: UInt32
    /// Samples in one block: `plan.blockFrames x channelCount`.
    let samplesPerBlock: Int
    /// Samples in the whole pool: `plan.poolFrames x channelCount`.
    let sampleCapacity: Int
    /// Exact accounting; only the pool changes it.
    private(set) var statistics: MediaBlockPoolStatistics

    private let identity = MediaBlockPoolIdentity()
    private let storage: UnsafeMutablePointer<Float>
    private var slots: [MediaBlockSlot]
    private var freeStack: [Int]
    private var freeTop: Int
    private var readerDepth = 0

    // MARK: - Creation

    /// Builds a pool. Refusals, in the order they are checked: the channel count, then the generation limit, then
    /// the storage cap. Nothing is allocated for a refused request.
    ///
    /// `maximumGeneration` is the slot generation at which a released block is retired; the default is
    /// `UInt32.max`. A small limit makes the retirement path reachable without billions of leases.
    ///
    /// **Memory.** An accepted request allocates and zero-fills the whole pool at once, up to
    /// `maximumSampleBytes` (256 MiB). The allocation has no throwing path, so running out of memory aborts the
    /// process instead of being refused, and zero-filling touches every page, so all of it is committed
    /// immediately. Size and create the pool during setup, before the render path starts; never on that path.
    static func make(
        plan: PrefetchPlan,
        channelCount: Int,
        maximumGeneration: Int = MediaBlockPool.defaultMaximumGeneration
    ) throws(MediaBlockPoolRefusal) -> MediaBlockPool {
        guard channelCountRange.contains(channelCount) else {
            throw .channelCountOutOfRange(channelCount)
        }
        guard let limit = UInt32(exactly: maximumGeneration) else {
            throw .maximumGenerationOutOfRange(maximumGeneration)
        }
        if let refusal = capacityRefusal(poolFrames: plan.poolFrames, channelCount: channelCount) {
            throw refusal
        }
        return MediaBlockPool(plan: plan, channelCount: channelCount, maximumGeneration: limit)
    }

    /// The storage-cap check `make` applies, as a pure function: nil when `poolFrames x channelCount` samples fit
    /// within `maximumSampleCapacity`, otherwise `.capacityExceedsCap` (its `samples` is `Int.max` if the product
    /// overflows). It allocates nothing, so the exact cap boundary is testable without a 256 MiB allocation.
    static func capacityRefusal(poolFrames: Int, channelCount: Int) -> MediaBlockPoolRefusal? {
        let (samples, overflow) = poolFrames.multipliedReportingOverflow(by: channelCount)
        guard !overflow, samples <= maximumSampleCapacity else {
            return .capacityExceedsCap(samples: overflow ? Int.max : samples, maximum: maximumSampleCapacity)
        }
        return nil
    }

    private init(plan: PrefetchPlan, channelCount: Int, maximumGeneration: UInt32) {
        let totalSamples = plan.poolFrames * channelCount
        // `allocate` has no throwing path (out of memory aborts the process) and `initialize` touches every page,
        // so the whole pool, up to 256 MiB, is committed right here at creation, never later on the render path.
        let memory = UnsafeMutablePointer<Float>.allocate(capacity: totalSamples)
        memory.initialize(repeating: 0, count: totalSamples)
        self.plan = plan
        self.channelCount = channelCount
        self.maximumGeneration = maximumGeneration
        self.samplesPerBlock = plan.blockFrames * channelCount
        self.sampleCapacity = totalSamples
        self.statistics = MediaBlockPoolStatistics(blockCount: plan.blockCount)
        self.storage = memory
        self.slots = Array(repeating: MediaBlockSlot(), count: plan.blockCount)
        self.freeStack = Array((0..<plan.blockCount).reversed())
        self.freeTop = plan.blockCount
    }

    deinit {
        storage.deallocate()
    }

    // MARK: - Lease and release

    /// Takes the next free block. It starts with `usedFrames == 0`. Refused with `.poolExhausted` when every block is
    /// leased or retired (the pool never grows), and with `.accessInProgress` while a `withSamples` body runs. A
    /// refused lease adds one to `leasesRefusedExhausted` or `leasesRefusedBusy` respectively and changes nothing else.
    func lease() throws(MediaBlockPoolRefusal) -> MediaBlockLease {
        guard readerDepth == 0 else {
            statistics.recordLeaseRefusedBusy()
            throw .accessInProgress
        }
        guard freeTop > 0 else {
            statistics.recordLeaseRefusedExhausted()
            throw .poolExhausted(leased: statistics.leasedCount, retired: statistics.retiredCount)
        }
        freeTop -= 1
        let slot = freeStack[freeTop]
        slots[slot].isLeased = true
        slots[slot].usedFrames = 0
        statistics.recordLease()
        return MediaBlockLease(identity: identity, slot: slot, generation: slots[slot].generation)
    }

    /// Returns a leased block, or retires it when its slot generation has reached `maximumGeneration`. Either way
    /// the lease (and every copy of it) is dead afterwards. Refused when the lease is foreign, already released or
    /// stale, and with `.accessInProgress` while a `withSamples` body runs; a refusal changes nothing.
    @discardableResult
    func release(_ lease: MediaBlockLease) throws(MediaBlockPoolRefusal) -> MediaBlockReleaseOutcome {
        guard readerDepth == 0 else { throw .accessInProgress }
        let slot = try validate(lease)
        slots[slot].isLeased = false
        guard lease.generation < maximumGeneration else {
            statistics.recordRelease(retired: true)
            return .retired
        }
        // Cannot overflow: the guard above keeps the generation strictly below `maximumGeneration <= UInt32.max`.
        slots[slot].generation = lease.generation + 1
        freeStack[freeTop] = slot
        freeTop += 1
        statistics.recordRelease(retired: false)
        return .returned
    }

    // MARK: - Capture copy

    /// The explicit, bounded capture copy: copies `frames` interleaved frames of `channels` channels from `source`
    /// into the leased block, replacing the block's visible content (it never appends) and setting `usedFrames`.
    ///
    /// `source` must hold exactly `frames x channels` samples, `channels` must equal `channelCount`, and `frames`
    /// must lie in `0...plan.blockFrames`; oversize input is refused, never truncated, and a refused copy writes
    /// nothing. Check order: `.accessInProgress`, lease validity, then channels, frames, source length. A copy
    /// refused for its shape adds one to `copiesRefused` and changes nothing else.
    ///
    /// A buffer without a base address holds no samples, whatever its `count` claims, so its length is taken as 0:
    /// with `frames > 0` the copy is refused as `.sourceLengthMismatch(expected: frames x channels, found: 0)`, and
    /// with `frames == 0` it is accepted and copies nothing. (Only an optimized build can construct such a buffer
    /// with a non-zero `count`; a debug build traps in the standard library when the buffer is built.)
    func copyIn(
        _ source: UnsafeBufferPointer<Float>,
        frames: Int,
        channels: Int,
        into lease: MediaBlockLease
    ) throws(MediaBlockPoolRefusal) {
        guard readerDepth == 0 else { throw .accessInProgress }
        let slot = try validate(lease)
        // A buffer without a base address has no samples to copy, whatever its count claims.
        let sourceCount = source.baseAddress == nil ? 0 : source.count
        if let refusal = shapeRefusal(sourceCount: sourceCount, frames: frames, channels: channels) {
            statistics.recordRefusedCopy()
            throw refusal
        }
        // Unwrap only; a missing base address can get past the checks above solely for a zero-frame copy.
        if let base = source.baseAddress {
            blockStart(of: slot).update(from: base, count: frames * channels)
        }
        slots[slot].usedFrames = frames
        statistics.recordCopy(frames: frames)
    }

    // MARK: - Reading

    /// Calls `body` with a read-only view of the first `usedFrames x channelCount` samples of the leased block.
    /// The view is valid only inside `body` and must not escape. While `body` runs the pool refuses `lease`,
    /// `release` and `copyIn` with `.accessInProgress`, so the viewed block cannot change; reads may nest.
    /// If the lease is refused, `body` never runs.
    func withSamples<Output>(
        of lease: MediaBlockLease,
        _ body: (UnsafeBufferPointer<Float>) -> Output
    ) throws(MediaBlockPoolRefusal) -> Output {
        let slot = try validate(lease)
        let view = UnsafeBufferPointer(
            start: UnsafePointer(blockStart(of: slot)),
            count: slots[slot].usedFrames * channelCount
        )
        readerDepth += 1
        defer { readerDepth -= 1 }
        return body(view)
    }

    /// The block's visible samples as a new array. Allocates; intended for tests and diagnostics, not for I/O paths.
    func copyOut(of lease: MediaBlockLease) throws(MediaBlockPoolRefusal) -> [Float] {
        try withSamples(of: lease) { Array($0) }
    }

    /// The frames stored in the leased block: `0` after `lease`, then the last accepted copy's `frames`.
    func usedFrames(of lease: MediaBlockLease) throws(MediaBlockPoolRefusal) -> Int {
        let slot = try validate(lease)
        return slots[slot].usedFrames
    }

    /// The free slots in the exact order the next leases will receive them. Allocates; for tests and diagnostics.
    func freeSlotsInLeaseOrder() -> [Int] {
        Array(freeStack[0..<freeTop].reversed())
    }

    // MARK: - Validation

    private func blockStart(of slot: Int) -> UnsafeMutablePointer<Float> {
        storage + slot * samplesPerBlock
    }

    private func shapeRefusal(sourceCount: Int, frames: Int, channels: Int) -> MediaBlockPoolRefusal? {
        guard channels == channelCount else {
            return .channelCountMismatch(expected: channelCount, found: channels)
        }
        guard (0...plan.blockFrames).contains(frames) else {
            return .framesOutOfRange(frames: frames, blockFrames: plan.blockFrames)
        }
        guard sourceCount == frames * channels else {
            return .sourceLengthMismatch(expected: frames * channels, found: sourceCount)
        }
        return nil
    }

    /// The lease's slot when the lease is valid: issued by this pool, its block leased, and the generations equal.
    private func validate(_ lease: MediaBlockLease) throws(MediaBlockPoolRefusal) -> Int {
        guard lease.wasIssued(by: identity) else { throw .foreignLease }
        let slot = lease.slot
        let current = slots[slot]
        guard current.isLeased else { throw .leaseAlreadyReleased(slot: slot) }
        guard current.generation == lease.generation else {
            throw .staleLease(
                slot: slot,
                leaseGeneration: lease.generation,
                currentGeneration: current.generation
            )
        }
        return slot
    }
}
