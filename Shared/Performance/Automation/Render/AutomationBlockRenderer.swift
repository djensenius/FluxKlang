//
//  AutomationBlockRenderer.swift
//  FluxKlang
//
//  Renders one automation lane, through its `ParameterArbiter`, into bounded
//  lists of `AutomationRampEvent`s over contiguous frame blocks (#108 T2).
//
//  Timing: every event comes from a knot (`AutomationRenderKnots.swift`) at a
//  frame from `MusicalClockMap.frame(atTicks:)`, rounded half-up, or from an
//  integer frame whose position is `exactTicks(atFrame:)`. A knot's events
//  belong to the block holding its frame, so rendering a window in one block or
//  any split of it gives the same events. Values come from ticks, so the same
//  ticks give the same values at any sample rate. A linear segment is exact at
//  its knots; a power segment renders as at most eight linear sub-ramps from
//  the approximation (`AutomationPowerApproximation`), plus one exact point per
//  tempo-change or loop-end crossing inside the segment.
//
//  Ownership: the renderer advances the arbiter to each knot's position and to
//  the end of each block, and emits lane events only while automation owns the
//  parameter. When a gesture, latch, glide, catch or manual hold owns it, lane
//  events are suppressed: a lane ramp still in flight is cancelled at the held
//  value, and the arbiter's own changes are rendered as ramps between advance
//  points (so a glide follows block and knot boundaries). Automation resumes
//  from the arbiter's value at the advance point where it takes back control.
//
//  Clock: like CL1, the renderer binds to the generations of its first render
//  after creation or `reset()` and refuses others (`clockRevisionChanged`), and
//  it refuses a clock that puts the block start at another position than the
//  previous block ended at (`positionMismatch`). It never re-anchors silently.
//  A loop wrap inside a block relocates the arbiter to the loop start at the
//  wrap frame; a wrap on a block boundary is applied at the next block's start.
//

/// Renders one lane over contiguous blocks. A refused call leaves the renderer and its arbiter unchanged.
struct AutomationBlockRenderer: Hashable, Sendable {
    /// The longest block one render covers, in frames.
    static let maximumBlockFrames: Int64 = 1 << 16
    /// The most events one block returns; a fuller block is refused, never truncated.
    static let maximumEvents = 1024

    private(set) var arbiter: ParameterArbiter
    /// The transport loop, if any; the renderer resolves its passes from each render's clock.
    let loop: LoopRange?
    /// The end of the last rendered block; the next render must start here.
    private(set) var cursor: Int64?
    /// The generations of the first render since creation or `reset()`; later renders must match them.
    private(set) var binding: AutomationRenderGenerations?
    /// Whether automation owned the parameter at the last advance point, so lane events are being emitted.
    private(set) var isRenderingLane = false
    /// The position the next block starts at (the loop start when a wrap falls on the cursor).
    private var cursorTicks: AutomationExactTicks?
    private var wrapPending = false
    /// The target of the last emitted event and the frame its ramp ends; `nil` before any event.
    private var hostValue: Double?
    private var hostRampEnd = Int64.min

    /// One render's working state.
    fileprivate struct Block {
        let start: Int64
        var pass: AutomationRenderPass
        var events: [AutomationRampEvent] = []
        /// The last advance point while the arbiter owns the value; its changes ramp from here.
        var holdFrom: Int64
        /// Where automation (re)entered: knots at this frame up to this position are covered by the entry.
        var floor: (frame: Int64, ticks: Double)?

        init(start: Int64, pass: AutomationRenderPass) {
            self.start = start
            self.pass = pass
            holdFrom = start
        }
    }

    init(arbiter: ParameterArbiter, loop: LoopRange? = nil) {
        self.arbiter = arbiter
        self.loop = loop
    }

