import Foundation

extension ControlRecord where Fields == ControlBindingFields {
    /// Checks this binding against the host's descriptor and returns the range it may write:
    /// the descriptor range capped by its ceiling, narrowed by the binding range and, for
    /// stepped parameters, shrunk to integral steps. Absolute bindings, which map positions over the
    /// range, refuse a range whose width overflows (`0 * inf` would be NaN); relative ones need no width.
    func validate(against descriptor: ParameterDescriptor) throws(ControlBindingRefusal) -> ClosedRange<Double> {
        guard descriptor.id == fields.target else {
            throw .descriptorMismatch(expected: fields.target, found: descriptor.id)
        }
        guard descriptor.controlClass == .live else { throw .unboundableClass(descriptor.controlClass) }
        guard descriptor.unit == fields.unit else { throw .unitMismatch(expected: descriptor.unit, found: fields.unit) }
        if !fields.profile.isRelative, descriptor.curve == .faderTaper { throw .undefinedCurve(.faderTaper) }
        let stepped = descriptor.curve == .stepped
        if stepped, let step = fields.step, step.rounded() != step { throw .invalidStep(step) }
        let range = try writableRange(descriptor, stepped: stepped)
        if !fields.profile.isRelative { try Self.requireRepresentable(range) }
        return range
    }

    /// Resolves one decoded input against host truth (`current`) into an absolute setter.
    /// Returns `nil` when the input does not change the value or would move against a relative turn.
    func operation(for input: ControlInput, current: ParameterValue,
                   descriptor: ParameterDescriptor) throws(ControlBindingRefusal) -> CommandOperation? {
        let range = try validate(against: descriptor)
        guard current.value.isFinite else { throw .nonFinite }
        guard current.unit == descriptor.unit else {
            throw .unitMismatch(expected: descriptor.unit, found: current.unit)
        }
        let stepped = descriptor.curve == .stepped
        guard let candidate = try candidate(for: input, current: current.value, range: range,
                                            curve: descriptor.curve) else { return nil }
        let resolved = Self.snap(candidate, to: range, stepped: stepped)
        guard resolved != current.value, Self.follows(input, from: current.value, to: resolved) else { return nil }
        let value = ParameterValue(value: resolved, unit: descriptor.unit)
        do { try descriptor.check(value) } catch { throw .invalidValue(error) }
        return .set(descriptor.id, value)
    }

    private func writableRange(_ descriptor: ParameterDescriptor,
                               stepped: Bool) throws(ControlBindingRefusal) -> ClosedRange<Double> {
        var lower = max(descriptor.lower, fields.lower ?? descriptor.lower)
        var upper = min(descriptor.ceiling ?? descriptor.upper, fields.upper ?? descriptor.upper)
        if stepped { (lower, upper) = (lower.rounded(.up), upper.rounded(.down)) }
        guard lower <= upper else { throw .emptyRange(lower: lower, upper: upper) }
        return lower...upper
    }

    static func requireRepresentable(_ range: ClosedRange<Double>) throws(ControlBindingRefusal) {
        guard (range.upperBound - range.lowerBound).isFinite else {
            throw .unrepresentableRange(lower: range.lowerBound, upper: range.upperBound)
        }
    }

    /// Stepped parameters step from the whole step behind the turn, so a non-integral host value
    /// moves at most `|delta|` steps.
    private func candidate(for input: ControlInput, current: Double, range: ClosedRange<Double>,
                           curve: ParameterCurve) throws(ControlBindingRefusal) -> Double? {
        switch input {
        case .relative(let delta):
            guard fields.profile.isRelative, let step = fields.step else { throw .inputMismatch }
            guard delta != 0 else { return nil }
            let base = curve != .stepped ? current : delta > 0 ? current.rounded(.down) : current.rounded(.up)
            return base + Double(delta) * step
        case .absolute(let normalized):
            guard !fields.profile.isRelative else { throw .inputMismatch }
            guard normalized.isFinite else { throw .nonFinite }
            guard (0...1).contains(normalized) else { throw .inputOutOfRange(normalized) }
            return try Self.value(at: normalized, over: range, curve: curve)
        }
    }

    /// Linear and stepped curves are linear in travel and land exactly on both ends.
    /// The fader-taper law is not yet defined, so it is refused; descriptors will carry
    /// the taper or a curve table.
    static func value(at normalized: Double, over range: ClosedRange<Double>,
                      curve: ParameterCurve) throws(ControlBindingRefusal) -> Double {
        guard curve != .faderTaper else { throw .undefinedCurve(curve) }
        try requireRepresentable(range)
        guard normalized < 1 else { return range.upperBound }
        return range.lowerBound + normalized * (range.upperBound - range.lowerBound)
    }

    /// A relative turn never moves against its direction (e.g. host truth above a lowered ceiling).
    private static func follows(_ input: ControlInput, from current: Double, to resolved: Double) -> Bool {
        guard case .relative(let delta) = input else { return true }
        return (resolved > current) == (delta > 0)
    }

    private static func snap(_ value: Double, to range: ClosedRange<Double>, stepped: Bool) -> Double {
        let snapped = stepped ? value.rounded() : value
        return min(max(snapped, range.lowerBound), range.upperBound)
    }
}
