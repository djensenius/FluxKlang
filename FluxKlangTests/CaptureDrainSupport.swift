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
