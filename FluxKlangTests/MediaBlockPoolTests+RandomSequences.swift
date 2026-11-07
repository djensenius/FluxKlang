import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// Seeded random walks over the media block pool's public operations, checked step by step against an independent
/// reference model. A failure names its seed and step, and every walk is exactly reproducible.
extension MediaBlockPoolTests {
    @Test
    func statisticsAndFreeOrderMatchAReferenceModelAcrossSeededRandomSequences() throws {
        // (seed, generation limit): a limit of 1 retires blocks almost at once, a large one almost never.
        let walks: [(seed: UInt64, limit: Int)] = [(1, 1), (7, 3), (42, 60), (20_260_101, 100)]
        var seen = Set<String>()
        for (seed, limit) in walks {
            var run = try MediaBlockPoolRandomRun(seed: seed, maximumGeneration: limit)
            for index in 0..<300 {
                let outcome = run.step()
                let statesMatch = run.poolState() == run.modelState()
                #expect(outcome.pool == outcome.model, "seed \(seed) step \(index)")
                #expect(statesMatch, "seed \(seed) step \(index)")
                if outcome.pool != outcome.model || !statesMatch {
                    break
                }
            }
            seen.formUnion(run.trace)
        }
        // The walks must actually have produced every outcome, or agreeing with the model would prove little.
        let requiredKinds = [
            "leased", "returned", "retired", "copied", "read", "refused poolExhausted",
            "refused leaseAlreadyReleased", "refused staleLease", "refused framesOutOfRange",
            "refused channelCountMismatch", "refused sourceLengthMismatch"
        ]
        for kind in requiredKinds {
            #expect(seen.contains(kind), "no step produced \(kind)")
        }
    }

    @Test
    func seededRandomSequencesAreDeterministic() throws {
        var first = try MediaBlockPoolRandomRun(seed: 99, maximumGeneration: 3)
        var second = try MediaBlockPoolRandomRun(seed: 99, maximumGeneration: 3)
        var other = try MediaBlockPoolRandomRun(seed: 100, maximumGeneration: 3)
        for _ in 0..<200 {
            _ = first.step()
            _ = second.step()
            _ = other.step()
        }
        #expect(first.trace.count == 200)
        #expect(first.trace == second.trace)
        #expect(first.poolState() == second.poolState())
        #expect(first.trace != other.trace)
    }

    @Test
    func randomSequenceGeneratorUsesTheHighBitsOfAKnownLCG() {
        var generator = MediaBlockPoolLCG(seed: 1)
        let drawn = (0..<8).map { _ in generator.next(below: 1_000_000) }
        #expect(drawn == [834_774, 944_153, 341_196, 192_870, 211_034, 839_795, 567_130, 486_902])
        var other = MediaBlockPoolLCG(seed: 20_260_101)
        let small = (0..<12).map { _ in other.next(below: 10) }
        #expect(small == [0, 1, 3, 0, 7, 4, 0, 1, 9, 8, 1, 8])
    }

    // MARK: - The walk's building blocks (private, nested in the suite)

    /// A 64-bit linear congruential generator (Knuth's MMIX constants), read from its high bits.
    private struct MediaBlockPoolLCG {
        private var state: UInt64

        init(seed: UInt64) {
            state = seed
        }

