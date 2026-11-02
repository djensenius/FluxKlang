// #64 event class: whether a kernel event may use a handoff's critical reservation.
// Reference model; not RT-certified.

/// `critical` events (today only `noteOff`, a note release) may use a handoff's reserved critical slots; everything
/// else is `general`. Safety requests do not travel as events: they use `SafetyFlags`.
/// Reference model; not RT-certified.
enum EventClass: UInt8, Sendable, BitwiseCopyable, CaseIterable {
    case general, critical
}
