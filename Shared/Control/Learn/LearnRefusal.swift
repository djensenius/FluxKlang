import Foundation

/// The phase of a Learn session without its payload, for refusals and display.
enum LearnPhaseKind: String, Codable, Hashable, Sendable, CaseIterable {
    case idle, listening, awaitingReview, committed, cancelled, blocked
}

/// Why a Learn call was refused. A refusal never changes the session.
enum LearnRefusal: Error, Hashable, Sendable {
    /// A session is listening or awaiting review; only one runs at a time.
    case sessionInProgress(LearnPhaseKind)
    case notListening(LearnPhaseKind)
    case notAwaitingReview(LearnPhaseKind)
    /// Cancel needs a listening or reviewing session.
    case noActiveSession(LearnPhaseKind)
    /// Timeouts must lie in `1...LearnSession.maximumTimeoutTicks`.
    case invalidTimeout(UInt64)
    /// Caller-supplied ticks are monotonic; `now` is earlier than the last tick seen.
    case tickRegressed(last: UInt64, now: UInt64)
    /// `now` precedes the session's start tick; unreachable unless an invariant is broken.
    case tickBeforeStart(start: UInt64, now: UInt64)
    case tooManyExcluded(Int)
    case tooManyPresentDevices(Int)
    case tooManyBindings(Int)
    /// Two existing bindings share one ID, so conflicts cannot be named unambiguously.
    case duplicateBinding(BindingID)
    /// The caller classified the heard control with an invalid encoder profile.
    case invalidProfile(EncoderDecodeError)
    case targetMismatch(expected: ParameterID, found: ParameterID)
    /// The target became ineligible between hearing and confirmation.
    case targetBlocked(LearnBlockReason)
    /// The proposed binding no longer validates against the current descriptor.
    case invalidBinding(ControlBindingRefusal)
    /// Confirm without replacement while bindings conflict; lists every conflict.
    case conflicted([LearnConflict])
    /// A replacement set that is not exactly the current conflict set (both sorted).
    case staleReplacement(expected: [BindingID], found: [BindingID])
    /// The current descriptor or complete conflicting bindings differ from the explicit review.
    case staleReview
    /// The new binding's ID belongs to an existing binding that is not being replaced.
    case bindingIDInUse(BindingID)
}

/// Why a heard control was not recorded. The session keeps listening.
enum LearnIgnoreReason: Error, Hashable, Sendable {
    /// The device is not in the caller's presence set.
    case deviceAbsent(DeviceID)
    /// The default binding for this control does not validate against the target.
    case incompatible(ControlBindingRefusal)
    /// A relative control on a target whose range yields no positive, finite default step.
    case noUsableStep
    /// The default fields failed record validation.
    case unconstructible
}

/// The result of one heard control while listening.
enum LearnHearing: Hashable, Sendable {
    case recorded(LearnProposal)
    case ignored(LearnIgnoreReason)
    /// The listening deadline had passed; the session is now cancelled.
    case timedOut
}
