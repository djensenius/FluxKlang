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
//  belong to the block holding its frame, so with automation in charge a
//  window rendered in one block or in any split of it gives the same events (a
//  gesture's ramps are chords between advance points: see Ownership). Values
//  come from ticks: breakpoint, tempo and loop knots carry the same values at
//  any sample rate, and a power segment's interior knots, which sit on whole
//  frames, agree across rates to within the curve's change over one frame. A
//  linear segment is exact at its knots; a power segment renders as at most
//  eight linear sub-ramps from the approximation
//  (`AutomationPowerApproximation`), plus one exact point per tempo-change or
//  loop-end crossing inside the segment (coordinator ruling).
//
//  Ownership: the renderer advances the arbiter to each knot's position and to
//  the end of each block, and emits lane events only while automation owns the
//  parameter. When a gesture, latch, glide, catch or manual hold owns it, lane
//  events are suppressed: a lane ramp still in flight is cancelled at the held
//  value, and the arbiter's own changes are rendered as ramps between advance
//  points (so a glide follows block and knot boundaries). At each knot the
//  arbiter first advances to just before the knot, and its changes ramp to that
//  value ending on the knot's frame; then it advances onto the knot, and any
//  change there (a step, a catch, a latch ending) is immediate, so a held value
//  never moves before the curve reaches it. Once every knot on that frame is
//  resolved, it advances to the frame's own position, which lies past the tick
//  of a knot rounded up onto its frame, and any change up to there (a stepped glide's next
//  whole step, a glide or catch handing back) is immediate too, so the frame
//  shows what the arbiter shows at its position (at the last knot's tick, when
//  that is later). A stepped lane never ramps: each whole step of a glide is
//  set at the first frame whose position shows it.
//  Automation resumes from the arbiter's value where it takes back control,
//  including a knot on that frame the arbiter has not yet passed. A touch that
//  takes the value from a rendering lane holds what the host shows on that frame
//  (a sub-ramp only approximates a power curve), so touching without moving
//  never jumps.
//
//  Clock: like CL1, the renderer binds to the generations of its first render
//  after creation or `reset()` and refuses others (`clockRevisionChanged`), and
//  it refuses a clock that puts the block start at another position than the
//  previous block ended at (`positionMismatch`). It never re-anchors silently.
//
//  Loops: `loop` is fixed at creation and kept by `reset()`; after a loop
//  change, build a new renderer from `renderer.arbiter`. A wrap inside a block
//  first advances the arbiter to the end of the pass as a block end does, then
//  relocates it to the loop start at the wrap frame; a wrap on a block boundary
//  is applied at the next block's start. One render applies at most
//  `maximumWraps` wraps.
//
//  Not real-time safe: a render allocates (its event list and knot caches), so
//  call it off the render thread and hand the events over.
//

/// Renders one lane over contiguous blocks. A refused call leaves the renderer and its arbiter unchanged.
struct AutomationBlockRenderer: Hashable, Sendable {
    /// The longest block one render covers, in frames.
    static let maximumBlockFrames: Int64 = 1 << 16
    /// The most events one block returns; a fuller block is refused, never truncated.
    static let maximumEvents = 1024
    /// The most loop wraps one render applies; a very short loop (held by a gesture, so emitting nothing) is
    /// refused beyond it rather than looped through up to `maximumBlockFrames` times.
    static let maximumWraps = 1024

    private(set) var arbiter: ParameterArbiter
    /// The transport loop, if any; the renderer resolves its passes from each render's clock.
    let loop: LoopRange?
    /// The end of the last rendered block; the next render must start here.
    private(set) var cursor: Int64?
    /// The generations of the first render since creation or `reset()`; later renders must match them.
    private(set) var binding: AutomationRenderGenerations?
    /// Whether automation owned the parameter at the last advance point and no gesture has taken it since, so lane
    /// events are being emitted.
    private(set) var isRenderingLane = false
    /// The position the next block starts at (the loop start when a wrap falls on the cursor).
    private var cursorTicks: AutomationExactTicks?
    private var wrapPending = false
    /// The ramp of the last emitted event, which the host is following; `nil` before any event.
    private var host: AutomationHostRamp?

    /// The target of the last emitted event.
    private var hostValue: Double? { host?.target }
    /// The frame the last emitted event's ramp ends.
    private var hostRampEnd: Int64 { host?.end ?? .min }

