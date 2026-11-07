/// Why a controller is told a position. This is an INTERNAL origin marker (issue #88: origin markers stay internal
/// unless the protocol supports metadata): nothing serialises it, so it is deliberately not `Codable`.
enum ControlFeedbackReason: Hashable, Sendable, CaseIterable {
    /// The host applied a different value than the controller asked for (ceiling, range or step snap).
    case clamp
    /// A scene or recall changed the host value.
    case scene
    /// Automation arbitration produced a new value.
    case automation
    /// The caller re-planned, for example the bindings `due(at:)` listed, or a binding after `forget`.
    case refresh
    /// A touch ended and the host's newest position is now sent. Only `ControlFeedbackPlanner.release` emits it.
    case release
}

/// One neutral correction: the control bound by `binding` should show `position`. It carries no bytes, port or
/// protocol detail; encoding it for a device belongs to a later layer. The only initializer validates and the position
/// is stored privately, so a message always carries a finite position in 0...1 and cannot be forged out of range, not
/// even by an extension initializer.
struct ControlFeedbackMessage: Hashable, Sendable {
    let binding: BindingID
    let source: ControlSourceID
    let reason: ControlFeedbackReason
    private let storedPosition: Double

    /// The host value as `ControlBinding.position(of:over:curve:)` maps it: exact, never quantised to the grid.
    var position: Double { storedPosition }

    /// Refuses a position that is not finite (`nonFinite`) or not in 0...1 (`inputOutOfRange`).
    init(binding: BindingID, source: ControlSourceID, position: Double,
         reason: ControlFeedbackReason) throws(ControlBindingRefusal) {
        guard position.isFinite else { throw .nonFinite }
        guard (0...1).contains(position) else { throw .inputOutOfRange(position) }
        self.binding = binding
        self.source = source
        self.reason = reason
        storedPosition = position
    }
}

/// Why an answer was withheld. `echo`, `hold` and `coalesced` leave the binding owing a correction, which
/// `ControlFeedbackPlanner.due(at:)` lists once it may be sent; `unchanged` and `noValue` owe nothing.
enum ControlFeedbackSuppression: Hashable, Sendable, CaseIterable {
    /// The host value is what this controller itself just caused (inside the echo window).
    case echo
    /// The control is being touched: nothing is sent to it until release or timeout.
    case hold
    /// The controller already shows the desired position.
    case unchanged
    /// The binding's emit budget for this window is spent; the newest value goes out when a slot frees.
    case coalesced
    /// Automation has no value yet; nothing is sent and nothing is tracked.
    case noValue
}

/// The planner's answer for one binding.
enum ControlFeedbackResult: Hashable, Sendable {
    case message(ControlFeedbackMessage)
    case suppressed(ControlFeedbackSuppression)
    /// The binding cannot be answered (missing target or value, non-finite value, non-live target, undefined curve...).
    /// Nothing is guessed and no track is created.
    case refused(ControlBindingRefusal)
    /// The planner already tracks `capacity` bindings and this one is new. Tracked bindings are never evicted.
    case tableFull(capacity: Int)
}

/// One binding and what the planner answered for it.
struct ControlFeedbackOutcome: Hashable, Sendable {
    let binding: BindingID
    let result: ControlFeedbackResult
}

/// How `ControlFeedbackPlanner.receive` classified one controller input.
enum ControlFeedbackInbound: Hashable, Sendable {
    /// The controller repeats a position it was just sent: not an intent, so the caller must not act on it.
    case echo
    /// A genuine controller move: the caller may turn it into an intent.
    case move
    case refused(ControlBindingRefusal)
    case tableFull(capacity: Int)
}

/// A planner call or policy that cannot be accepted. Every case leaves the planner (or the value being built)
/// unchanged. Problems of one binding are not thrown: they come back as `ControlFeedbackResult.refused`, so one bad
/// binding refuses only itself.
enum ControlFeedbackRefusal: Error, Hashable, Sendable {
    case invalidBindingCapacity(Int)
    case invalidHoldCapacity(Int)
    case invalidWindow(UInt64)
    case invalidHoldTimeout(UInt64)
    case invalidEmitBudget(Int)
    /// `now` is below the last tick the planner saw. Time only moves forward; equal ticks are allowed.
    case tickRegressed(last: UInt64, now: UInt64)
    /// `plan` cannot be asked for `.release`; only `release` produces that reason.
    case reasonNotPlannable(ControlFeedbackReason)
    case tooManyBindings(Int)
    /// One `BindingID` appeared twice in a call; the smallest such ID is reported.
    case duplicateBinding(BindingID)
    case holdTableFull(capacity: Int)
}

/// The bounds a planner runs under. The only initializer validates and the values are stored privately, so a planner
/// cannot be built unbounded, not even by an extension initializer.
///
/// `windowTicks` is ONE knob for two windows that share a length: how long an echo entry stays live, and the window in
/// which a binding may emit at most `emitBudget` messages (a binding emits at most `emitBudget` messages in any
/// `windowTicks + 1` consecutive ticks). A table or per-call list never exceeds `maximumCapacity`, which is
/// `ControlHostTruth.maximumValues`.
struct ControlFeedbackPolicy: Hashable, Sendable {
    static let maximumCapacity = ControlHostTruth.maximumValues
    static let maximumTicks: UInt64 = 3_600_000
    static let maximumEmitBudget = ControlFeedbackEcho.depth

    private let storedBindingCapacity: Int
    private let storedHoldCapacity: Int
    private let storedWindowTicks: UInt64
    private let storedHoldTimeoutTicks: UInt64
    private let storedEmitBudget: Int

    var bindingCapacity: Int { storedBindingCapacity }
    var holdCapacity: Int { storedHoldCapacity }
    var windowTicks: UInt64 { storedWindowTicks }
    var holdTimeoutTicks: UInt64 { storedHoldTimeoutTicks }
    var emitBudget: Int { storedEmitBudget }

    /// Checks the arguments in declaration order; the first invalid one is reported.
    init(bindingCapacity: Int, holdCapacity: Int, windowTicks: UInt64, holdTimeoutTicks: UInt64,
         emitBudget: Int) throws(ControlFeedbackRefusal) {
        guard (1...Self.maximumCapacity).contains(bindingCapacity) else {
            throw .invalidBindingCapacity(bindingCapacity)
        }
        guard (1...Self.maximumCapacity).contains(holdCapacity) else { throw .invalidHoldCapacity(holdCapacity) }
        guard (1...Self.maximumTicks).contains(windowTicks) else { throw .invalidWindow(windowTicks) }
        guard (1...Self.maximumTicks).contains(holdTimeoutTicks) else { throw .invalidHoldTimeout(holdTimeoutTicks) }
        guard (1...Self.maximumEmitBudget).contains(emitBudget) else { throw .invalidEmitBudget(emitBudget) }
        storedBindingCapacity = bindingCapacity
        storedHoldCapacity = holdCapacity
        storedWindowTicks = windowTicks
        storedHoldTimeoutTicks = holdTimeoutTicks
        storedEmitBudget = emitBudget
    }
}
