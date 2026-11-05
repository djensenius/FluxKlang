import Foundation

extension ControlRecord where Fields == ControlBindingFields {
    /// The state a binding starts in, and returns to when its controller is seen again:
    /// a catch binding waits for its first position; jump and relative bindings apply at once.
    var initialPickupState: PickupState {
        fields.pickup == .catch ? .waiting(hardware: nil) : .engaged(hardware: nil)
    }

    /// The caller signals that another origin (host UI, recall, automation, a peer) changed this
    /// binding's target, and also when the writable range changes (a new ceiling, descriptor range or
    /// binding range), since the control's position then maps to a different value. An engaged catch
    /// binding waits again, remembering the control's side; jump and relative bindings never wait.
    func hostChanged(_ state: PickupState) -> PickupState {
        guard fields.pickup == .catch, case .engaged(let hardware) = state else { return state }
        return .waiting(hardware: hardware)
    }

    /// Resolves one input under pickup against host truth (`current`). Engagement is decided in
    /// parameter-value space after snapping: a waiting catch binding engages when the input lands on
    /// the value, or when it and the previous position are not strictly on the same side of it.
    /// Stepped parameters thus catch within half a step; linear ones need no tolerance. Host truth
    /// outside the writable range is never caught at the range's end, which would jump. Refusals
    /// are thrown and leave the caller's state as it was.
    func resolve(input: ControlInput, current: ParameterValue, descriptor: ParameterDescriptor,
                 state: PickupState) throws(ControlBindingRefusal) -> PickupResolution {
        guard state != .unavailable else { throw .pickupUnavailable }
        let operation = try operation(for: input, current: current, descriptor: descriptor)
        let decision = operation.map(PickupDecision.apply) ?? .unchanged
        guard case .absolute(let position) = input, let mode = fields.pickup else {
            return PickupResolution(decision: decision, state: .engaged(hardware: nil))
        }
        let engaged = PickupResolution(decision: decision, state: .engaged(hardware: position))
        guard mode == .catch, case .waiting(let previous) = state else { return engaged }
        if let previous { try Self.requirePosition(previous) }
        let range = try validate(against: descriptor)
        let target = current.value
        if target < range.lowerBound { return try held(position, target, range, descriptor, .targetBelowRange) }
        if target > range.upperBound { return try held(position, target, range, descriptor, .targetAboveRange) }
        let landed = try Self.snapped(position, over: range, curve: descriptor.curve)
        guard landed != target else { return engaged }
        if let previous {
            let before = try Self.snapped(previous, over: range, curve: descriptor.curve)
            guard Self.sameSide(landed, before, of: target) else { return engaged }
        }
        return try held(position, target, range, descriptor, .notCaught)
    }

    /// Inverse of `value(at:over:curve:)`: the normalized position of `value`, clamped into
    /// `range`. Both ends are exact; in a zero-width range its own value is position 0.
    static func position(of value: Double, over range: ClosedRange<Double>,
                         curve: ParameterCurve) throws(ControlBindingRefusal) -> Double {
        guard curve != .faderTaper else { throw .undefinedCurve(curve) }
        guard value.isFinite else { throw .nonFinite }
        try requireRepresentable(range)
        guard value > range.lowerBound else { return 0 }
        guard value < range.upperBound else { return 1 }
        return (value - range.lowerBound) / (range.upperBound - range.lowerBound)
    }

    private func held(_ position: Double, _ target: Double, _ range: ClosedRange<Double>,
                      _ descriptor: ParameterDescriptor,
                      _ reason: PickupHoldReason) throws(ControlBindingRefusal) -> PickupResolution {
        let shown = try Self.position(of: target, over: range, curve: descriptor.curve)
        return PickupResolution(decision: .held(hardware: position, target: shown, reason: reason),
                                state: .waiting(hardware: position))
    }

    private static func snapped(_ position: Double, over range: ClosedRange<Double>,
                                curve: ParameterCurve) throws(ControlBindingRefusal) -> Double {
        let value = try value(at: position, over: range, curve: curve)
        return curve == .stepped ? value.rounded() : value
    }

    /// A stored position is caller-held state; it must be a valid normalized input like any other.
    private static func requirePosition(_ position: Double) throws(ControlBindingRefusal) {
        guard position.isFinite else { throw .nonFinite }
        guard (0...1).contains(position) else { throw .inputOutOfRange(position) }
    }

    private static func sameSide(_ first: Double, _ second: Double, of target: Double) -> Bool {
        (first < target && second < target) || (first > target && second > target)
    }
}
