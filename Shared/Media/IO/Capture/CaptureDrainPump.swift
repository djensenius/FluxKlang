//
//  CaptureDrainPump.swift
//  FluxKlang
//
//  The writer-side twin of `PrefetchFillPump` (#109 WDP1, media-contract.md
//  §8.3): a pure value that decides what a capture writer is asked next. It
//  opens no file, calls no worker, leases or releases nothing and reads no
//  time. Storage and every mutation live in this file (a `private(set)`
//  property is writable only here); the non-mutating checks are in
//  `CaptureDrainPump+Write.swift`. Every mutating method validates first and
//  assigns after its last throw, so a refusal leaves the pump `==`-identical.
//  No method copies the pump: the ring holds up to 1_024 slots.
//

/// One captured block waiting for the writer. Only the pump builds it.
struct CaptureDrainBlock: Equatable, Sendable {
    let lease: MediaBlockLease
    let startFrame: Int64
    let frames: Int

    fileprivate init(lease: MediaBlockLease, startFrame: Int64, frames: Int) {
        self.lease = lease
        self.startFrame = startFrame
        self.frames = frames
    }
}

/// One write handed to the worker: `id` in issue order, `request` the remainder of the head block.
struct CaptureDrainTicket: Equatable, Sendable {
    let id: UInt64
    let request: MediaWriteRequest

    fileprivate init(id: UInt64, request: MediaWriteRequest) {
        self.id = id
        self.request = request
    }
}

/// A bounded queue of captured blocks drained to one writer, one ticket at a time. One pump is one file and one
/// segment run: a restart or a new take is a new pump.
struct CaptureDrainPump: Equatable, Sendable {
    let startFrame: Int64
    let pendingBound: Int
    private(set) var state: CaptureDrainState = .running
    /// The start frame of the next block: `startFrame` plus every queued, padded and written frame.
    private(set) var streamEnd: Int64
    private(set) var pendingBlocks = 0
    private(set) var acceptedFrames: Int64 = 0
    private(set) var unwrittenFrames: Int64 = 0
    private(set) var paddedFrames: Int64 = 0
    private(set) var reclaimedFrames: Int64 = 0
    private(set) var inFlight: CaptureDrainTicket?
    private(set) var counters = CaptureDrainCounters()
    private(set) var latchedFault: MediaWriteFault?
    private(set) var ring: [CaptureDrainBlock?]
    private(set) var headIndex = 0
    private(set) var headWritten = 0
    private(set) var held: Set<MediaBlockLease> = []
    private(set) var consecutiveFailures = 0
    private(set) var pendingPolls: UInt64 = 0
    private(set) var lastTicketID: UInt64 = 0

    private init(startFrame: Int64, pendingBound: Int) {
        self.startFrame = startFrame
        self.pendingBound = pendingBound
        streamEnd = startFrame
        ring = Array(repeating: nil, count: pendingBound)
        held.reserveCapacity(pendingBound)
    }

    /// Refuses, first failure wins: a bound outside `1...1_024` (before any allocation), a negative start frame.
    static func make(startFrame: Int64, pendingBound: Int) throws(CaptureDrainRefusal) -> CaptureDrainPump {
        let maximum = CaptureDrainLimits.maximumPendingBlocks
        guard (1...maximum).contains(pendingBound) else {
            throw .pendingBoundOutOfRange(bound: pendingBound, maximum: maximum)
        }
        guard startFrame >= 0 else { throw .request(.negativeStartFrame(startFrame)) }
        return CaptureDrainPump(startFrame: startFrame, pendingBound: pendingBound)
    }

    // MARK: Recorder side

    /// Takes one captured block. Never blocks: a stopped pump hands the lease back, a full queue pads the NEWEST
    /// block (queued frames are real audio) and hands its lease back.
    mutating func enqueue(lease: MediaBlockLease, frames: Int) throws(CaptureDrainRefusal) -> CaptureDrainEnqueue {
        try checkEnqueue(lease: lease, frames: frames)
        if case .stopped(let fault) = state {
            counters.noteAfterStop(frames: frames)
            return .stopped(reason: MediaIOFaultMapping.captureStopReason(for: fault), returning: lease)
        }
        let interval = CaptureDrainOverflow(startFrame: streamEnd, frames: frames)
        if pendingBlocks == pendingBound {
            streamEnd += Int64(frames)
            paddedFrames += Int64(frames)
            counters.noteBackpressure()
            return .padded(interval, returning: lease)
        }
        ring[(headIndex + pendingBlocks) % pendingBound] =
            CaptureDrainBlock(lease: lease, startFrame: streamEnd, frames: frames)
        held.insert(lease)
        streamEnd += Int64(frames)
        unwrittenFrames += Int64(frames)
        pendingBlocks += 1
        counters.noteQueued()
        return .queued(pending: pendingBlocks)
    }

    /// The recorder says its own handoff dropped `frames`; the pump only records the interval.
    mutating func pad(frames: Int) throws(CaptureDrainRefusal) -> CaptureDrainPadResult {
        try checkPad(frames: frames)
        if case .stopped(let fault) = state {
            counters.noteAfterStop(frames: frames)
            return .stopped(reason: MediaIOFaultMapping.captureStopReason(for: fault))
        }
        let interval = CaptureDrainOverflow(startFrame: streamEnd, frames: frames)
        streamEnd += Int64(frames)
        paddedFrames += Int64(frames)
        return .padded(interval)
    }

