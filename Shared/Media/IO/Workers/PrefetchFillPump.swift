//
//  PrefetchFillPump.swift
//  FluxKlang
//
//  The prefetch fill pump (#109 IO2, media-contract.md §8.2): pure
//  scheduling and bookkeeping that decides which block to read next, absorbs
//  short reads, bounded retries and stalls, and discards stale completions.
//  The caller advances it with injected values (the consumer position, the
//  count of resident blocks, a worker's poll result or fault); the pump owns
//  no pool, lease, playhead, worker, clock or collection. Time never exists
//  here: retries and stalls are COUNTED, and any real deadline belongs to the
//  later adapter that drives a real worker.
//

/// One issued read: the range, the generations it was stamped with and an id that completions must echo.
/// Only the pump can mint one (its initialiser is `fileprivate`).
struct PrefetchFillTicket: Equatable, Sendable {
    /// 1, 2, 3, ... in issue order.
    let id: UInt64
    let startFrame: Int64
    /// `1...plan.blockFrames`, clipped to the end of the source.
    let frames: Int
    let sourceGeneration: UInt64
    let readGeneration: UInt64

    fileprivate init(id: UInt64, startFrame: Int64, frames: Int, sourceGeneration: UInt64, readGeneration: UInt64) {
        self.id = id
        self.startFrame = startFrame
        self.frames = frames
        self.sourceGeneration = sourceGeneration
        self.readGeneration = readGeneration
    }

    /// The worker request for this ticket and the leased block that will hold the frames. Re-validated here.
    func readRequest(lease: MediaBlockLease) throws(MediaIORequestRefusal) -> MediaReadRequest {
        try MediaReadRequest.make(lease: lease, startFrame: startFrame, frames: frames,
                                  sourceGeneration: sourceGeneration, readGeneration: readGeneration)
    }
}

/// The fill pump of one source. Build it with `make`; every stored field is `private(set)` or `private`.
///
/// Deviations from a deeper pipeline, on purpose: exactly ONE read in flight (`MediaIOLimits.maximumInFlight`) so
/// completions arrive in order with no gaps, and ONE remembered abandoned ticket id (a new abandonment overwrites
/// it, so a completion of an older abandoned ticket is `unknownTicket`).
///
/// Every `mutating` method validates all inputs first and assigns the new state only on success, so a thrown
/// `PrefetchFillRefusal` leaves the pump `==`-identical to its state before the call.
struct PrefetchFillPump: Equatable, Sendable {
    private(set) var plan: PrefetchPlan
    private(set) var sourceFrames: Int64
    private(set) var state: PrefetchFillState
    /// The next source frame the pump will read; never above `sourceFrames`.
    private(set) var nextFrame: Int64
    private(set) var sourceGeneration: UInt64
    private(set) var readGeneration: UInt64
    private(set) var inFlight: PrefetchFillTicket?
    /// The block being assembled from nonterminal short reads, or nil. Dropped by `locate` and `resume`.
    private(set) var partialBlock: PrefetchFillPartialBlock?
    private(set) var counters: PrefetchFillCounters

    private var consecutiveFailures: Int
    private var pendingPolls: Int
    private var lastTicketID: UInt64
    private var abandonedTicketID: UInt64?
    private var restoring: Bool

    private init(validatedPlan plan: PrefetchPlan, sourceFrames: Int64, sourceGeneration: UInt64,
                 readGeneration: UInt64, position: Int64) {
        self.plan = plan
        self.sourceFrames = sourceFrames
        self.sourceGeneration = sourceGeneration
        self.readGeneration = readGeneration
        state = .idle
        nextFrame = position
        inFlight = nil
        partialBlock = nil
        counters = PrefetchFillCounters()
        consecutiveFailures = 0
        pendingPolls = 0
        lastTicketID = 0
        abandonedTicketID = nil
        restoring = false
    }

    /// Order of checks, first failure wins: `sourceFrames` at least 1, `sourceGeneration` at least 1, `position`
    /// not negative, `position` not above `sourceFrames` (`position == sourceFrames` is accepted: already at the end).
    static func make(plan: PrefetchPlan, sourceFrames: Int64, sourceGeneration: UInt64, readGeneration: UInt64,
                     position: Int64) throws(PrefetchFillRefusal) -> PrefetchFillPump {
        guard sourceFrames >= 1 else { throw .sourceFramesNotPositive(sourceFrames) }
        guard sourceGeneration >= 1 else { throw .sourceGenerationNotPositive }
        try checkPosition(position, sourceFrames: sourceFrames)
        return PrefetchFillPump(validatedPlan: plan, sourceFrames: sourceFrames, sourceGeneration: sourceGeneration,
                                readGeneration: readGeneration, position: position)
    }

