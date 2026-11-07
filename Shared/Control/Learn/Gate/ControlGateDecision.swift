/// Why the gate held a sample instead of delivering or hearing it. Held samples are dropped: the gate keeps no queue
/// and replays nothing when learn ends.
enum ControlHoldReason: Hashable, Sendable {
    /// A proposal is under review; review ends only by confirm or cancel, so every sample is held meanwhile.
    case awaitingReview
    /// The session is listening but the caller has not chosen an encoder profile; the gate never infers one and does
    /// not call `hear`, so the session is unchanged and its deadline is not checked: only `LearnSession.advance`
    /// times it out while no profile is chosen.
    case profileNotChosen
    /// The listening deadline had passed. The sample is swallowed and the session is now cancelled.
    case timedOut
    /// The chosen (valid) profile cannot decode the sample's raw value; `hear` is not called, so the session is
    /// unchanged and, as for `profileNotChosen`, its deadline is not checked.
    case rawOutsideProfile(EncoderDecodeError)
    /// `hear` ignored the control; the session keeps listening.
    case ignored(LearnIgnoreReason)
    /// `hear` refused; the session is unchanged.
    case heardRefused(LearnRefusal)
}

/// What the gate did with one sample. `.deliver` exists only for a session that was not active when the sample
/// arrived, and its payload can be built only by the gate (`ControlGateDelivery`), so a held or heard sample cannot be
/// turned into a deliverable one.
enum ControlGateDecision: Equatable, Sendable {
    case deliver(ControlGateDelivery)
    /// The control was recorded as a proposal by `LearnSession.hear`; it is not a performance event.
    case hear(LearnHeardControl)
    case held(ControlHoldReason)
}