    /// One render's working state.
    fileprivate struct Block {
        let start: Int64
        var pass: AutomationRenderPass
        var events: [AutomationRampEvent] = []
        /// The last advance point while the arbiter owns the value, and the arbiter there; its changes since
        /// then are rendered from here.
        var holdFrom: Int64
        var held: ParameterArbiter
        /// Where automation (re)entered: knots at this frame up to this position are covered by the entry.
        var floor: (frame: Int64, ticks: Double)?
        /// The loop wraps applied so far, including one carried from the previous block's end.
        var wraps = 0

        init(start: Int64, pass: AutomationRenderPass, arbiter: ParameterArbiter) {
            self.start = start
            self.pass = pass
            holdFrom = start
            held = arbiter
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
        var block = Block(start: start, pass: try AutomationRenderPass.containing(start, clock: clock, loop: loop),
                          arbiter: arbiter)
        try next.render(&block, to: end, clock: clock)
        next.binding = current
        self = next
        return block.events
    }

    /// Applies a gesture at the arbiter's position (the end of the last block). Its effect on the output
    /// starts with the next block. A touch that takes the value from a rendering lane holds what the host shows
    /// on the next block's first frame rather than the exact curve (a power sub-ramp only approximates it), so
    /// touching without moving never jumps. A gesture that takes the value from automation ends lane rendering
    /// even when automation resumes before the next block (a lane without breakpoints resumes at once), so that
    /// block renders the value automation resumed with, and a touch after such a hand-back holds that value, not
    /// the one the host still shows.
    mutating func perform(_ gesture: AutomationRenderGesture) throws(AutomationRenderRefusal) -> ArbitrationResult {
        guard let cursor, let position = arbiter.position else { throw .notStarted }
        var next = arbiter
        let result: ArbitrationResult
        do {
            switch gesture {
            case let .touch(source, priority):
                result = try next.touch(source, priority: priority, at: position)
                if isRenderingLane, let shown = host?.value(at: cursor), shown != next.value {
                    _ = try next.move(source, to: shown, at: position)
                }
            case let .move(source, value): result = try next.move(source, to: value, at: position)
            case let .release(source): result = try next.release(source, at: position)
            case let .setMode(mode): result = try next.setMode(mode, at: position)
            }
        } catch {
            throw .automation(error)
        }
        arbiter = next
        if next.owner != .automation { isRenderingLane = false }
        return ArbitrationResult(outcome: result.outcome, owner: next.owner, value: next.value)
    }

    /// Forgets the cursor, binding and output state, keeping the arbiter and the loop. Call it after a clock
    /// revision change or a transport jump; the next render may start anywhere and binds to its own generations.
    /// The loop is fixed at creation: after a loop change, build a new renderer from `arbiter`.
    mutating func reset() {
        cursor = nil
        binding = nil
        isRenderingLane = false
        cursorTicks = nil
        wrapPending = false
        host = nil
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
            // A wrap inside the block reaches the end of the pass exactly as a wrap on a block boundary does.
            try settle(&block, at: limit, boundary: boundary)
            guard limit < end else {
                finish(block, at: end)
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
            // The arbiter's own changes reach the value just before the knot on its frame; a change on the knot
            // itself (a step, a catch, a latch ending) is then immediate there.
            try advance(to: knot.ticks.nextDown)
            try reconcile(&block, at: knot.frame, ticks: knot.ticks.nextDown, reason: .resume)
            try advance(to: knot.ticks)
            try reconcile(&block, at: knot.frame, ticks: knot.ticks, reason: .resume)
            if isRenderingLane, !block.covers(knot) {
                let arrives = previous.map { !source.ramps(from: $0) || $0.frame == knot.frame } ?? false
                // An entry on the knot's frame but before its position (a start rounded down onto the frame, or a
                // hand-back just before it) has not reached the knot's value yet.
                let entered = block.floor?.frame == knot.frame && hostValue != knot.value
                if arrives || entered {
                    try emit(&block, at: knot.frame, knot.value, ramp: 0, .curve)
                }
                if source.ramps(from: knot), let next, next.frame > knot.frame {
                    try emit(&block, at: knot.frame, next.value, ramp: next.frame - knot.frame, .curve)
                }
            }
            // With every knot on the frame resolved, the frame shows what the arbiter shows at its own position,
            // which a frame rounded past its last knot reaches only here: the arbiter's changes since the knot's
            // tick (a stepped glide's next step, a glide or catch handing back) are immediate on the frame as well.
            if next?.frame != knot.frame {
                let reached = try advance(toFrame: knot.frame, in: block.pass, before: next?.ticks)
                try reconcile(&block, at: knot.frame, ticks: reached, reason: .resume)
            }
            previous = knot
            current = next
        }
        return current?.ticks
    }

    /// Advances the arbiter to the position of `frame` (a block end, a wrap or a knot's frame) without passing the
    /// unvisited knot at `boundary` or the loop end; returns the position reached.
    @discardableResult
    private mutating func advance(toFrame frame: Int64, in pass: AutomationRenderPass,
                                  before boundary: Double?) throws(AutomationRenderRefusal) -> Double {
        var target = pass.exactTicks(atFrame: frame).position
        if let boundary { target = min(target, boundary.nextDown) }
        if let loopEnd = pass.loopEnd { target = min(target, Double(loopEnd).nextDown) }
        try advance(to: target)
        return target
    }

    /// Advances the arbiter to the position of `frame` (a block end or a wrap) without passing an unvisited knot
    /// or the loop end, and renders any arbiter-owned change up to `frame`.
    private mutating func settle(_ block: inout Block, at frame: Int64,
                                 boundary: Double?) throws(AutomationRenderRefusal) {
        try advance(toFrame: frame, in: block.pass, before: boundary)
        // The arbiter owned the value since `holdFrom` (a glide or catch may have handed it back to the lane
        // during the advance; the lane resumes from the reached value at `frame`).
        if !isRenderingLane, let value = arbiter.value, hostValue != value {
            try hold(&block, to: frame, value, settling: true)
        }
        block.holdFrom = frame
        block.held = arbiter
    }

    /// Records where the next block starts.
    private mutating func finish(_ block: Block, at end: Int64) {
        cursor = end
        wrapPending = block.pass.wrapFrame == end
        if wrapPending, let loopStart = block.pass.loopStart {
            cursorTicks = AutomationExactTicks(loopStart)
        } else {
            cursorTicks = block.pass.exactTicks(atFrame: end)
        }
    }

    /// The transport wraps to the loop start at `frame`: the arbiter relocates there, and automation re-enters.
    private mutating func wrap(_ block: inout Block, at frame: Int64) throws(AutomationRenderRefusal) {
        guard let loop else { return }
        block.wraps += 1
        guard block.wraps <= Self.maximumWraps else { throw .tooManyWraps(limit: Self.maximumWraps) }
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
                try hold(&block, to: frame, value)
            }
            block.holdFrom = frame
            block.held = arbiter
            return
        }
        guard !isRenderingLane else { return }
        isRenderingLane = true
        // Automation enters where the arbiter is, which may be short of `ticks` when a block starts on the frame
        // of a knot the arbiter has not passed; that knot is still rendered.
        let entry = min(ticks, arbiter.position ?? ticks)
        block.floor = (frame, entry)
        if reason == .resume, hostValue != value, block.holdFrom < frame {
            // A glide or catch handed the value back between advance points: reach it rather than jump.
            try hold(&block, to: frame, value)
        } else if reason != .resume || hostValue != value || hostRampEnd > frame {
            try emit(&block, at: frame, value, ramp: 0, reason)
        }
        var source = AutomationKnotSource(lane: arbiter.lane, pass: block.pass)
        if let target = try source.target(after: entry), target.frame > frame {
            try emit(&block, at: frame, target.value, ramp: target.frame - frame, reason)
        }
    }

    /// Renders the arbiter's own change since `holdFrom` so the host shows `value` at `frame`: one ramp, or on a
    /// stepped lane each whole step at the first frame whose position shows it, never a fractional value. When
    /// `settling` (a block end or a wrap), a stepped change on `frame` itself is left to whatever renders that
    /// frame next, so a wrap inside a block and one on a block boundary render alike.
    private mutating func hold(_ block: inout Block, to frame: Int64, _ value: Double,
                               settling: Bool = false) throws(AutomationRenderRefusal) {
        guard arbiter.lane.isStepped else {
            try emit(&block, at: block.holdFrom, value, ramp: frame - block.holdFrom, .hold)
            return
        }
        try steps(&block, before: frame)
        if !settling, hostValue != value { try emit(&block, at: frame, value, ramp: 0, .hold) }
    }

    /// Sets each whole step a stepped value takes in `(holdFrom, frame)` at the first frame showing it. A stepped
    /// lane only steps at breakpoints, and no breakpoint lies between advance points, so a glide there moves one
    /// way only and bisection finds each step.
    private mutating func steps(_ block: inout Block, before frame: Int64) throws(AutomationRenderRefusal) {
        guard var shown = hostValue else { return }
        var low = block.holdFrom
        while low + 1 < frame, let last = try block.value(at: frame - 1), last != shown {
            var high = frame - 1
            var value = last
            while high - low > 1 {
                let middle = low + (high - low) / 2
                if let probe = try block.value(at: middle), probe != shown {
                    high = middle
                    value = probe
                } else {
                    low = middle
                }
            }
            try emit(&block, at: high, value, ramp: 0, .hold)
            shown = value
            low = high
        }
    }

    private mutating func emit(_ block: inout Block, at frame: Int64, _ value: Double, ramp: Int64,
                               _ reason: AutomationRampEvent.Reason) throws(AutomationRenderRefusal) {
        guard block.events.count < Self.maximumEvents else { throw .tooManyEvents(limit: Self.maximumEvents) }
        block.events.append(AutomationRampEvent(frame: frame, offset: Int(frame - block.start), value: value,
                                                rampFrames: ramp, reason: reason))
        host = AutomationHostRamp(start: host?.value(at: frame) ?? value, startFrame: frame, target: value,
                                  end: frame + ramp)
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

    /// The value the arbiter shows at `frame`'s position, from its state at `holdFrom`. Every frame before the
    /// next advance point lies before the knot, block end or loop end that bounds the advance.
    func value(at frame: Int64) throws(AutomationRenderRefusal) -> Double? {
        var probe = held
        let ticks = pass.exactTicks(atFrame: frame).position
        do {
            return try probe.advance(to: max(ticks, probe.position ?? ticks)).value
        } catch {
            throw .automation(error)
        }
    }
}
