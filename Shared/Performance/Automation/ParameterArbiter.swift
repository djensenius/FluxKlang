import Foundation

/// Arbitrates one automated parameter between its lane and live performer gestures (control
/// touches and moves already resolved through their bindings). A pure value type: time is the
/// explicit musical position (ticks) carried by every event, so the same events yield the same
/// values however they are split into render blocks and whatever the sample rate.
///
/// Every event first advances the arbiter to its position (finishing a latch whose breakpoint has
/// passed), then applies the event, then resolves the value at that position. Positions may not
/// move backwards except through `relocate`. A refused event leaves the arbiter unchanged.
///
/// Ownership rules:
/// - The highest-ranked touching source owns the value (`GestureTouch.outranks`). A touch that takes
///   ownership holds the current value until its first move, so a touch never jumps.
/// - When the owner releases, the next-ranked touching source takes over, again holding the value.
///   Releasing the last touch hands the value back according to the mode: `touch` resumes at once,
///   `latch` holds until the next breakpoint, `manual` holds indefinitely.
/// - Automation resumes from the held value through `resume`, never by jumping. Callers that keep
///   bindings in `catch` pickup should report host changes to the outranked bindings themselves.
/// - Transport is an explicit input. `transportStopped` ends touch and latch gestures and any latch,
///   glide or catch; the value holds until `transportStarted`, which resumes through `resume`. Read
///   and manual ownership are unchanged by stop. A locate (`relocate`) never ends a latch.
struct ParameterArbiter: Hashable, Sendable {
    static let maximumTouches = 16

    let lane: AutomationLane
    let resume: AutomationResume
    private(set) var mode: AutomationMode
    private(set) var owner: ParameterOwnership
    private(set) var value: Double?
    /// The last event's position, `nil` before the first event.
    private(set) var position: Double?
    /// Touching sources, highest-ranked first.
    private(set) var touches: [GestureTouch] = []
    private(set) var isPlaying: Bool
    /// Touches a transport stop or a switch to Read ended, oldest first, at most `maximumTouches`. The
    /// source's later move or release is ignored with the recorded reason until it touches again.
    private(set) var endedTouches: [EndedTouch] = []
    /// While catching, the position from which the curve has not yet been checked.
    private var catchSince: Double = 0

    init(lane: AutomationLane, mode: AutomationMode, resume: AutomationResume,
         playing: Bool = true) throws(AutomationRefusal) {
        if case .glide(let ticks) = resume, !(1...AutomationResume.maximumGlideTicks).contains(ticks) {
            throw .invalidGlide(ticks)
        }
        self.lane = lane
        self.resume = resume
        self.mode = mode
        isPlaying = playing
        owner = mode == .manual ? .manual : .automation
    }

    /// Moves the arbiter's clock forward without an input event.
    mutating func advance(to ticks: Double) throws(AutomationRefusal) -> ArbitrationResult {
        try transact(at: ticks) { _ throws(AutomationRefusal) in .applied }
    }

    mutating func touch(_ source: ControlSourceID, priority: Int,
                        at ticks: Double) throws(AutomationRefusal) -> ArbitrationResult {
        try transact(at: ticks) { arbiter throws(AutomationRefusal) in
            guard arbiter.mode != .read else { return .ignored(.readMode) }
            guard !arbiter.touches.contains(where: { $0.source == source }) else { throw .alreadyTouched(source) }
            guard arbiter.touches.count < Self.maximumTouches else { throw .tooManyTouches }
            arbiter.endedTouches.removeAll { $0.source == source }
            let touch = GestureTouch(source: source, priority: priority)
            let index = arbiter.touches.firstIndex { touch.outranks($0) } ?? arbiter.touches.count
            arbiter.touches.insert(touch, at: index)
            guard index == 0 else { return .ignored(.outranked(owner: arbiter.touches[0].source)) }
            arbiter.owner = .gesture(source)
            return .applied
        }
    }