    private static func checkPosition(_ position: Int64, sourceFrames: Int64) throws(PrefetchFillRefusal) {
        guard position >= 0 else { throw .negativePosition(position) }
        guard position <= sourceFrames else {
            throw .positionBeyondSource(position: position, sourceFrames: sourceFrames)
        }
    }

    // MARK: Issuing

    /// Decides the next read. Refusals first (position negative, beyond the source, `residentBlocks` outside
    /// `0...plan.blockCount`), then the first wait reason that holds: `failed`, `inFlight`, `ended`, `poolFull`
    /// (`residentBlocks >= blockCount`, skipped while a partial block exists: its block is already leased),
    /// `satisfied` (the head is covered by PUBLISHED frames: `published - position >= headFrames`, where `published`
    /// is the start of the partial block when one exists, else `start`; frames gathered in a partial block are not
    /// resident yet and never count).
    /// Otherwise it issues one ticket. `start` is `max(nextFrame, position)`: a consumer that ran ahead skips
    /// source frames, counted in `framesSkipped` (the playhead's silence-and-skip rule). While a partial block
    /// exists `start` is `nextFrame` (the block stays contiguous). If the consumer has meanwhile passed the partial
    /// block, filling still completes it and the playhead discards it (`discardedPassed`): wasteful but intended,
    /// because the next block then starts at the consumer. State `ended` also waits with `.ended`, so a source that
    /// ended early is never re-read until `locate`.
    mutating func nextRequest(position: Int64, residentBlocks: Int) throws(PrefetchFillRefusal) -> PrefetchFillStep {
        try Self.checkPosition(position, sourceFrames: sourceFrames)
        guard (0...plan.blockCount).contains(residentBlocks) else {
            throw .residentBlocksOutOfRange(count: residentBlocks, maximum: plan.blockCount)
        }
        var next = self
        let step = try next.decide(position: position, residentBlocks: residentBlocks)
        self = next
        return step
    }

    private mutating func decide(position: Int64,
                                 residentBlocks: Int) throws(PrefetchFillRefusal) -> PrefetchFillStep {
        if case .failed = state { return .wait(.failed) }
        if inFlight != nil { return .wait(.inFlight) }
        let start = partialBlock == nil ? max(nextFrame, position) : nextFrame
        if state == .ended || start >= sourceFrames {
            state = .ended
            return .wait(.ended)
        }
        if partialBlock == nil, residentBlocks >= plan.blockCount { return .wait(.poolFull) }
        let published = partialBlock?.startFrame ?? start
        if published - position >= Int64(plan.headFrames) { return .wait(.satisfied) }
        return .request(try issue(start: start))
    }

    /// `lastTicketID == UInt64.max` is refused, but no public sequence reaches it (2^64 tickets).
    /// The ticket covers the rest of the block being assembled (`blockFrames` minus the partial frames), clipped to
    /// the end of the source.
    private mutating func issue(start: Int64) throws(PrefetchFillRefusal) -> PrefetchFillTicket {
        guard lastTicketID < UInt64.max else { throw .ticketCounterOverflow }
        let room = Int64(plan.blockFrames - (partialBlock?.frames ?? 0))
        let frames = Int(min(room, sourceFrames - start))
        let ticket = PrefetchFillTicket(id: lastTicketID + 1, startFrame: start, frames: frames,
                                        sourceGeneration: sourceGeneration, readGeneration: readGeneration)
        counters.noteIssued(skipped: start - nextFrame)
        lastTicketID = ticket.id
        inFlight = ticket
        state = .awaitingCompletion
        nextFrame = start
        pendingPolls = 0
        return ticket
    }

    // MARK: Completing

    /// Applies a worker poll to the ticket `id`. Order of checks: the single remembered abandoned id is
    /// `.discardedStale` (payload never inspected); then an id that is not the ticket in flight is `.unknownTicket`;
    /// then `.ready` frames outside `0...ticket.frames` are refused with the ticket still in flight.
    /// Effects are in the doc comments of the private steps below.
    mutating func receive(_ id: UInt64, _ poll: MediaReadPoll) throws(PrefetchFillRefusal) -> PrefetchFillOutcome {
        var next = self
        let outcome = try next.complete(id, poll)
        self = next
        return outcome
    }

