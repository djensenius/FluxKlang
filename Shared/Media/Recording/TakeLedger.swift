//
//  TakeLedger.swift
//  FluxKlang
//
//  Builds recording takes from capture progress and `RuntimeDiscontinuity`
//  records (media-contract.md §8.3): a clock restart or sample jump splits a
//  take into segments (an empty closed segment is dropped, its boundary
//  kept), overflow intervals are attributed to the segment that wholly
//  contains them, `droppedFrames` sums the padding, and finishing checks the
//  stop against the stop the take owns, then seals it. No abnormal path leaves a
//  take stuck: a segment without an anchor finishes unplaced with typed
//  evidence, a jump before the take's start ends it at its last good frame, and
//  any unfinished take can be discarded with a typed reason. A take the ledger
//  ended owns no further record, through `ingest` or `append`, and never blocks
//  a restart; `ingest` reports `.ended` so the caller can open a new take. For
//  #109: until that ended take is finished or discarded, a post-jump overflow (at
//  or after the jump's frame, in its generation) no take records is refused
//  `.recordNotOwned`, and a late pre-jump overflow for it is refused, never
//  attached. A restart needs every
//  capturing take on its clock at `previousFrame`: one lagging take refuses it
//  for all (typed, nothing changes) until its progress is advanced.
//  Pure bookkeeping: no file I/O, handoffs or resampling. Deterministic and
//  append-only; a refused input changes nothing (stale anchors are remembered).
//

struct GenerationSlot: Hashable, Sendable {
    let clock: UInt32
    let generation: UInt64
}

/// What one ingested record did to one take. `TakeLedger.ingest` lists them in opening order.
enum TakeIngestEffect: Hashable, Sendable {
    /// A restart or jump closed the take's current segment and opened the next.
    case split(TakeID)
    /// The ledger ended the take at its last good frame; audio after the record needs a new take.
    case ended(TakeID, TakeStopReason)
    /// An overflow or `captureStopped` was appended to the take.
    case recorded(TakeID)

    var take: TakeID {
        switch self {
        case .split(let take), .ended(let take, _), .recorded(let take): take
        }
    }
}

struct TakeLedger: Sendable {
    static let maximumTakes = 256
    static let maximumSegmentsPerTake = 1_024
    static let maximumOverflowsPerSegment = 4_096
    /// Restarts and jumps recorded in one take's history, dropped empty segments included.
    static let maximumBoundariesPerTake = 2_048
    /// Applies separately to observed anchors and to ingested restarts.
    static let maximumGenerationRecords = 4_096

    let timebase: HostTimebase
    /// Every take, open, finished or discarded, in opening order.
    private(set) var order: [TakeID] = []
    private var states: [TakeID: TakeLedgerState] = [:]
    private var anchors: [GenerationSlot: GenerationAnchor] = [:]
    private var restarts: Set<GenerationSlot> = []
    private var latestGeneration: [UInt32: UInt64] = [:]
    /// Generations whose anchor was refused stale; evidence for unplaced segments.
    private(set) var staleAnchors: Set<GenerationSlot> = []

    init(timebase: HostTimebase) throws(TakeLedgerError) {
        guard timebase.numer > 0, timebase.denom > 0 else { throw .invalidTimebase }
        self.timebase = timebase
    }

    /// The finished take, or nil while it is open, discarded or unknown.
    func take(_ id: TakeID) -> RecordingTake? {
        guard case .finished(let take)? = states[id]?.outcome else { return nil }
        return take
    }

    func discarded(_ id: TakeID) -> DiscardedTake? {
        guard case .discarded(let take)? = states[id]?.outcome else { return nil }
        return take
    }

    func isOpen(_ id: TakeID) -> Bool {
        states[id]?.isOpen ?? false
    }

    /// The stop the ledger itself gave the take at a discontinuity, open, finished or discarded.
    func ledgerStop(_ take: TakeID) -> TakeStopReason? {
        guard let reason = states[take]?.stop?.reason, reason.isLedgerStop else { return nil }
        return reason
    }

    func anchor(clock: UInt32, generation: UInt64) -> GenerationAnchor? {
        anchors[GenerationSlot(clock: clock, generation: generation)]
    }

    // MARK: Clock observations