    // MARK: Writer side

    /// Issues one ticket for the remainder of the head block, or says why not.
    mutating func nextWrite() throws(CaptureDrainRefusal) -> CaptureDrainStep {
        if let reason = idleReason { return .idle(reason) }
        guard let block = ring[headIndex] else { return .idle(.empty) }
        guard lastTicketID < UInt64.max else { throw .ticketCounterOverflow }
        let request = try makeRequest(for: block)
        lastTicketID += 1
        let ticket = CaptureDrainTicket(id: lastTicketID, request: request)
        inFlight = ticket
        counters.noteIssued()
        return .write(ticket)
    }

    /// A poll of the ticket in flight. `pending` never fails or latches.
    mutating func receive(_ id: UInt64, _ poll: MediaWritePoll) throws(CaptureDrainRefusal) -> CaptureDrainOutcome {
        let target = try checkInFlight(id)
        switch poll {
        case .pending:
            pendingPolls = PrefetchFillCounters.saturatingSum(pendingPolls, 1)
            counters.noteSlowPoll()
            return .stillPending(polls: pendingPolls)
        case .accepted(let frames):
            try checkAccepted(frames, for: target.ticket)
            return applyAccept(frames, to: target)
        }
    }

    /// A fault of the ticket in flight: terminal faults latch at once, the others are retried up to three times in
    /// a row, the next one latches.
    mutating func fail(_ id: UInt64, _ fault: MediaWriteFault) throws(CaptureDrainRefusal) -> CaptureDrainOutcome {
        _ = try checkInFlight(id)
        if Self.isTerminal(fault) || consecutiveFailures >= CaptureDrainLimits.maximumRetries {
            return latch(fault)
        }
        consecutiveFailures += 1
        inFlight = nil
        pendingPolls = 0
        counters.noteRetry()
        return .retryScheduled(attempt: consecutiveFailures)
    }

    /// The head block of a stopped or finished pump, or nil; the caller releases its lease. Its unwritten frames
    /// move to `reclaimedFrames`. A reclaim after `finish` leaves the summary that `finish` returned stale: it is a
    /// value snapshot taken at the seal.
    mutating func reclaim() throws(CaptureDrainRefusal) -> CaptureDrainBlock? {
        if case .running = state { throw .notStopped }
        guard let block = ring[headIndex] else { return nil }
        let remainder = Int64(block.frames - headWritten)
        unwrittenFrames -= remainder
        reclaimedFrames += remainder
        counters.noteReclaimed()
        popHead(block)
        return block
    }

    // MARK: Sealing

    /// Seals the run with the worker's result. A partial file is a result, not a refusal.
    mutating func finish(_ result: MediaWriteFinish) throws(CaptureDrainRefusal) -> CaptureDrainSummary {
        try checkFinish()
        guard result.acceptedFrames == acceptedFrames else {
            throw .acceptedMismatch(worker: result.acceptedFrames, pump: acceptedFrames)
        }
        state = .finished
        return makeSummary(sealing: .sealed(durableFrames: result.durableFrames), stopReason: latchedReason)
    }

    /// Seals the run after the worker's `finish` threw `fault`.
    mutating func finishFailed(_ fault: MediaWriteFault) throws(CaptureDrainRefusal) -> CaptureDrainSummary {
        try checkFinish()
        state = .finished
        let reason = latchedReason ?? MediaIOFaultMapping.captureStopReason(for: fault)
        return makeSummary(sealing: .sealFailed(fault), stopReason: reason)
    }

    // MARK: Steps (no throw after the first assignment)

    private mutating func applyAccept(_ frames: Int, to target: CaptureDrainInFlight) -> CaptureDrainOutcome {
        acceptedFrames += Int64(frames)
        unwrittenFrames -= Int64(frames)
        consecutiveFailures = 0
        pendingPolls = 0
        inFlight = nil
        let remaining = target.ticket.request.frames - frames
        guard remaining == 0 else {
            headWritten += frames
            counters.noteShortAccept()
            return .partial(accepted: frames, remaining: remaining)
        }
        counters.noteWritten()
        popHead(target.block)
        return .blockWritten(target.block)
    }

    private mutating func latch(_ fault: MediaWriteFault) -> CaptureDrainOutcome {
        state = .stopped(fault)
        latchedFault = fault
        inFlight = nil
        counters.noteLatched()
        return .captureStopped(reason: MediaIOFaultMapping.captureStopReason(for: fault), fault: fault)
    }

    private mutating func popHead(_ block: CaptureDrainBlock) {
        ring[headIndex] = nil
        headIndex = (headIndex + 1) % pendingBound
        pendingBlocks -= 1
        headWritten = 0
        held.remove(block.lease)
    }

    private static func isTerminal(_ fault: MediaWriteFault) -> Bool {
        switch fault {
        case .diskFull, .unavailable: true
        case .ioFailure, .interrupted: false
        }
    }
}
