/// A pure planner from host truth to neutral controller-correction messages, with echo suppression, touch hold and
/// loop-free convergence. It emits values only (no bytes, ports or I/O) and never reads or mutates a `LearnSession`,
/// a binding store or a command: the caller owns the bindings, the host truth and the clock.
///
/// Level-triggered, no stored messages. Every emission is re-derived from the bindings and host truth passed in that
/// call, so a held, echo-suppressed or coalesced binding always converges to the NEWEST host value and a stale message
/// cannot exist. Per tracked binding the planner keeps only the step the controller is believed to show, whether a
/// correction is still owed, the first tick it may be retried and an echo ledger; `due(at:)` lists the bindings the
/// caller should re-plan. This replaces storing "the newest position" while a control is held, and is the one
/// deliberate difference from the lane text.
///
/// Loop freedom: feedback derives from host truth only; it is sent only when the desired grid step differs from the
/// one shown; a controller's own move and the feedback it was sent are recognised as echoes inside
/// `policy.windowTicks`; and a binding emits at most `policy.emitBudget` messages in any `windowTicks + 1` consecutive
/// ticks, coalescing to the newest value (a deferred correction is never dropped).
///
/// Bounds and ordering: at most `policy.bindingCapacity` tracked bindings (a full table refuses only a NEW binding),
/// at most `policy.holdCapacity` live holds (never evicted), at most 4096 bindings per call. Bindings are processed in
/// ascending `BindingID` order and outcomes come back in input order, so no result depends on input order or on
/// dictionary iteration order. Every call that throws leaves the planner unchanged (each throw precedes the first
/// mutation); time must not regress.
///
/// Ledger bound: each tracked binding keeps two rings of at most `ControlFeedbackEcho.depth` (8) entries, so the
/// planner holds at most `policy.bindingCapacity * 16` ledger entries (65,536 at the 4096 maximum). The emit-budget
/// bound holds only while a track persists: `forget(_:)` drops the track and its ledger, and the next plan is answered
/// at once.
///
/// What a caller must do: call `forget(_:)` for every binding it removes (a track otherwise keeps its table slot, and
/// a full table refuses NEW bindings), and make an encoder that reads a position back round it exactly like
/// `ControlFeedbackEcho.step(of:grid:)` on the `EncoderProfile.feedbackGrid` steps, or an echo will not match its
/// message and is taken for a move. It must also re-plan every binding that `due(at:)` lists, and each binding again
/// after its writes are applied: a held, coalesced or contradicted correction (a refused report can contradict too) is
/// sent only by such a re-plan, and while host truth stays unavailable the re-plan is refused and the binding stays
/// listed.
struct ControlFeedbackPlanner: Hashable, Sendable {
    /// What the planner knows about one tracked binding.
    private struct Track: Hashable, Sendable {
        /// The control's position grid and source when the track began; a change of either starts a fresh track.
        let grid: Int
        let source: ControlSourceID
        /// The step the controller is believed to show, or `nil` while unknown.
        var shown: Int?
        /// Whether a correction is still owed (held, echo-suppressed, coalesced, or contradicted by a controller report
        /// that disagrees with the shown step, whether the host judged that report or refused it).
        var deferred = false
        /// The first tick at which an owed correction may be sent.
        var retryAt: UInt64 = 0
        var echo = ControlFeedbackEcho()
    }

    /// A viable binding's desired position and the step it lands on.
    private struct Candidate {
        let position: Double
        let step: Int
        let grid: Int
    }

    /// The answer for one binding and the track state to store with it.
    private struct Decision {
        let result: ControlFeedbackResult
        let track: Track
    }

    /// Finds a binding's descriptor and the value to answer with. A `nil` value means "none yet" (automation only).
    private typealias Resolver =
        (ControlBinding) throws(ControlBindingRefusal) -> (ParameterDescriptor, ParameterValue?)

    let policy: ControlFeedbackPolicy
    private(set) var lastTick: UInt64 = 0
    private(set) var holds: ControlTouchHold
    private var tracks: [BindingID: Track] = [:]

    init(policy: ControlFeedbackPolicy) {
        self.policy = policy
        holds = ControlTouchHold(policy: policy)
    }

    /// How many bindings are tracked (never more than `policy.bindingCapacity`).
    var trackedCount: Int { tracks.count }

    func isTracked(_ binding: BindingID) -> Bool { tracks[binding] != nil }

    /// The grid step the controller is believed to show for a tracked binding, or `nil`.
    func shownStep(of binding: BindingID) -> Int? { tracks[binding]?.shown }