    /// Renders the block `[start, end)`. The first render since creation or `reset()` may start anywhere: it
    /// relocates the arbiter to the start position, binds to `current` and emits the value there.
    mutating func render(from start: Int64, to end: Int64, clock: MusicalClockMap,
                         current: AutomationRenderGenerations) throws(AutomationRenderRefusal)
        -> [AutomationRampEvent] {
        guard start < end else { throw .invalidWindow(start: start, end: end) }
        let (span, overflow) = end.subtractingReportingOverflow(start)
        guard !overflow, span <= Self.maximumBlockFrames else {
            throw .windowTooLong(start: start, end: end, limit: Self.maximumBlockFrames)
        }
        if let cursor, cursor != start { throw .nonContiguousWindow(expected: cursor, start: start) }
        guard clock.anchor.sample.generation == current.sample else { throw .clock(.staleSampleGeneration) }
        guard clock.musical.transport == current.transport else { throw .clock(.staleTransport) }
        guard clock.map.revision == current.musicalMap else { throw .staleMusicalMap }
        if let binding, binding != current { throw .clockRevisionChanged(expected: binding, got: current) }
        var next = self
        var block = Block(start: start, pass: try AutomationRenderPass.containing(start, clock: clock, loop: loop))
        try next.render(&block, to: end, clock: clock)
        next.binding = current
        self = next
        return block.events
    }

    /// Applies a gesture at the arbiter's position (the end of the last block). Its effect on the output
    /// starts with the next block.
    mutating func perform(_ gesture: AutomationRenderGesture) throws(AutomationRenderRefusal) -> ArbitrationResult {
        guard cursor != nil, let position = arbiter.position else { throw .notStarted }
        do {
            switch gesture {
            case let .touch(source, priority): return try arbiter.touch(source, priority: priority, at: position)
            case let .move(source, value): return try arbiter.move(source, to: value, at: position)
            case let .release(source): return try arbiter.release(source, at: position)
            case let .setMode(mode): return try arbiter.setMode(mode, at: position)
            }
        } catch {
            throw .automation(error)
        }
    }

    /// Forgets the cursor, binding and output state, keeping the arbiter. Call it after a clock revision
    /// change or a transport jump; the next render may start anywhere and binds to its own generations.
    mutating func reset() {
        cursor = nil
        binding = nil
        isRenderingLane = false
        cursorTicks = nil
        wrapPending = false
        hostValue = nil
        hostRampEnd = Int64.min
    }

    private mutating func render(_ block: inout Block, to end: Int64,
                                 clock: MusicalClockMap) throws(AutomationRenderRefusal) {
        let position = block.pass.exactTicks(atFrame: block.start)
        if let cursorTicks {
            guard cursorTicks.isSame(as: position) else { throw .positionMismatch(frame: block.start) }
            if wrapPending { try wrap(&block, at: block.start) }
            try reconcile(&block, at: block.start, ticks: position.position, reason: .resume)
        } else {
            try relocate(to: position.position)
            try reconcile(&block, at: block.start, ticks: position.position, reason: .start)
        }
        var from = block.start
        while true {
            let limit = min(end, block.pass.wrapFrame ?? end)
            let boundary = try walk(&block, from: from, to: limit)
            guard limit < end else {
                try finish(&block, at: end, boundary: boundary)
                return
            }
            block.pass = try AutomationRenderPass.containing(limit, clock: clock, loop: loop)
            try wrap(&block, at: limit)
            from = limit
        }
    }

    /// Visits every knot with a frame in `[from, limit)`; returns the position of the first knot after them.
    private mutating func walk(_ block: inout Block, from: Int64,
                               to limit: Int64) throws(AutomationRenderRefusal) -> Double? {
        var source = AutomationKnotSource(lane: arbiter.lane, pass: block.pass)
        var (previous, current) = try source.bracket(before: from)
        while let knot = current, knot.frame < limit {
            let next = try source.next(after: knot)
            try advance(to: knot.ticks)
            try reconcile(&block, at: knot.frame, ticks: knot.ticks, reason: .resume)
            if isRenderingLane, !block.covers(knot) {
                if let previous, !source.ramps(from: previous) || previous.frame == knot.frame {
                    try emit(&block, at: knot.frame, knot.value, ramp: 0, .curve)
                }
                if source.ramps(from: knot), let next, next.frame > knot.frame {
                    try emit(&block, at: knot.frame, next.value, ramp: next.frame - knot.frame, .curve)
                }
            }
            previous = knot
            current = next
        }
        return current?.ticks
    }