    /// A touching source's new value, in the parameter's unit; admitted under the lane's rules.
    mutating func move(_ source: ControlSourceID, to newValue: Double,
                       at ticks: Double) throws(AutomationRefusal) -> ArbitrationResult {
        try transact(at: ticks) { arbiter throws(AutomationRefusal) in
            guard arbiter.mode != .read else { return .ignored(.readMode) }
            let admitted = try arbiter.lane.admit(newValue)
            guard arbiter.touches.contains(where: { $0.source == source }) else {
                return try arbiter.untouched(source)
            }
            let top = arbiter.touches[0].source
            guard top == source else { return .ignored(.outranked(owner: top)) }
            arbiter.value = admitted
            return .applied
        }
    }

    mutating func release(_ source: ControlSourceID, at ticks: Double) throws(AutomationRefusal) -> ArbitrationResult {
        try transact(at: ticks) { arbiter throws(AutomationRefusal) in
            guard arbiter.mode != .read else { return .ignored(.readMode) }
            guard let index = arbiter.touches.firstIndex(where: { $0.source == source }) else {
                return try arbiter.untouched(source)
            }
            arbiter.touches.remove(at: index)
            guard index == 0 else { return .applied }
            if let next = arbiter.touches.first {
                arbiter.owner = .gesture(next.source)
            } else {
                try arbiter.relinquish(at: ticks)
            }
            return .applied
        }
    }

    /// Switching to `read` ends every touch (a later lift is `.endedByModeChange`) and resumes
    /// automation from the held value; switching
    /// to `manual` suspends automation at the current value; switching between `touch` and `latch`
    /// keeps a touching owner, and a pending latch or manual hold resumes at once.
    mutating func setMode(_ newMode: AutomationMode, at ticks: Double) throws(AutomationRefusal) -> ArbitrationResult {
        try transact(at: ticks) { arbiter throws(AutomationRefusal) in
            guard newMode != arbiter.mode else { return .applied }
            arbiter.mode = newMode
            if newMode == .read { arbiter.endTouches(.endedByModeChange) }
            switch (newMode, arbiter.owner) {
            case (.read, .gesture), (.read, .latched), (.read, .manual),
                 (.touch, .latched), (.touch, .manual), (.latch, .manual):
                arbiter.beginResume(at: ticks)
            case (.manual, .gesture):
                break
            case (.manual, _):
                arbiter.owner = .manual
            default:
                break
            }
            return .applied
        }
    }

    /// A transport locate or jump, playing or stopped; the only event that may move backwards. The
    /// curve is re-evaluated at the new position. Held values do not jump: a latch keeps its value
    /// and now ends at the next breakpoint after the new position, a glide restarts from the current
    /// value there, a catch checks the curve from there; gestures and manual holds are kept.
    mutating func relocate(to ticks: Double) throws(AutomationRefusal) -> ArbitrationResult {
        guard ticks.isFinite else { throw .nonFinite }
        var next = self
        next.position = ticks
        switch next.owner {
        case .latched: next.owner = .latched(until: try lane.nextBreakpoint(after: ticks))
        case .gliding: next.owner = .gliding(from: value ?? 0, start: ticks)
        case .catching: next.catchSince = ticks
        case .automation, .gesture, .manual, .awaitingPlayback: break
        }
        try next.settle(at: ticks)
        self = next
        return ArbitrationResult(outcome: .applied, owner: owner, value: value)
    }

    /// Playback stops. In touch and latch modes every touch ends; any gesture, latch, glide or catch
    /// holds its value until playback restarts. A glide or catch freezes at its current value whatever
    /// the mode, including one left running by a switch to Read. Steady Read and manual are unchanged.
    mutating func transportStopped(at ticks: Double) throws(AutomationRefusal) -> ArbitrationResult {
        try transact(at: ticks) { arbiter throws(AutomationRefusal) in
            arbiter.isPlaying = false
            if arbiter.mode == .touch || arbiter.mode == .latch { arbiter.endTouches(.endedByTransport) }
            switch arbiter.owner {
            case .latched, .gliding, .catching: arbiter.beginResume(at: ticks)
            case .gesture where arbiter.touches.isEmpty: arbiter.beginResume(at: ticks)
            case .automation, .gesture, .manual, .awaitingPlayback: break
            }
            return .applied
        }
    }