    /// Answers every binding from host truth: a message when the controller must be told a new position, otherwise
    /// why not. A host value that differs from the controller's move (ceiling, range, step snap) is answered at the
    /// applied position (call this after the host applied the write); a scene or recall is answered at the new
    /// position. `.refresh` is only a label and forces nothing: use `forget` to make the controller be told again.
    /// Reason `.release` is refused. Outcomes are in input order.
    mutating func plan(_ bindings: [ControlBinding], truth: ControlHostTruth, reason: ControlFeedbackReason,
                       now: UInt64) throws(ControlFeedbackRefusal) -> [ControlFeedbackOutcome] {
        try requireTick(now)
        guard reason != .release else { throw .reasonNotPlannable(reason) }
        let order = try Self.processingOrder(bindings)
        lastTick = now
        return evaluate(bindings, order: order, reason: reason, now: now, resolve: Self.hostResolver(truth))
    }

    /// Answers bindings of `target` at an automation arbitration's value (reason `.automation`). A `nil` value emits
    /// nothing and tracks nothing. Deviation from "host truth only": the VALUE is `result.value` (what the arbiter
    /// says the parameter shows); the descriptor still comes from `truth`, and the arbitration outcome and owner are
    /// ignored. A binding of another target is refused with `descriptorMismatch`.
    mutating func plan(automation result: ArbitrationResult, target: ParameterID, bindings: [ControlBinding],
                       truth: ControlHostTruth,
                       now: UInt64) throws(ControlFeedbackRefusal) -> [ControlFeedbackOutcome] {
        try requireTick(now)
        let order = try Self.processingOrder(bindings)
        lastTick = now
        let resolve = Self.automationResolver(result, target: target, truth: truth)
        return evaluate(bindings, order: order, reason: .automation, now: now, resolve: resolve)
    }

    /// Classifies one decoded controller input. An absolute position equal to one the controller was just sent is an
    /// `.echo`, which the caller must not turn into an intent. Normally the planner already believes the controller
    /// shows that step and nothing changes. If it believes another step (the user really moved onto a value just sent,
    /// or an older message arrives late), the report contradicts the belief: the shown step becomes unknown and the
    /// correction is owed at once, so `due(at:)` lists the binding and the next plan re-sends host truth (the emit
    /// budget still applies; the echo of that message equals the shown step and changes nothing). Anything else valid
    /// is a `.move`, which is remembered so the host's equal write is not echoed back to the control that made it. A
    /// relative input is always a `.move` and records nothing. Refusals mirror
    /// `ControlBinding.operation(for:current:descriptor:)`. A refused report is never an intent and never creates a
    /// track, but a valid absolute one that contradicts an existing track still makes the shown step unknown and owes
    /// the correction at once (the host may be unavailable only for now): the correction goes out at the first plan
    /// that can answer, with the ledger and the emit budget kept.
    mutating func receive(_ input: ControlInput, for binding: ControlBinding, truth: ControlHostTruth,
                          now: UInt64) throws(ControlFeedbackRefusal) -> ControlFeedbackInbound {
        try requireTick(now)
        lastTick = now
        do throws(ControlBindingRefusal) {
            let (descriptor, current) = try truth.target(binding.target)
            _ = try binding.validate(against: descriptor)
            guard current.value.isFinite else { throw .nonFinite }
            guard current.unit == descriptor.unit else {
                throw .unitMismatch(expected: descriptor.unit, found: current.unit)
            }
            switch input {
            case .relative:
                guard binding.profile.isRelative else { throw .inputMismatch }
                return .move
            case .absolute(let normalized):
                guard !binding.profile.isRelative else { throw .inputMismatch }
                return try receiveAbsolute(normalized, for: binding, now: now)
            }
        } catch {
            noteRefusedReport(input, for: binding, now: now)
            return .refused(error)
        }
    }

    /// Starts a touch on `source`: nothing is sent to it until `release` or the timeout. Returns `false` and changes
    /// nothing but the clock when the source is already held (the timeout is not renewed). A NEW source while
    /// `holdCapacity` holds are live throws `holdTableFull`; no hold is ever evicted.
    @discardableResult
    mutating func touch(_ source: ControlSourceID, now: UInt64) throws(ControlFeedbackRefusal) -> Bool {
        try requireTick(now)
        let started = try holds.touch(source, now: now)
        lastTick = now
        return started
    }

    /// Ends a live touch on `source` and answers the supplied bindings of that source (reason `.release`): at most one
    /// message per binding, none when the controller already shows the position. An absent hold returns `[]` and
    /// changes nothing but the clock, so a duplicate release is idempotent; an expired hold is dropped from the table
    /// and returns `[]` too, leaving `due(at:)` to list whatever correction it still owed. Bindings of other sources
    /// get no outcome.
    mutating func release(_ source: ControlSourceID, bindings: [ControlBinding], truth: ControlHostTruth,
                          now: UInt64) throws(ControlFeedbackRefusal) -> [ControlFeedbackOutcome] {
        try requireTick(now)
        let order = try Self.processingOrder(bindings)
        lastTick = now
        guard holds.release(source, at: now) else { return [] }
        let owned = order.filter { bindings[$0].source == source }
        return evaluate(bindings, order: owned, reason: .release, now: now, resolve: Self.hostResolver(truth))
    }