    /// Ends the block: advances the arbiter to the end position without passing an unvisited knot or the
    /// loop end, renders any arbiter-owned change up to the end, and records where the next block starts.
    private mutating func finish(_ block: inout Block, at end: Int64,
                                 boundary: Double?) throws(AutomationRenderRefusal) {
        let pass = block.pass
        var target = pass.exactTicks(atFrame: end).position
        if let boundary { target = min(target, boundary.nextDown) }
        if let loopEnd = pass.loopEnd { target = min(target, Double(loopEnd).nextDown) }
        try advance(to: target)
        // The arbiter owned the value since `holdFrom` (a glide or catch may have handed it back to the lane
        // during the advance; the lane resumes from the reached value at the next block).
        if !isRenderingLane, let value = arbiter.value, hostValue != value {
            try emit(&block, at: block.holdFrom, value, ramp: end - block.holdFrom, .hold)
        }
        cursor = end
        wrapPending = pass.wrapFrame == end
        if wrapPending, let loopStart = pass.loopStart {
            cursorTicks = AutomationExactTicks(loopStart)
        } else {
            cursorTicks = pass.exactTicks(atFrame: end)
        }
    }

    /// The transport wraps to the loop start at `frame`: the arbiter relocates there, and automation re-enters.
    private mutating func wrap(_ block: inout Block, at frame: Int64) throws(AutomationRenderRefusal) {
        guard let loop else { return }
        try relocate(to: Double(loop.startTicks))
        isRenderingLane = false
        try reconcile(&block, at: frame, ticks: Double(loop.startTicks), reason: .loopWrap)
    }

    /// Matches the output to the arbiter's owner at an advance point.
    private mutating func reconcile(_ block: inout Block, at frame: Int64, ticks: Double,
                                    reason: AutomationRampEvent.Reason) throws(AutomationRenderRefusal) {
        guard let value = arbiter.value else { return }
        guard arbiter.owner == .automation else {
            isRenderingLane = false
            if hostRampEnd > frame {
                try emit(&block, at: frame, value, ramp: 0, .hold)
            } else if hostValue != value {
                try emit(&block, at: block.holdFrom, value, ramp: frame - block.holdFrom, .hold)
            }
            block.holdFrom = frame
            return
        }
        guard !isRenderingLane else { return }
        isRenderingLane = true
        block.floor = (frame, ticks)
        if reason == .resume, hostValue != value, block.holdFrom < frame {
            // A glide or catch handed the value back between advance points: ramp to it rather than jump.
            try emit(&block, at: block.holdFrom, value, ramp: frame - block.holdFrom, .hold)
        } else if reason != .resume || hostValue != value || hostRampEnd > frame {
            try emit(&block, at: frame, value, ramp: 0, reason)
        }
        var source = AutomationKnotSource(lane: arbiter.lane, pass: block.pass)
        if let target = try source.target(after: ticks), target.frame > frame {
            try emit(&block, at: frame, target.value, ramp: target.frame - frame, reason)
        }
    }

    private mutating func emit(_ block: inout Block, at frame: Int64, _ value: Double, ramp: Int64,
                               _ reason: AutomationRampEvent.Reason) throws(AutomationRenderRefusal) {
        guard block.events.count < Self.maximumEvents else { throw .tooManyEvents(limit: Self.maximumEvents) }
        block.events.append(AutomationRampEvent(frame: frame, offset: Int(frame - block.start), value: value,
                                                rampFrames: ramp, reason: reason))
        hostValue = value
        hostRampEnd = frame + ramp
    }

    private mutating func advance(to ticks: Double) throws(AutomationRenderRefusal) {
        do {
            _ = try arbiter.advance(to: max(ticks, arbiter.position ?? ticks))
        } catch {
            throw .automation(error)
        }
    }

    private mutating func relocate(to ticks: Double) throws(AutomationRenderRefusal) {
        do {
            _ = try arbiter.relocate(to: ticks)
        } catch {
            throw .automation(error)
        }
    }
}

fileprivate extension AutomationBlockRenderer.Block {
    /// Whether the entry at `floor` already covers `knot`: it lies on the entry frame at or before its position.
    func covers(_ knot: AutomationKnot) -> Bool {
        guard let floor else { return false }
        return knot.frame == floor.frame && knot.ticks <= floor.ticks
    }
}