        /// A value in `0..<bound` for a positive `bound`.
        mutating func next(below bound: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 33) % UInt64(bound))
        }
    }

    /// What one step did, or why it was refused.
    private enum MediaBlockPoolStepEvent: Equatable {
        case leased(slot: Int, generation: UInt32)
        case released(slot: Int, retired: Bool)
        case copied(slot: Int, frames: Int)
        case read(slot: Int, samples: [Float])
        case refused(MediaBlockPoolRefusal)

        /// A short label without payload: the event's case and, for a refusal, the refusal's case.
        var kind: String {
            switch self {
            case .leased: "leased"
            case .released(_, let retired): retired ? "retired" : "returned"
            case .copied: "copied"
            case .read: "read"
            case .refused(let refusal): "refused " + String(String(describing: refusal).prefix { $0 != "(" })
            }
        }
    }

    /// The same step as seen by the pool and by the model.
    private struct MediaBlockPoolStepOutcome {
        let pool: MediaBlockPoolStepEvent
        let model: MediaBlockPoolStepEvent
    }

    /// Everything observable about the block counts and the lease order.
    private struct MediaBlockPoolRunState: Equatable {
        /// `[leased, free, retired, high-water, frames copied, copies completed, copies refused]`.
        let counts: [Int]
        let freeOrder: [Int]
    }

    /// One capture copy to attempt: the source samples are exactly one block long at most, whatever the shape
    /// claimed.
    private struct MediaBlockPoolCopyRequest {
        let lease: MediaBlockLease
        let samples: [Float]
        let frames: Int
        let channels: Int
    }

    /// An independent model of the pool: plain arrays and the documented rules, none of the pool's data structures.
    private struct MediaBlockPoolModel {
        private let blockFrames: Int
        private let poolChannels: Int
        private let maximumGeneration: Int
        private var leased: [Bool]
        private var retired: [Bool]
        private var generation: [Int]
        private var content: [[Float]]
        /// The free blocks, the one the next lease receives first.
        private var freeOrder: [Int]
        private var highWater = 0
        private var framesCopied = 0
        private var copiesCompleted = 0
        private var copiesRefused = 0

        init(blockCount: Int, blockFrames: Int, poolChannels: Int, maximumGeneration: Int) {
            self.blockFrames = blockFrames
            self.poolChannels = poolChannels
            self.maximumGeneration = maximumGeneration
            leased = Array(repeating: false, count: blockCount)
            retired = Array(repeating: false, count: blockCount)
            generation = Array(repeating: 0, count: blockCount)
            content = Array(repeating: [], count: blockCount)
            freeOrder = Array(0..<blockCount)
        }

        private var leasedCount: Int { leased.filter { $0 }.count }
        private var retiredCount: Int { retired.filter { $0 }.count }

        func isLive(_ lease: MediaBlockLease) -> Bool {
            leased[lease.slot] && generation[lease.slot] == Int(lease.generation)
        }

        mutating func lease() -> MediaBlockPoolStepEvent {
            guard !freeOrder.isEmpty else {
                return .refused(.poolExhausted(leased: leasedCount, retired: retiredCount))
            }
            let slot = freeOrder.removeFirst()
            leased[slot] = true
            content[slot] = []
            highWater = max(highWater, leasedCount)
            return .leased(slot: slot, generation: UInt32(generation[slot]))
        }

        mutating func release(_ lease: MediaBlockLease) -> MediaBlockPoolStepEvent {
            if let refusal = leaseRefusal(lease) {
                return .refused(refusal)
            }
            let slot = lease.slot
            leased[slot] = false
            content[slot] = []
            guard generation[slot] < maximumGeneration else {
                retired[slot] = true
                return .released(slot: slot, retired: true)
            }
            generation[slot] += 1
            freeOrder.insert(slot, at: 0)
            return .released(slot: slot, retired: false)
        }

        mutating func copyIn(_ request: MediaBlockPoolCopyRequest) -> MediaBlockPoolStepEvent {
            if let refusal = leaseRefusal(request.lease) {
                return .refused(refusal)
            }
            if let refusal = shapeRefusal(request) {
                copiesRefused += 1
                return .refused(refusal)
            }
            content[request.lease.slot] = request.samples
            framesCopied += request.frames
            copiesCompleted += 1
            return .copied(slot: request.lease.slot, frames: request.frames)
        }

        func read(_ lease: MediaBlockLease) -> MediaBlockPoolStepEvent {
            if let refusal = leaseRefusal(lease) {
                return .refused(refusal)
            }
            return .read(slot: lease.slot, samples: content[lease.slot])
        }

        func state() -> MediaBlockPoolRunState {
            MediaBlockPoolRunState(
                counts: [
                    leasedCount, freeOrder.count, retiredCount, highWater,
                    framesCopied, copiesCompleted, copiesRefused
                ],
                freeOrder: freeOrder
            )
        }

        private func leaseRefusal(_ lease: MediaBlockLease) -> MediaBlockPoolRefusal? {
            let slot = lease.slot
            guard leased[slot] else {
                return .leaseAlreadyReleased(slot: slot)
            }
            guard generation[slot] == Int(lease.generation) else {
                return .staleLease(
                    slot: slot,
                    leaseGeneration: lease.generation,
                    currentGeneration: UInt32(generation[slot])
                )
            }
            return nil
        }

        private func shapeRefusal(_ request: MediaBlockPoolCopyRequest) -> MediaBlockPoolRefusal? {
            let expected = request.frames * request.channels
            if request.channels != poolChannels {
                return .channelCountMismatch(expected: poolChannels, found: request.channels)
            }
            if request.frames < 0 || request.frames > blockFrames {
                return .framesOutOfRange(frames: request.frames, blockFrames: blockFrames)
            }
            if request.samples.count != expected {
                return .sourceLengthMismatch(expected: expected, found: request.samples.count)
            }
            return nil
        }
    }

    /// A pool of five two-channel blocks of 64 frames, a model of it, and a seeded generator choosing the operations.
    private struct MediaBlockPoolRandomRun {
        private let pool: MediaBlockPool
        private var model: MediaBlockPoolModel
        private var generator: MediaBlockPoolLCG
        private var issued: [MediaBlockLease] = []
        private(set) var trace: [String] = []

        init(seed: UInt64, maximumGeneration: Int) throws {
            pool = try MediaBlockPoolTests.makePool(blockCount: 5, channels: 2, maximumGeneration: maximumGeneration)
            model = MediaBlockPoolModel(
                blockCount: 5, blockFrames: 64, poolChannels: 2, maximumGeneration: maximumGeneration
            )
            generator = MediaBlockPoolLCG(seed: seed)
        }

        func poolState() -> MediaBlockPoolRunState {
            let stats = pool.statistics
            return MediaBlockPoolRunState(
                counts: [
                    stats.leasedCount, stats.freeCount, stats.retiredCount, stats.highWaterLeased,
                    Int(clamping: stats.framesCopied), Int(clamping: stats.copiesCompleted),
                    Int(clamping: stats.copiesRefused)
                ],
                freeOrder: pool.freeSlotsInLeaseOrder()
            )
        }

        func modelState() -> MediaBlockPoolRunState {
            model.state()
        }

        /// One random operation (30% lease, 20% release, 30% copy, 20% read), applied to the pool and to the model.
        mutating func step() -> MediaBlockPoolStepOutcome {
            let outcome: MediaBlockPoolStepOutcome
            switch generator.next(below: 10) {
            case 0...2: outcome = stepLease()
            case 3...4: outcome = stepRelease()
            case 5...7: outcome = stepCopy()
            default: outcome = stepRead()
            }
            trace.append(outcome.model.kind)
            return outcome
        }

        private mutating func stepLease() -> MediaBlockPoolStepOutcome {
            let modelEvent = model.lease()
            let poolEvent: MediaBlockPoolStepEvent
            do {
                let lease = try pool.lease()
                issued.append(lease)
                poolEvent = .leased(slot: lease.slot, generation: lease.generation)
            } catch {
                poolEvent = Self.refusedEvent(error)
            }
            return MediaBlockPoolStepOutcome(pool: poolEvent, model: modelEvent)
        }

        private mutating func stepRelease() -> MediaBlockPoolStepOutcome {
            guard let lease = pickLease() else { return stepLease() }
            let modelEvent = model.release(lease)
            let poolEvent: MediaBlockPoolStepEvent
            do {
                let outcome = try pool.release(lease)
                poolEvent = .released(slot: lease.slot, retired: outcome == .retired)
            } catch {
                poolEvent = Self.refusedEvent(error)
            }
            return MediaBlockPoolStepOutcome(pool: poolEvent, model: modelEvent)
        }

        private mutating func stepCopy() -> MediaBlockPoolStepOutcome {
            guard let lease = pickLease() else { return stepLease() }
            let request = makeCopyRequest(for: lease)
            let modelEvent = model.copyIn(request)
            let target = pool
            let poolEvent: MediaBlockPoolStepEvent
            do {
                try request.samples.withUnsafeBufferPointer { buffer in
                    try target.copyIn(buffer, frames: request.frames, channels: request.channels, into: lease)
                }
                poolEvent = .copied(slot: lease.slot, frames: request.frames)
            } catch {
                poolEvent = Self.refusedEvent(error)
            }
            return MediaBlockPoolStepOutcome(pool: poolEvent, model: modelEvent)
        }

        private mutating func stepRead() -> MediaBlockPoolStepOutcome {
            guard let lease = pickLease() else { return stepLease() }
            let modelEvent = model.read(lease)
            let poolEvent: MediaBlockPoolStepEvent
            do {
                let samples = try pool.copyOut(of: lease)
                poolEvent = .read(slot: lease.slot, samples: samples)
            } catch {
                poolEvent = Self.refusedEvent(error)
            }
            return MediaBlockPoolStepOutcome(pool: poolEvent, model: modelEvent)
        }

        /// Mostly a live lease, sometimes any lease ever issued (released, stale or retired ones included).
        private mutating func pickLease() -> MediaBlockLease? {
            guard !issued.isEmpty else { return nil }
            let preferLive = generator.next(below: 4) != 0
            let live = issued.filter { model.isLive($0) }
            let choices = preferLive && !live.isEmpty ? live : issued
            return choices[generator.next(below: choices.count)]
        }

        /// Mostly valid shapes, with the occasional wrong width, short source or oversize frame count. The source
        /// is one block of samples at most, so a copy that was wrongly accepted still could not run past the
        /// pool's storage.
        private mutating func makeCopyRequest(for lease: MediaBlockLease) -> MediaBlockPoolCopyRequest {
            let frameChoices = [0, 1, 7, 33, 64, 65]
            let frames = frameChoices[generator.next(below: frameChoices.count)]
            let channels = generator.next(below: 8) == 0 ? 3 : 2
            let shortBy = generator.next(below: 8) == 0 ? 1 : 0
            let count = min(max(frames * channels - shortBy, 0), 128)
            let first = Float(generator.next(below: 1_000))
            let samples = (0..<count).map { first + Float($0) }
            return MediaBlockPoolCopyRequest(lease: lease, samples: samples, frames: frames, channels: channels)
        }

        private static func refusedEvent(_ error: any Error) -> MediaBlockPoolStepEvent {
            guard let refusal = error as? MediaBlockPoolRefusal else {
                Issue.record("unexpected error \(error)")
                return .refused(.foreignLease)
            }
            return .refused(refusal)
        }
    }
}