    /// Records a generation's first anchor and nominal rate. Later anchors of the same
    /// generation are drift-checked elsewhere (§5.2) and do not move the take's alignment.
    mutating func observe(_ anchor: RuntimeClockAnchor, nominalRate: Int) throws(TakeLedgerError) {
        guard MediaNominalRate.isValid(nominalRate) else { throw .invalidRate(nominalRate) }
        let generation = anchor.sample.generation
        _ = try Self.contractGeneration(generation)
        let slot = GenerationSlot(clock: anchor.sample.clock, generation: generation)
        if let first = anchors[slot] {
            guard first.nominalRate == nominalRate else { throw .rateMismatch(generation: generation) }
            return
        }
        guard generation >= latestGeneration[slot.clock, default: 0] else {
            if staleAnchors.count < Self.maximumGenerationRecords { staleAnchors.insert(slot) }
            throw .staleGeneration(generation)
        }
        guard anchors.count < Self.maximumGenerationRecords else { throw .tooManyGenerationRecords }
        anchors[slot] = GenerationAnchor(frame: anchor.sample.frame, hostTicks: anchor.host.ticks,
                                         nominalRate: nominalRate)
        latestGeneration[slot.clock] = generation
    }

    // MARK: Takes

    mutating func open(_ opening: TakeOpening) throws(TakeLedgerError) {
        guard states[opening.take] == nil else { throw .duplicateTake(opening.take) }
        guard order.count < Self.maximumTakes else { throw .tooManyTakes }
        let generation = opening.startGeneration
        _ = try Self.contractGeneration(generation)
        let clock = opening.startClockSlot
        guard generation >= latestGeneration[clock, default: 0] else { throw .staleGeneration(generation) }
        let busy = states.values.contains {
            $0.holdsStream && ($0.opening.streamSlot == opening.streamSlot || $0.opening.stream == opening.stream)
        }
        guard !busy else { throw .streamBusy(opening.stream) }
        order.append(opening.take)
        states[opening.take] = TakeLedgerState(opening: opening)
        latestGeneration[clock] = generation
    }

    /// Capture progress: frames `[segment start, stamp.frame)` of the current segment,
    /// padded overflow included, are in the take.
    mutating func advance(_ take: TakeID, to stamp: RuntimeSampleStamp) throws(TakeLedgerError) {
        var state = try openState(take)
        try state.advance(to: stamp)
        states[take] = state
    }

    /// Appends an `overflow` or `captureStopped` record addressed to `take`. A record for
    /// another stream, clock or generation, or not wholly inside a segment, is refused. A take
    /// the ledger ended owns no further record, as in `ingest`: `.recordNotOwned`.
    mutating func append(_ record: RuntimeDiscontinuity, to take: TakeID) throws(TakeLedgerError) {
        var state = try openState(take)
        guard let stream = record.stream else { throw .missingStream }
        guard state.stop?.reason.isLedgerStop != true else {
            throw .recordNotOwned(stream: stream, frame: record.sample.frame)
        }
        guard stream == state.opening.streamSlot else { throw .streamMismatch }
        guard record.sample.clock == state.opening.startClockSlot else { throw .clockMismatch }
        switch record.kind {
        case .overflow:
            try state.appendOverflow(record.sample, frames: record.frames)
        case .captureStopped(let reason):
            try state.appendStop(record.sample, reason: reason)
        default:
            throw .unsupportedDiscontinuity
        }
        states[take] = state
    }

    /// Routes one capture-side record. A clock restart splits every capturing take on its clock;
    /// a `sampleJump` splits every capturing take of its clock and generation (only its stream's,
    /// if it names one), or ends one it sends before its start (`.ended`, so the caller can open a
    /// new take for the audio that follows); an `overflow` or `captureStopped` goes to the take
    /// that owns it (§8.3). Effects are in opening order; empty for a kind takes do not account
    /// (underrun, locate, …) or a record before every open take of its stream and generation
    /// (pre-roll, other streams). A record a take on its stream could have owned is never dropped:
    /// unowned, it is refused `.recordNotOwned` (a take the ledger ended owns no further record).
    /// Ownership is decided before the frames are checked: an overflow without a length is routed
    /// like a 1-frame one, then its owner refuses it (`.missingOverflowFrames`, or `.takeSealed`).
    mutating func ingest(_ record: RuntimeDiscontinuity) throws(TakeLedgerError) -> [TakeIngestEffect] {
        switch record.kind {
        case .clockRestart(let previousFrame):
            return try restart(record.sample, previousFrame: previousFrame)
        case .sampleJump:
            return try jump(record.sample, stream: record.stream)
        case .overflow, .captureStopped:
            guard let stream = record.stream else { throw .missingStream }
            guard let owner = owner(of: record) else {
                guard !mustBeOwned(record, stream: stream) else {
                    throw .recordNotOwned(stream: stream, frame: record.sample.frame)
                }
                return []
            }
            try append(record, to: owner)
            return [.recorded(owner)]
        default:
            return []
        }
    }