    /// Playback (re)starts; a value held by a stop returns to automation through `resume` from here.
    mutating func transportStarted(at ticks: Double) throws(AutomationRefusal) -> ArbitrationResult {
        try transact(at: ticks) { arbiter throws(AutomationRefusal) in
            arbiter.isPlaying = true
            if arbiter.owner == .awaitingPlayback { arbiter.beginResume(at: ticks) }
            return .applied
        }
    }

    private mutating func transact(
        at ticks: Double, _ event: (inout Self) throws(AutomationRefusal) -> ArbitrationOutcome
    ) throws(AutomationRefusal) -> ArbitrationResult {
        guard ticks.isFinite else { throw .nonFinite }
        if let position, ticks < position { throw .timeRegressed(from: position, to: ticks) }
        var next = self
        if case .latched(let until?) = next.owner, Double(until) <= ticks {
            next.beginResume(at: Double(until))
        }
        try next.settle(at: ticks)
        let outcome = try event(&next)
        try next.settle(at: ticks)
        next.position = ticks
        self = next
        return ArbitrationResult(outcome: outcome, owner: owner, value: value)
    }

    /// A move or release from a source that is not touching: the lift of a touch a stop ended is
    /// ignored, anything else is refused.
    private func untouched(_ source: ControlSourceID) throws(AutomationRefusal) -> ArbitrationOutcome {
        guard let ended = endedTouches.first(where: { $0.source == source }) else { throw .notTouched(source) }
        return .ignored(ended.reason)
    }

    /// Ends every touch, recording each source. A touching source has no record (touching clears it),
    /// so records stay unique.
    private mutating func endTouches(_ reason: ArbitrationIgnoreReason) {
        endedTouches.append(contentsOf: touches.map { EndedTouch(source: $0.source, reason: reason) })
        endedTouches.removeFirst(max(0, endedTouches.count - Self.maximumTouches))
        touches.removeAll()
    }

    /// The last touch released: hand the value back according to the mode.
    private mutating func relinquish(at ticks: Double) throws(AutomationRefusal) {
        switch mode {
        case .touch, .read: beginResume(at: ticks)
        case .latch where isPlaying: owner = .latched(until: try lane.nextBreakpoint(after: ticks))
        case .latch: beginResume(at: ticks)
        case .manual: owner = .manual
        }
    }

    private mutating func beginResume(at ticks: Double) {
        guard let value, !lane.breakpoints.isEmpty else {
            owner = .automation
            return
        }
        guard isPlaying else {
            owner = .awaitingPlayback
            return
        }
        switch resume {
        case .glide: owner = .gliding(from: value, start: ticks)
        case .catch:
            owner = .catching
            catchSince = ticks
        }
    }

    /// Resolves the value at `ticks` for the current owner, finishing a glide or catch once done.
    private mutating func settle(at ticks: Double) throws(AutomationRefusal) {
        switch owner {
        case .automation:
            if let curve = try lane.value(at: ticks) { value = curve }
        case .gesture, .latched, .manual, .awaitingPlayback:
            break
        case .gliding(let from, let start):
            guard case .glide(let duration) = resume, let curve = try lane.value(at: ticks) else { return }
            let progress = (ticks - start) / Double(duration)
            guard progress < 1 else {
                owner = .automation
                value = curve
                return
            }
            let mixed = AutomationLane.blend(from, curve, at: progress)
            let bounded = min(max(mixed, lane.range.lowerBound), lane.range.upperBound)
            value = lane.isStepped ? bounded.rounded() : bounded
        case .catching:
            guard let held = value else { return }
            if try lane.reaches(held, from: catchSince, through: ticks) {
                owner = .automation
                value = try lane.value(at: ticks)
            }
            catchSince = ticks
        }
    }
}