    /// Drops a binding's track and ledger so the controller is told its position again at the next plan. Idempotent;
    /// never touches a hold or the clock. Callers must call it for every binding they remove, or the track keeps its
    /// table slot; it also resets that binding's emit budget, which holds only while a track persists.
    mutating func forget(_ binding: BindingID) {
        tracks[binding] = nil
    }

    /// The bindings that owe a correction and may send it now (a held, echo-suppressed or coalesced binding, or one
    /// whose valid move the host refused, whose retry tick has come and whose source is not held), ascending by
    /// `BindingID`. Re-plan them with the current truth; reason `.refresh` is conventional. Read-only.
    func due(at now: UInt64) throws(ControlFeedbackRefusal) -> [BindingID] {
        try requireTick(now)
        let ready = tracks.filter { entry in
            entry.value.deferred && entry.value.retryAt <= now && !holds.isHeld(entry.value.source, at: now)
        }
        return ready.keys.sorted()
    }

    private func requireTick(_ now: UInt64) throws(ControlFeedbackRefusal) {
        guard now >= lastTick else { throw .tickRegressed(last: lastTick, now: now) }
    }

    /// Indices of `bindings` in ascending `BindingID` order. Refuses more than 4096 bindings and a repeated ID (the
    /// smallest repeated one is reported).
    private static func processingOrder(_ bindings: [ControlBinding]) throws(ControlFeedbackRefusal) -> [Int] {
        guard bindings.count <= ControlFeedbackPolicy.maximumCapacity else { throw .tooManyBindings(bindings.count) }
        let order = bindings.indices.sorted { bindings[$0].id < bindings[$1].id }
        let ids = order.map { bindings[$0].id }
        for index in ids.indices.dropFirst() where ids[index] == ids[index - 1] { throw .duplicateBinding(ids[index]) }
        return order
    }

    private static func hostResolver(_ truth: ControlHostTruth) -> Resolver {
        { binding throws(ControlBindingRefusal) in
            let (descriptor, value) = try truth.target(binding.target)
            return (descriptor, value)
        }
    }

    private static func automationResolver(_ result: ArbitrationResult, target: ParameterID,
                                           truth: ControlHostTruth) -> Resolver {
        { _ throws(ControlBindingRefusal) in
            guard let descriptor = truth.catalog[target] else { throw .targetMissing(target) }
            return (descriptor, result.value.map { ParameterValue(value: $0, unit: descriptor.unit) })
        }
    }

    /// Answers the bindings at `order` (ascending ID) and returns the outcomes in input order.
    private mutating func evaluate(_ bindings: [ControlBinding], order: [Int], reason: ControlFeedbackReason,
                                   now: UInt64, resolve: Resolver) -> [ControlFeedbackOutcome] {
        var answered: [(index: Int, outcome: ControlFeedbackOutcome)] = []
        for index in order {
            let binding = bindings[index]
            let result = answer(for: binding, reason: reason, now: now, resolve: resolve)
            answered.append((index, ControlFeedbackOutcome(binding: binding.id, result: result)))
        }
        return answered.sorted { $0.index < $1.index }.map { $0.outcome }
    }

    private mutating func answer(for binding: ControlBinding, reason: ControlFeedbackReason, now: UInt64,
                                 resolve: Resolver) -> ControlFeedbackResult {
        do throws(ControlBindingRefusal) {
            guard let candidate = try Self.candidate(for: binding, resolve: resolve) else {
                return .suppressed(.noValue)
            }
            guard let track = admit(binding, grid: candidate.grid) else {
                return .tableFull(capacity: policy.bindingCapacity)
            }
            let decision = try decide(track, candidate: candidate, binding: binding, reason: reason, now: now)
            tracks[binding.id] = decision.track
            return decision.result
        } catch {
            return .refused(error)
        }
    }

    /// The viability pipeline shared by every answer: descriptor and value, `validate(against:)`, a finite value of the
    /// descriptor's unit, then the exact position and its grid step. Any refusal here means no track is touched.
    private static func candidate(for binding: ControlBinding,
                                  resolve: Resolver) throws(ControlBindingRefusal) -> Candidate? {
        let (descriptor, value) = try resolve(binding)
        let range = try binding.validate(against: descriptor)
        guard let value else { return nil }
        guard value.value.isFinite else { throw .nonFinite }
        guard value.unit == descriptor.unit else { throw .unitMismatch(expected: descriptor.unit, found: value.unit) }
        let position = try ControlBinding.position(of: value.value, over: range, curve: descriptor.curve)
        let grid = binding.profile.feedbackGrid
        // `position(of:over:curve:)` never returns a position outside 0...1, so the guard cannot fail; it stays so no
        // position is ever guessed.
        guard let step = ControlFeedbackEcho.step(of: position, grid: grid) else { throw .nonFinite }
        return Candidate(position: position, step: step, grid: grid)
    }