    /// An unowned record is refused when an open take records its stream and clock and it is
    /// not pre-roll: any `captureStopped`, or an overflow at or after the start of one of that
    /// take's segments in the record's generation (a late one past a closed segment's end), or,
    /// once the ledger ended the take, at or after the jump's target in the jump's generation
    /// (post-jump audio, even below the old segment's start).
    private func mustBeOwned(_ record: RuntimeDiscontinuity, stream: UInt32) -> Bool {
        states.values.contains { state in
            guard state.isOpen, state.opening.streamSlot == stream,
                  state.opening.startClockSlot == record.sample.clock else { return false }
            if case .captureStopped = record.kind { return true }
            if let stop = state.stop, stop.reason.isLedgerStop, stop.reportedGeneration == record.sample.generation,
               stop.reportedFrame <= record.sample.frame { return true }
            return state.segments.contains {
                $0.generation == record.sample.generation && $0.startFrame <= record.sample.frame
            }
        }
    }

    /// The take that owns an `overflow` or `captureStopped` record, in opening order: a
    /// capturing owner first, then a stopped but unfinished one, then a closed one (which
    /// refuses it `.takeSealed`; a closed take never receives a record).
    func owner(of record: RuntimeDiscontinuity) -> TakeID? {
        guard let stream = record.stream else { return nil }
        let owners = order.filter { id in
            states[id]?.owns(stream: stream, sample: record.sample, kind: record.kind, frames: record.frames) ?? false
        }
        return owners.first { states[$0]?.isCapturing ?? false }
            ?? owners.first { states[$0]?.isOpen ?? false } ?? owners.first
    }

    /// Checks the stop against the stop the take owns, converts every stored segment to its
    /// persisted form and seals the take. A missing anchor never fails it: the segment is
    /// finished `.unplaced` with the reason.
    mutating func finish(_ take: TakeID, reason: TakeStopReason) throws(TakeLedgerError) -> RecordingTake {
        var state = try openState(take)
        try state.validateStop(reason)
        let recording = try seal(state, reason: reason)
        state.seal(recording)
        states[take] = state
        return recording
    }

    /// Gives up any unfinished take: it stays in the history, discarded with `reason`, its
    /// stream is freed and its segments and evidence stay readable.
    @discardableResult
    mutating func discard(_ take: TakeID, reason: TakeDiscardReason) throws(TakeLedgerError) -> DiscardedTake {
        var state = try openState(take)
        let record = try state.discard(reason)
        states[take] = state
        return record
    }

    // MARK: Private

    private func openState(_ take: TakeID) throws(TakeLedgerError) -> TakeLedgerState {
        guard let state = states[take] else { throw .unknownTake(take) }
        guard state.isOpen else { throw .takeSealed(take) }
        return state
    }

    /// Every capturing take on the clock must stand at `previousFrame`: one lagging take's
    /// frontier refuses the restart for all (`.segmentEndMismatch`, nothing changes) until its
    /// progress is advanced, then the same restart is accepted.
    private mutating func restart(_ sample: RuntimeSampleStamp,
                                  previousFrame: Int64) throws(TakeLedgerError) -> [TakeIngestEffect] {
        let generation = sample.generation
        guard generation > 1 else { throw .generationOutOfRange(generation) }
        let slot = GenerationSlot(clock: sample.clock, generation: generation)
        guard !restarts.contains(slot), generation >= latestGeneration[slot.clock, default: 0] else {
            throw .staleGeneration(generation)
        }
        guard restarts.count < Self.maximumGenerationRecords else { throw .tooManyGenerationRecords }
        // A stopped take is passed by, but its recorded stop must not lie past the restart (§8.3),
        // whether the take is still open, finished or discarded: its state, stop included, stays in
        // `states` (at most `maximumTakes` stops). A take the ledger ended at a discontinuity is
        // exempt: its frames predate the jump.
        for id in order {
            guard let state = states[id], state.opening.startClockSlot == sample.clock,
                  let stop = state.stop, !stop.reason.isLedgerStop, stop.generation + 1 == generation,
                  stop.frame > previousFrame else { continue }
            throw .stopAfterRestart(id, stopFrame: stop.frame, previousFrame: previousFrame)
        }
        let affected = try split(.clockRestart(previousFrame: previousFrame), at: sample, stream: nil)
        restarts.insert(slot)
        latestGeneration[slot.clock] = generation
        return affected
    }

