//
//  AutomationRampEvent.swift
//  FluxKlang
//
//  The neutral output of automation block rendering (#108 T2): one parameter
//  event per entry, in the shape of an Audio Unit parameter event (a frame, a
//  target value and a ramp length) without depending on AudioToolbox. The AU
//  adapter is a follow-up.
//

/// One parameter event. Starting at `frame`, the parameter moves linearly from its current value to `value`,
/// reaching it at `frame + rampFrames`; a ramp of 0 frames sets `value` at once. A later event replaces a ramp
/// still in flight. Events of one block are ordered by frame, then by emission order.
struct AutomationRampEvent: Hashable, Sendable {
    /// Why the event was emitted.
    enum Reason: Hashable, Sendable {
        /// The first render since creation or `reset()`: the value at the start position.
        case start
        /// Automation took the parameter back from a gesture, latch, glide or catch.
        case resume
        /// The transport wrapped from the loop end to the loop start at this frame.
        case loopWrap
        /// A ramp boundary or step of the lane's curve.
        case curve
        /// A value owned by the arbiter rather than the lane (a held or moved gesture, a glide, a manual hold).
        case hold
    }

    /// The absolute frame on the bound sample clock.
    let frame: Int64
    /// The frame relative to the start of the rendered block, `0..<blockLength`.
    let offset: Int
    let value: Double
    /// The ramp length in frames; 0 for an immediate change. A ramp may end after its block.
    let rampFrames: Int64
    let reason: Reason
}

/// The live generations a clock map must match before it is used. A local mirror of `MIDIClipGenerations`
/// and `MetronomeGenerations`, kept here so no lane depends on another; unifying them onto one contract type
/// is a follow-up.
struct AutomationRenderGenerations: Hashable, Sendable {
    let sample: Generation
    let transport: Generation
    let musicalMap: Generation
}

/// A performer gesture forwarded to the renderer's arbiter. Gestures arrive between blocks and are stamped at
/// the arbiter's current position, the end of the last rendered block.
enum AutomationRenderGesture: Hashable, Sendable {
    case touch(ControlSourceID, priority: Int)
    case move(ControlSourceID, to: Double)
    case release(ControlSourceID)
    case setMode(AutomationMode)
}

/// The ramp a host following the events is on: from `start` at `startFrame` to `target` at `end`.
struct AutomationHostRamp: Hashable, Sendable {
    let start: Double
    let startFrame: Int64
    let target: Double
    let end: Int64

    /// The value the host holds at `frame`, before any event on that frame.
    func value(at frame: Int64) -> Double {
        guard frame < end else { return target }
        guard frame > startFrame else { return start }
        return AutomationLane.blend(start, target, at: Double(frame - startFrame) / Double(end - startFrame))
    }
}