    /// The binding's track: the existing one (fresh when its source or grid changed, since what the controller shows is
    /// then unknown), or a new one while the table has room, else `nil`. Nothing is stored here.
    private func admit(_ binding: ControlBinding, grid: Int) -> Track? {
        if let existing = tracks[binding.id], existing.grid == grid, existing.source == binding.source {
            return existing
        }
        guard tracks[binding.id] != nil || tracks.count < policy.bindingCapacity else { return nil }
        return Track(grid: grid, source: binding.source)
    }

    /// Decides one viable binding: hold, then echo, then unchanged, then the emit budget, then a message. A throw can
    /// only come from building the message, before any state is stored.
    private func decide(_ start: Track, candidate: Candidate, binding: ControlBinding, reason: ControlFeedbackReason,
                        now: UInt64) throws(ControlBindingRefusal) -> Decision {
        var track = start
        let desired = candidate.step
        let owed = track.shown != desired
        if holds.isHeld(binding.source, at: now) {
            track.deferred = owed
            track.retryAt = now
            return Decision(result: .suppressed(.hold), track: track)
        }
        if let deadline = track.echo.causedDeadline(of: desired, at: now) {
            track.deferred = owed
            track.retryAt = ControlFeedbackEcho.following(deadline)
            return Decision(result: .suppressed(.echo), track: track)
        }
        guard owed else {
            track.deferred = false
            return Decision(result: .suppressed(.unchanged), track: track)
        }
        if let retry = track.echo.sendableAt(budget: policy.emitBudget, now: now) {
            track.deferred = true
            track.retryAt = retry
            return Decision(result: .suppressed(.coalesced), track: track)
        }
        let message = try ControlFeedbackMessage(binding: binding.id, source: binding.source,
                                                 position: candidate.position, reason: reason)
        track.echo.recordSent(step: desired, now: now, window: policy.windowTicks)
        track.shown = desired
        track.deferred = false
        return Decision(result: .message(message), track: track)
    }

    /// The absolute half of `receive`: validates the position, then classifies echo or move. An echo of a step the
    /// planner does not believe is shown is stored as "shown unknown, correction owed now": dropping it silently would
    /// leave the planner believing a position the controller no longer shows, and the final correction would be lost.
    /// A fresh track has an empty ledger, so only an existing track can reach the store.
    private mutating func receiveAbsolute(_ normalized: Double, for binding: ControlBinding,
                                          now: UInt64) throws(ControlBindingRefusal) -> ControlFeedbackInbound {
        guard normalized.isFinite else { throw .nonFinite }
        guard (0...1).contains(normalized) else { throw .inputOutOfRange(normalized) }
        let grid = binding.profile.feedbackGrid
        guard let step = ControlFeedbackEcho.step(of: normalized, grid: grid) else { throw .nonFinite }
        guard var track = admit(binding, grid: grid) else { return .tableFull(capacity: policy.bindingCapacity) }
        if track.echo.isSent(step: step, at: now) {
            if track.shown != step {
                track.shown = nil
                track.deferred = true
                track.retryAt = now
                tracks[binding.id] = track
            }
            return .echo
        }
        track.shown = step
        track.deferred = false
        track.echo.recordCaused(step: step, now: now, window: policy.windowTicks)
        tracks[binding.id] = track
        return .move
    }

    /// The part of a refused `receive` that still matters. The host refusing a report (a target or value that is
    /// unavailable for now, say) does not undo that the controller moved: a valid absolute report that contradicts an
    /// EXISTING track makes the shown step unknown and owes the correction at once, so the first plan that can answer
    /// re-sends host truth. It never creates a track, and it leaves a track of another source or grid alone (its
    /// `shown` is on another grid; the next plan starts it afresh). The ledger is kept, so echo suppression and the
    /// emit budget stand, and no `caused` entry is recorded because the host did not take the move.
    private mutating func noteRefusedReport(_ input: ControlInput, for binding: ControlBinding, now: UInt64) {
        guard case .absolute(let normalized) = input, !binding.profile.isRelative else { return }
        let grid = binding.profile.feedbackGrid
        guard let step = ControlFeedbackEcho.step(of: normalized, grid: grid) else { return }
        guard var track = tracks[binding.id], track.grid == grid, track.source == binding.source,
              track.shown != step else { return }
        track.shown = nil
        track.deferred = true
        track.retryAt = now
        tracks[binding.id] = track
    }
}
