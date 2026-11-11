//
//  AutomationRenderRefusal.swift
//  FluxKlang
//
//  Typed refusals of automation block rendering (#108 T2). A refused render or
//  gesture returns nothing and leaves the renderer, including its arbiter,
//  exactly as it was.
//

/// Why an automation render or forwarded gesture is refused.
enum AutomationRenderRefusal: Error, Equatable, Sendable {
    /// The clock map refused (overflow), or it is stale for the live sample or transport generation.
    case clock(ClockMapError)
    /// The clock map's tempo map revision is not the live `musicalMap` generation.
    case staleMusicalMap
    /// The block `[start, end)` is empty or reversed.
    case invalidWindow(start: Int64, end: Int64)
    /// The block spans more than `limit` frames.
    case windowTooLong(start: Int64, end: Int64, limit: Int64)
    /// The block holds more than `limit` events; nothing is returned rather than a truncated list.
    case tooManyEvents(limit: Int)
    /// A render must start where the previous one ended.
    case nonContiguousWindow(expected: Int64, start: Int64)
    /// The render's generations differ from those the renderer is bound to. Nothing is re-anchored silently:
    /// call `reset()`, then render on the new map.
    case clockRevisionChanged(expected: ClockGenerationSnapshot, got: ClockGenerationSnapshot)
    /// The clock places the block start at another musical position than the previous render ended at, so the
    /// map was re-anchored without a generation change; `reset()` first.
    case positionMismatch(frame: Int64)
    /// The loop is shorter than one frame at this tempo and rate, so the transport would never advance.
    case nonAdvancingLoop
    /// The block would wrap the loop more than `limit` times (a loop of a few frames held by a gesture).
    case tooManyWraps(limit: Int)
    /// A gesture arrived before the first render, so it has no position.
    case notStarted
    /// The arbiter or lane refused (for example a gesture from a source that is not touching).
    case automation(AutomationRefusal)
}