    private mutating func jump(_ sample: RuntimeSampleStamp,
                               stream: UInt32?) throws(TakeLedgerError) -> [TakeIngestEffect] {
        guard sample.generation >= latestGeneration[sample.clock, default: 0] else {
            throw .staleGeneration(sample.generation)
        }
        let affected = try split(.sampleJump, at: sample, stream: stream)
        latestGeneration[sample.clock] = sample.generation
        return affected
    }

    /// Splits every affected take atomically: all validate before any changes.
    private mutating func split(_ reason: SegmentBoundaryReason, at sample: RuntimeSampleStamp,
                                stream: UInt32?) throws(TakeLedgerError) -> [TakeIngestEffect] {
        let generation = try Self.contractGeneration(sample.generation)
        let affected = order.filter { id in
            guard let state = states[id], state.isCapturing, state.opening.startClockSlot == sample.clock,
                  stream.map({ $0 == state.opening.streamSlot }) ?? true else { return false }
            return reason == .sampleJump ? state.current.generation <= sample.generation
                : state.current.generation < sample.generation
        }
        var updated: [TakeID: TakeLedgerState] = [:]
        var effects: [TakeIngestEffect] = []
        for id in affected {
            guard var state = states[id] else { continue }
            if reason == .sampleJump, state.jumpsBeforeStart(sample) {
                state.end(at: sample, .jumpBeforeTakeStart)
                effects.append(.ended(id, .discontinuity(.jumpBeforeTakeStart)))
            } else {
                try state.validateBoundary(reason, into: sample.generation)
                state.applyBoundary(reason, into: generation, rawGeneration: sample.generation,
                                    startFrame: sample.frame)
                effects.append(.split(id))
            }
            updated[id] = state
        }
        states.merge(updated) { _, new in new }
        return effects
    }

    private func seal(_ state: TakeLedgerState, reason: TakeStopReason) throws(TakeLedgerError) -> RecordingTake {
        let opening = state.opening
        let stored = state.storedSegments
        guard let first = stored.first else { throw .emptySegment }
        let base = anchor(clock: opening.startClockSlot, generation: first.generation).map {
            AnchoredFrame(frame: first.startFrame, anchor: $0)
        }
        var segments: [RecordingSegment] = []
        var fileFrame: Int64 = 0
        for segment in stored {
            let own = anchor(clock: opening.startClockSlot, generation: segment.generation)
            let frames = try Self.checked(segment.endFrame.subtractingReportingOverflow(segment.startFrame))
            segments.append(try RecordingSegment(
                clock: opening.clock, generation: try Self.contractGeneration(segment.generation),
                nominalRate: own?.nominalRate, startFrame: segment.startFrame,
                placement: try placement(of: segment, clock: opening.startClockSlot, anchor: own, base: base),
                fileFrameStart: fileFrame, frames: frames, overflows: segment.overflows, openedBy: segment.openedBy))
            fileFrame = try Self.checked(fileFrame.addingReportingOverflow(frames))
        }
        return try RecordingTake(take: opening.take, stream: opening.stream, inputLatency: opening.inputLatency,
                                 segments: segments, boundaries: state.boundaries, stopReason: reason,
                                 stopMark: try state.stopMark())
    }

    private func placement(of segment: CapturedSegment, clock: UInt32, anchor: GenerationAnchor?,
                           base: AnchoredFrame?) throws(TakeLedgerError) -> SegmentPlacement {
        guard let anchor else {
            let slot = GenerationSlot(clock: clock, generation: segment.generation)
            return .unplaced(staleAnchors.contains(slot) ? .anchorRefusedStale : .anchorNotObserved)
        }
        guard let base else { return .unplaced(.takeAnchorMissing) }
        let offset = try TakeOffsetMath.offsetNs(of: AnchoredFrame(frame: segment.startFrame, anchor: anchor),
                                                 from: base, timebase: timebase)
        return offset >= 0 ? .placed(startOffsetNs: offset) : .unplaced(.beforeTakeStart)
    }

    private static func checked(_ result: (partialValue: Int64, overflow: Bool)) throws(TakeLedgerError) -> Int64 {
        guard !result.overflow else { throw .arithmeticOverflow }
        return result.partialValue
    }

    /// Runtime generations are `UInt64`; the take document uses `Generation` (1 ... 2^53 − 1).
    static func contractGeneration(_ raw: UInt64) throws(TakeLedgerError) -> Generation {
        guard let value = Int(exactly: raw), let generation = try? Generation(value) else {
            throw .generationOutOfRange(raw)
        }
        return generation
    }
}
