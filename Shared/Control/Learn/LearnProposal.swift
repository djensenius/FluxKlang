import Foundation

/// One control heard while listening. The caller decodes the protocol and classifies the
/// control: `profile` says whether it is absolute or relative. Learn never guesses a profile.
struct LearnHeardControl: Hashable, Sendable {
    let device: DeviceID
    let source: ControlSourceID
    let profile: EncoderProfile
}

/// Default binding fields for a heard control: absolute controls catch, relative controls step
/// a fixed fraction of the writable range (one whole step on stepped targets).
enum LearnDefaults {
    static let relativeDetentsPerRange = 100.0

    static func binding(_ id: BindingID, for heard: LearnHeardControl,
                        on descriptor: ParameterDescriptor) throws(LearnIgnoreReason) -> ControlBinding {
        let relative = heard.profile.isRelative
        var step: Double?
        if relative {
            guard let value = relativeStep(for: descriptor) else { throw .noUsableStep }
            step = value
        }
        let fields = ControlBindingFields(id: id, source: heard.source, target: descriptor.id,
                                          unit: descriptor.unit, profile: heard.profile, step: step,
                                          pickup: relative ? nil : .catch)
        let binding: ControlBinding
        do { binding = try ControlBinding(fields) } catch { throw .unconstructible }
        do { _ = try binding.validate(against: descriptor) } catch { throw .incompatible(error) }
        return binding
    }

    static func relativeStep(for descriptor: ParameterDescriptor) -> Double? {
        if descriptor.curve == .stepped { return 1 }
        let step = ((descriptor.ceiling ?? descriptor.upper) - descriptor.lower) / relativeDetentsPerRange
        return step.isFinite && step > 0 ? step : nil
    }
}
