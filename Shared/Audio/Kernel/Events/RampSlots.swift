// #64 parameter ramps: at most one active ramp per prepared parameter, so timed ramps cannot accumulate.
// Reference model; not RT-certified.

/// Render-owned ramp state with one slot per prepared parameter. A new ramp replaces the parameter's active ramp
/// from the caller's `current` value; nothing is queued. Reference model; not RT-certified.
///
/// Storage is two allocations of `parameterCount` entries made in `init`: the slots and each parameter's last known
/// value (`lastValue`). A single thread (render) owns the instance, so the slots, the values and the active counter
/// are plain memory, not atomics. Hot-path methods range-check `parameter` before forming an index, never allocate
/// and never trap, including at `Int64` extremes.
///
/// Shared across a `.replacingCycle` handoff (round 2l, Copilot thread PRRT_kwDOS3CuTM60f7vt): the last known values
/// live here, beside the ramps, not in a cycle, so a replacement given these slots reports and ramps from the values
/// its retired predecessor left (a completed ramp's target included). Only one cycle uses the slots at a time; the
/// happens-before across the handoff is the ownership claim's (see `KernelCycleStart.replacingCycle`).
final class RampSlots: @unchecked Sendable {
    enum PreparationError: Error, Equatable, Sendable {
        /// `parameterCount` is outside `1...maximumParameters`.
        case parameterCountOutOfRange(Int)
    }

    /// Largest parameter count (inclusive), shared with the largest handoff capacity.
    static let maximumParameters = KernelLimits.maximumCapacity

    private struct Ramp: BitwiseCopyable {
        var start: Float
        var target: Float
        /// Always `>= 0`; `0` means the ramp jumps to `target` on its next `advance`.
        var duration: Int64
        /// Always in `0..<duration` while a ramp with `duration > 0` is active.
        var elapsed: Int64
        var active: Bool

        static let idle = Ramp(start: 0, target: 0, duration: 0, elapsed: 0, active: false)
    }

    let parameterCount: Int
    /// Number of parameters with an active ramp; O(1) and never above `parameterCount`.
    private(set) var activeCount = 0
    private let slots: UnsafeMutablePointer<Ramp>
    /// Each parameter's last known value: what its latest `advance` returned, kept after the ramp completes and the
    /// slot goes idle; 0 before any.
    private let values: UnsafeMutablePointer<Float>

    init(parameterCount: Int) throws(PreparationError) {
        guard parameterCount >= 1, parameterCount <= Self.maximumParameters else {
            throw .parameterCountOutOfRange(parameterCount)
        }
        self.parameterCount = parameterCount
        slots = UnsafeMutablePointer<Ramp>.allocate(capacity: parameterCount)
        slots.initialize(repeating: .idle, count: parameterCount)
        values = UnsafeMutablePointer<Float>.allocate(capacity: parameterCount)
        values.initialize(repeating: 0, count: parameterCount)
    }

    /// Control-side teardown only.
    deinit {
        slots.deinitialize(count: parameterCount)
        slots.deallocate()
        values.deallocate()
    }

    /// Starts a ramp from `current` to `target` over `durationFrames`, replacing any active ramp on `parameter`.
    /// A `durationFrames <= 0` ramp jumps: the next `advance` returns `target` and the slot goes idle.
    /// Returns `.refused(.slotOutOfRange)` for an out-of-range parameter, or `.refused(.invalidLength)` when
    /// `target` or `current` is NaN or infinite. A refusal leaves the slot and `activeCount` unchanged.
    func set(parameter: UInt32, target: Float, durationFrames: Int64, current: Float) -> KernelStatus {
        guard let index = index(parameter) else { return .refused(.slotOutOfRange) }
        // Follow-up (#64): a dedicated `.nonFinite` refusal; `.invalidLength` is the closest existing case.
        guard target.isFinite, current.isFinite else { return .refused(.invalidLength) }
        if !slots[index].active { activeCount &+= 1 }
        slots[index] = Ramp(start: current, target: target, duration: max(durationFrames, 0), elapsed: 0,
                            active: true)
        return .ok
    }

    /// Moves `parameter`'s ramp forward by `frames` (negative counts as 0) and returns its value, or `nil` when the
    /// parameter is idle or out of range. The call that reaches the end returns exactly `target` and frees the slot.
    /// The value returned is also stored as the parameter's `lastValue`.
    func advance(parameter: UInt32, frames: Int64) -> Float? {
        guard let index = index(parameter), slots[index].active else { return nil }
        let step = max(frames, 0)
        // `0 <= elapsed <= duration`, so neither the subtraction nor the addition below can overflow.
        let remaining = slots[index].duration &- slots[index].elapsed
        if step >= remaining {
            slots[index].active = false
            activeCount &-= 1
            values[index] = slots[index].target
            return values[index]
        }
        slots[index].elapsed &+= step
        values[index] = Self.sample(slots[index])
        return values[index]
    }

    /// `parameter`'s last known value: what its latest `advance` returned (kept once the ramp completes and the slot
    /// goes idle), or 0 before any; `nil` when out of range. `set` does not change it.
    func lastValue(parameter: UInt32) -> Float? {
        guard let index = index(parameter) else { return nil }
        return values[index]
    }

    /// Reads `parameter`'s value without moving the ramp: what the last `advance` returned, or `current` before
    /// the first. A pending jump (`durationFrames <= 0`) reads as its `target`. `nil` when the parameter is idle or
    /// out of range.
    func value(parameter: UInt32) -> Float? {
        guard let index = index(parameter), slots[index].active else { return nil }
        return Self.sample(slots[index])
    }

    private func index(_ parameter: UInt32) -> Int? {
        guard parameter < UInt32(truncatingIfNeeded: parameterCount) else { return nil }
        return Int(parameter)
    }

    /// The value at `elapsed`, shared by `advance` and `value`: `target` once `elapsed` reaches `duration` (only a
    /// pending jump, since `advance` completes a ramp there), otherwise interpolated.
    private static func sample(_ ramp: Ramp) -> Float {
        ramp.elapsed < ramp.duration ? interpolate(ramp) : ramp.target
    }

    /// Only called with `elapsed < duration`, so `duration > 0`. Computed as `start + span * fraction` in `Double`:
    /// - the span between two finite `Float`s is at most 2 × `greatestFiniteMagnitude`, so it cannot overflow
    ///   `Double` and needs no infinite-span fallback;
    /// - every step (convert, divide, multiply, add, narrow) rounds monotonically, so the value never steps away
    ///   from `target` as `elapsed` grows. The weighted sum `start * (1 - f) + target * f` does not have this
    ///   property (#183);
    /// - the span itself can round past `target`, so the result is clamped to the endpoints.
    private static func interpolate(_ ramp: Ramp) -> Float {
        let fraction = Double(ramp.elapsed) / Double(ramp.duration)
        let span = Double(ramp.target) - Double(ramp.start)
        let value = Float(Double(ramp.start) + span * fraction)
        return min(max(value, min(ramp.start, ramp.target)), max(ramp.start, ramp.target))
    }
}
