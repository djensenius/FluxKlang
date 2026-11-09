import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// Shared helpers of the capture write drain pump tests (#109 WDP1). No test lives here.
extension CaptureDrainStep {
    var issuedTicket: CaptureDrainTicket? {
        if case .write(let ticket) = self { return ticket }
        return nil
    }
}

extension CaptureDrainOutcome {
    var writtenBlock: CaptureDrainBlock? {
        if case .blockWritten(let block) = self { return block }
        return nil
    }
}

/// Distinct leases of one real pool (64 frames, one channel); a lease is only an identity here.
func drainLeases(_ count: Int = 8) throws -> [MediaBlockLease] {
    let plan = try PrefetchPlan.make(blockFrames: 64, blockCount: max(count, 2), headFrames: 64)
    let pool = try MediaBlockPool.make(plan: plan, channelCount: 1)
    var leases: [MediaBlockLease] = []
    for _ in 0..<count { leases.append(try pool.lease()) }
    return leases
}

func drainRefusal<Value>(_ body: () throws -> Value) -> CaptureDrainRefusal? {
    do {
        _ = try body()
        return nil
    } catch {
        return error as? CaptureDrainRefusal
    }
}

/// Runs `body`; it must throw `expected`, and the WHOLE pump must equal its saved copy afterwards.
func expectDrainRefused(
    _ pump: inout CaptureDrainPump,
    _ expected: CaptureDrainRefusal,
    sourceLocation: SourceLocation = #_sourceLocation,
    _ body: (inout CaptureDrainPump) throws -> Void
) {
    let before = pump
    var caught: CaptureDrainRefusal?
    do {
        try body(&pump)
    } catch {
        caught = error as? CaptureDrainRefusal
    }
    #expect(caught == expected, sourceLocation: sourceLocation)
    #expect(pump == before, sourceLocation: sourceLocation)
}

func drainIssue(_ pump: inout CaptureDrainPump) throws -> CaptureDrainTicket {
    let step = try pump.nextWrite()
    return try #require(step.issuedTicket)
}

func drainExpect(
    _ ticket: CaptureDrainTicket,
    id: UInt64,
    lease: MediaBlockLease,
    start: Int64,
    frames: Int,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    #expect(ticket.id == id, sourceLocation: sourceLocation)
    #expect(ticket.request.lease == lease, sourceLocation: sourceLocation)
    #expect(ticket.request.startFrame == start, sourceLocation: sourceLocation)
    #expect(ticket.request.frames == frames, sourceLocation: sourceLocation)
}

func expectBalanced(_ pump: CaptureDrainPump, sourceLocation: SourceLocation = #_sourceLocation) {
    let span = pump.streamEnd - pump.startFrame
    let spent = pump.acceptedFrames + pump.unwrittenFrames + pump.paddedFrames + pump.reclaimedFrames
    #expect(span == spent, sourceLocation: sourceLocation)
}

/// Golden step 1: bound 3, start 100, blocks of 10, 20 and 5 frames queued.
func drainGoldenQueued(_ leases: [MediaBlockLease]) throws -> CaptureDrainPump {
    var pump = try CaptureDrainPump.make(startFrame: 100, pendingBound: 3)
    let first = try pump.enqueue(lease: leases[0], frames: 10)
    #expect(first == .queued(pending: 1))
    let second = try pump.enqueue(lease: leases[1], frames: 20)
    #expect(second == .queued(pending: 2))
    let third = try pump.enqueue(lease: leases[2], frames: 5)
    #expect(third == .queued(pending: 3))
    return pump
}

/// Golden step 2: the fourth block padded, then a recorder-reported drop of 4 frames.
func drainGoldenPadded(_ leases: [MediaBlockLease]) throws -> CaptureDrainPump {
    var pump = try drainGoldenQueued(leases)
    _ = try pump.enqueue(lease: leases[3], frames: 7)
    _ = try pump.pad(frames: 4)
    return pump
}

/// Golden step 3: the first block written in two accepts (6, then 4).
func drainGoldenWritten(_ leases: [MediaBlockLease]) throws -> CaptureDrainPump {
    var pump = try drainGoldenPadded(leases)
    let first = try drainIssue(&pump)
    _ = try pump.receive(first.id, .accepted(frames: 6))
    let second = try drainIssue(&pump)
    _ = try pump.receive(second.id, .accepted(frames: 4))
    return pump
}

/// Golden step 4: the second block fails four times in a row and the fault latches.
func drainGoldenLatched(_ leases: [MediaBlockLease]) throws -> CaptureDrainPump {
    var pump = try drainGoldenWritten(leases)
    let faults: [MediaWriteFault] = [.ioFailure, .interrupted, .ioFailure, .ioFailure]
    for fault in faults {
        let ticket = try drainIssue(&pump)
        _ = try pump.fail(ticket.id, fault)
    }
    return pump
}

/// Real stereo pool blocks (round 2): block `b` holds `frameCounts[b]` frames whose interleaved samples count up
/// from 1 across all blocks, so every sample value is distinct. `samples[b]` is the original content of block `b`.
struct DrainStereoFixture {
    let pool: MediaBlockPool
    let leases: [MediaBlockLease]
    let samples: [[Float]]
}

func drainStereoBlocks(frameCounts: [Int]) throws -> DrainStereoFixture {
    let plan = try PrefetchPlan.make(blockFrames: 64, blockCount: max(frameCounts.count, 2), headFrames: 64)
    let pool = try MediaBlockPool.make(plan: plan, channelCount: 2)
    var leases: [MediaBlockLease] = []
    var samples: [[Float]] = []
    var next: Float = 1
    for frames in frameCounts {
        var block: [Float] = []
        for _ in 0..<(frames * 2) {
            block.append(next)
            next += 1
        }
        let lease = try pool.lease()
        try block.withUnsafeBufferPointer { (view: UnsafeBufferPointer<Float>) throws(MediaBlockPoolRefusal) in
            try pool.copyIn(view, frames: frames, channels: 2, into: lease)
        }
        leases.append(lease)
        samples.append(block)
    }
    return DrainStereoFixture(pool: pool, leases: leases, samples: samples)
}

/// What a writer would take from the pool when it accepts `accepted` frames of `request`: block frames
/// `blockOffset ..< blockOffset + accepted`, converted to interleaved sample indexes (two channels). It records a
/// test failure and throws instead of trapping when the range does not fit the block's used samples.
func drainWrittenSamples(_ pool: MediaBlockPool, _ request: MediaWriteRequest, accepted: Int) throws -> [Float] {
    let first = request.blockOffset * 2
    let last = first + accepted * 2
    let usedSamples = try pool.withSamples(of: request.lease) { (view: UnsafeBufferPointer<Float>) -> Int in
        view.count
    }
    let zero = 0
    try #require(accepted >= zero)
    try #require(last <= usedSamples)
    let range = first..<last
    return try pool.withSamples(of: request.lease) { (view: UnsafeBufferPointer<Float>) -> [Float] in
        Array(view[range])
    }
}

/// The refusal a write request factory produced for these arguments, or nil when it was accepted.
func drainRequestRefusal(
    _ lease: MediaBlockLease,
    startFrame: Int64 = 0,
    frames: Int,
    blockOffset: Int
) -> MediaIORequestRefusal? {
    do throws(MediaIORequestRefusal) {
        _ = try MediaWriteRequest.make(lease: lease, startFrame: startFrame, frames: frames, blockOffset: blockOffset)
        return nil
    } catch {
        return error
    }
}
