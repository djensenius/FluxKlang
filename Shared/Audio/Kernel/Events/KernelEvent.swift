// #64 kernel event vocabulary: fixed-size, bitwise-copyable events with a §6.5 lane rank and an event class.
// Reference model; not RT-certified.

/// Delivery lane for events that share a frame; lower raw values are delivered first (§6.5 ranks).
/// `Comparable` follows `rawValue`. Reference model; not RT-certified.
enum EventLane: UInt8, Sendable, BitwiseCopyable, Comparable {
    case release = 0, transport, state, content

    static func < (lhs: EventLane, rhs: EventLane) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// A kernel event's payload. Every case is fixed-size and trivially copyable.
/// Reference model; not RT-certified.
enum KernelEventPayload: Sendable, BitwiseCopyable, Equatable {
    case noteOn(channel: UInt8, note: UInt8, velocity: UInt16)
    case noteOff(channel: UInt8, note: UInt8)
    /// Stateful: never coalesced.
    case control(channel: UInt8, controller: UInt8, value: UInt32)
    case program(channel: UInt8, program: UInt8, bank: UInt16)
    case clockPulse
    case rampTo(parameter: UInt32, value: Float, durationFrames: Int64)
}

/// A scheduled kernel event. Reference model; not RT-certified.
///
/// Equality is synthesised and compares `rampTo`'s `Float` with IEEE semantics, so an event carrying NaN is not
/// equal to itself and `+0.0 == -0.0`.
struct KernelEvent: Sendable, BitwiseCopyable, Equatable {
    let frame: Int64
    let scope: UInt32
    let sequence: UInt64
    let payload: KernelEventPayload

    /// §6.5 lane: `noteOff` → `release`, `clockPulse` → `transport`, `control` and `program` → `state`,
    /// `noteOn` and `rampTo` → `content`.
    var lane: EventLane {
        switch payload {
        case .noteOff: .release
        case .clockPulse: .transport
        case .control, .program: .state
        case .noteOn, .rampTo: .content
        }
    }

    /// Only `noteOff` (note release) is `critical`; every other payload is `general`. Safety requests travel
    /// through `SafetyFlags`, not as events.
    var eventClass: EventClass {
        switch payload {
        case .noteOff: .critical
        case .noteOn, .control, .program, .clockPulse, .rampTo: .general
        }
    }
}