    /// Applies a worker fault to the ticket `id`; the same id checks as `receive`. `unavailable` latches at once;
    /// `ioFailure` and `interrupted` are retried up to `maximumConsecutiveRetries` in a row, the next one latches.
    mutating func fail(_ id: UInt64, _ fault: MediaReadFault) throws(PrefetchFillRefusal) -> PrefetchFillOutcome {
        var next = self
        let outcome = try next.completeFault(id, fault)
        self = next
        return outcome
    }

    private mutating func complete(_ id: UInt64, _ poll: MediaReadPoll) throws(PrefetchFillRefusal)
        -> PrefetchFillOutcome {
        if let stale = discardIfAbandoned(id) { return stale }
        let ticket = try ticketInFlight(id)
        switch poll {
        case .pending:
            return pend(ticket)
        case .ready(let result):
            guard (0...ticket.frames).contains(result.frames) else {
                throw .deliveredFramesOutOfRange(delivered: result.frames, requested: ticket.frames)
            }
            return try deliver(ticket, result)
        }
    }

    private mutating func completeFault(_ id: UInt64, _ fault: MediaReadFault) throws(PrefetchFillRefusal)
        -> PrefetchFillOutcome {
        if let stale = discardIfAbandoned(id) { return stale }
        _ = try ticketInFlight(id)
        return failRange(fault)
    }

    private mutating func discardIfAbandoned(_ id: UInt64) -> PrefetchFillOutcome? {
        guard id == abandonedTicketID else { return nil }
        abandonedTicketID = nil
        counters.noteStaleCompletion()
        return .discardedStale
    }

    private func ticketInFlight(_ id: UInt64) throws(PrefetchFillRefusal) -> PrefetchFillTicket {
        guard let ticket = inFlight, ticket.id == id else { throw .unknownTicket(id) }
        return ticket
    }

    /// `pendingPolls` counts consecutive pending polls of the ticket (at most 9, then the ticket is abandoned).
    /// Polls 1...8 are `.stillPending`; the 9th is a stall: abandoned, counted, and handled as an `ioFailure`.
    private mutating func pend(_ ticket: PrefetchFillTicket) -> PrefetchFillOutcome {
        pendingPolls += 1
        if pendingPolls <= MediaIOLimits.maximumPendingPolls {
            return .stillPending(polls: pendingPolls)
        }
        counters.noteStall()
        abandon(ticket)
        return failRange(.ioFailure)
    }

    private mutating func abandon(_ ticket: PrefetchFillTicket) {
        abandonedTicketID = ticket.id
        counters.noteAbandoned()
        inFlight = nil
    }

    /// A read with data (or a zero-frame end that closes a partial block). A read that fills its ticket or reaches
    /// the end publishes the block, which includes every frame gathered before it; any other short read is added
    /// to the partial block and nothing is published, so the pool cannot fill with blocks that cover too little.
    private mutating func deliver(_ ticket: PrefetchFillTicket,
                                  _ result: MediaReadResult) throws(PrefetchFillRefusal) -> PrefetchFillOutcome {
        let gathered = partialBlock?.frames ?? 0
        guard result.frames >= 1 || (result.reachedEnd && gathered >= 1) else {
            return emptyRead(ticket, reachedEnd: result.reachedEnd)
        }
        let whole = PrefetchFillPartialBlock(startFrame: partialBlock?.startFrame ?? ticket.startFrame,
                                             frames: gathered + result.frames)
        guard result.frames == ticket.frames || result.reachedEnd else {
            return accumulate(whole, end: ticket.startFrame + Int64(result.frames))
        }
        return try publish(whole, ticket: ticket, reachedEnd: result.reachedEnd)
    }

    /// Builds the block `whole` (its start and total frames), moves the cursor to its end and resets the runs.
    private mutating func publish(_ whole: PrefetchFillPartialBlock, ticket: PrefetchFillTicket,
                                  reachedEnd flagged: Bool) throws(PrefetchFillRefusal) -> PrefetchFillOutcome {
        let block: PrefetchBlock
        do {
            block = try PrefetchBlock.make(startFrame: whole.startFrame, frames: whole.frames,
                                           sourceGeneration: ticket.sourceGeneration,
                                           readGeneration: ticket.readGeneration)
        } catch {
            throw .blockRefused(error)
        }
        partialBlock = nil
        nextFrame = block.endFrame
        consecutiveFailures = 0
        pendingPolls = 0
        inFlight = nil
        counters.noteDelivery(frames: whole.frames)
        if flagged && nextFrame < sourceFrames { counters.noteEarlyEnd() }
        let reachedEnd = flagged || nextFrame >= sourceFrames
        state = reachedEnd ? .ended : .idle
        let delivery = PrefetchFillDelivery(block: block, restoredSource: restoring, reachedEnd: reachedEnd)
        restoring = false
        return .delivered(delivery)
    }

