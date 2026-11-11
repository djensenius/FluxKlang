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
    /// Stateful: never coalesced on dispatch (carry re-admission coalesces only what `isCoalescible` allows).
    /// `controller` is a MIDI Control Change number.
    case control(channel: UInt8, controller: UInt8, value: UInt32)
    case program(channel: UInt8, program: UInt8, bank: UInt16)
    case clockPulse
    case rampTo(parameter: UInt32, value: Float, durationFrames: Int64)

    /// Whether a later event for the same target makes this one redundant, so carry re-admission
    /// (`KernelCarryReadmission`) may keep only the last writer. `true` for `program`, `rampTo` and a `control` whose
    /// last write, at its own position, determines the resulting state (a set value, or a command that repeats
    /// harmlessly, such as the other channel-mode messages 120 and 122–127). `false` for the RPN/NRPN data-entry
    /// family, whose effect depends on order and count: 6 and 38 (Data Entry MSB/LSB) write the selected parameter, 96
    /// and 97 (Data Increment/Decrement) step it, 98–101 (NRPN/RPN parameter number LSB/MSB) select it, and 121 (Reset
    /// All Controllers) deselects it (RP-015: 98–101 back to 127, so later data entry has no parameter); and for
    /// `noteOn`, `noteOff` and `clockPulse`, never coalesced. Render-safe: a pure switch, no allocation or lock.
    var isCoalescible: Bool {
        switch self {
        case let .control(_, controller, _):
            switch controller {
            case 6, 38, 96...101, 121: false
            default: true
            }
        case .program, .rampTo: true
        case .noteOn, .noteOff, .clockPulse: false
        }
    }
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
