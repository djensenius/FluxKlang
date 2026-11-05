import Foundation

/// Who may write an automated parameter, chosen per lane by the performer.
enum AutomationMode: String, Hashable, Sendable, CaseIterable {
    /// Automation owns the value; gestures are ignored.
    case read
    /// A touching gesture owns the value; when the last one releases, automation resumes.
    case touch
    /// A touching gesture owns the value; after the last release its value holds until the lane's next
    /// breakpoint after the release (or a transport stop or mode change), then automation resumes.
    case latch
    /// Automation is suspended; gestures own the value and it holds after release.
    case manual
}

/// How automation takes a parameter back from a held value without a jump.
enum AutomationResume: Hashable, Sendable {
    /// Crossfades linearly from the held value to the live curve over `ticks`, a musical duration.
    case glide(ticks: Int64)
    /// Holds until the live curve reaches or crosses the held value, like a `catch` control pickup.
    case `catch`

    static let maximumGlideTicks = MusicalTime.ticksPerQuarter * 64
}

/// Who currently writes the parameter.
enum ParameterOwnership: Hashable, Sendable {
    case automation
    case gesture(ControlSourceID)
    /// Latch mode after release: the gesture's value holds until the breakpoint at `until`;
    /// `nil` when the lane has no later breakpoint.
    case latched(until: Int64?)
    /// Resuming: crossfading from `from` toward the curve, starting at position `start`.
    case gliding(from: Double, start: Double)
    /// Resuming: holding until the curve reaches or crosses the held value.
    case catching
    /// Manual mode without a touching gesture: the last value holds.
    case manual
    /// Transport stopped: the held value stays until playback restarts, then automation returns
    /// through the arbiter's `AutomationResume`.
    case awaitingPlayback
}

enum ArbitrationIgnoreReason: Hashable, Sendable {
    /// The lane is in read mode; gestures do not register.
    case readMode
    /// The source registered its touch or move, but a higher-ranked touching source owns the value.
    case outranked(owner: ControlSourceID)
    /// A transport stop already ended this source's touch; its move or release is acknowledged but has no
    /// effect until it touches again.
    case endedByTransport
    /// A switch to Read already ended this source's touch; its move or release is acknowledged but has no
    /// effect until it touches again.
    case endedByModeChange
}

/// A touch that a transport stop or mode change ended, kept so the source's lift is not refused.
struct EndedTouch: Hashable, Sendable {
    let source: ControlSourceID
    let reason: ArbitrationIgnoreReason
}

enum ArbitrationOutcome: Hashable, Sendable {
    case applied
    case ignored(ArbitrationIgnoreReason)
}

/// The arbiter's answer to one event. `value` is what the parameter (and its controller feedback)
/// should show at the event's position; it is `nil` until a breakpoint or a gesture defines one.
struct ArbitrationResult: Hashable, Sendable {
    let outcome: ArbitrationOutcome
    let owner: ParameterOwnership
    let value: Double?
}

/// One touching source. Rank depends only on the explicit priority, then the stable source ID,
/// never on arrival order.
struct GestureTouch: Hashable, Sendable {
    let source: ControlSourceID
    let priority: Int

    func outranks(_ other: GestureTouch) -> Bool {
        priority != other.priority ? priority > other.priority : source < other.source
    }
}