    /// A nonterminal short read: counted, kept in the partial block, the cursor moves to `end`, and the failure and
    /// poll runs reset (the read made progress). Not a delivery: `blocksDelivered` and `framesDelivered` count
    /// published frames only.
    private mutating func accumulate(_ partial: PrefetchFillPartialBlock, end: Int64) -> PrefetchFillOutcome {
        partialBlock = partial
        nextFrame = end
        consecutiveFailures = 0
        pendingPolls = 0
        inFlight = nil
        state = .idle
        counters.noteShortRead()
        return .accumulated(frames: partial.frames)
    }

    /// A zero-frame read: at the end it is `.endedWithoutData` (an early end, counted); otherwise a counted short
    /// read handled as a retryable `ioFailure` WITHOUT abandoning (the ticket id is consumed, no stale id is kept).
    private mutating func emptyRead(_ ticket: PrefetchFillTicket, reachedEnd: Bool) -> PrefetchFillOutcome {
        guard reachedEnd else {
            counters.noteShortRead()
            return failRange(.ioFailure)
        }
        inFlight = nil
        pendingPolls = 0
        state = .ended
        if ticket.startFrame < sourceFrames { counters.noteEarlyEnd() }
        return .endedWithoutData
    }

    /// The ticket failed: latch at once for `unavailable` or when the run exceeds the retry budget, else retry.
    private mutating func failRange(_ fault: MediaReadFault) -> PrefetchFillOutcome {
        inFlight = nil
        pendingPolls = 0
        guard fault != .unavailable else { return latch(fault) }
        consecutiveFailures += 1
        guard consecutiveFailures <= MediaIOLimits.maximumConsecutiveRetries else { return latch(fault) }
        state = .retrying
        counters.noteRetryScheduled()
        return .retryScheduled(attempt: consecutiveFailures)
    }

    private mutating func latch(_ fault: MediaReadFault) -> PrefetchFillOutcome {
        state = .failed(fault)
        counters.noteFaultLatched()
        return .sourceLost(fault)
    }

    // MARK: Recovery

    /// Moves the read cursor to `frame`. Order: negative frame, frame above the source, read generation at
    /// `UInt64.max`. Effects: the read generation increases by one, any ticket in flight is abandoned (its late
    /// completion is `.discardedStale`), the partial block is dropped (the playhead drops its blocks on a locate
    /// too), the failure and pending runs reset, and the state becomes `.idle` unless it is `.failed` (only
    /// `resume` leaves that). Nothing is thrown after validation, so a refusal changes nothing.
    mutating func locate(to frame: Int64) throws(PrefetchFillRefusal) {
        try Self.checkPosition(frame, sourceFrames: sourceFrames)
        guard readGeneration < UInt64.max else { throw .generationOverflow }
        readGeneration += 1
        if let ticket = inFlight { abandon(ticket) }
        nextFrame = frame
        partialBlock = nil
        consecutiveFailures = 0
        pendingPolls = 0
        if case .failed = state { return }
        state = .idle
    }

    /// Leaves `.failed` after the source came back under a strictly newer generation, and restarts filling at the
    /// consumer's CURRENT `position`, because `PrefetchPlayhead.adoptSourceGeneration` discards every resident block:
    /// the cursor moves to `position` (possibly backwards) and the partial block is dropped. Order: not failed, then
    /// generation not newer, then `position` negative, then `position` above the source (`position == sourceFrames`
    /// is accepted). The next delivery reports `restoredSource` once. An earlier abandoned ticket stays remembered.
    /// Nothing is thrown after validation, so a refusal changes nothing.
    mutating func resume(sourceGeneration proposed: UInt64, position: Int64) throws(PrefetchFillRefusal) {
        guard case .failed = state else { throw .notFailed }
        guard proposed > sourceGeneration else {
            throw .generationNotNewer(current: sourceGeneration, proposed: proposed)
        }
        try Self.checkPosition(position, sourceFrames: sourceFrames)
        sourceGeneration = proposed
        nextFrame = position
        partialBlock = nil
        state = .idle
        consecutiveFailures = 0
        pendingPolls = 0
        restoring = true
    }
}
