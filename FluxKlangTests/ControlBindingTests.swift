import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

struct ControlBindingTests {
    static let level = ParameterID(validated: "par.mains.gain")
    static let mix = ParameterID(validated: "par.verb.mix")
    static let colour = ParameterID(validated: "par.colour")

    @Test
    func twosComplementGoldens() throws {
        let seven = EncoderProfile.twosComplement(width: .seven)
        let goldens = [(1, 1), (127, -1), (63, 63), (64, -64), (0, 0)]
        for (raw, delta) in goldens { #expect(try seven.decode(raw: raw) == .relative(delta: delta)) }
        let fourteen = EncoderProfile.twosComplement(width: .fourteen)
        for (raw, delta) in [(1, 1), (16_383, -1), (8191, 8191), (8192, -8192), (0, 0)] {
            #expect(try fourteen.decode(raw: raw) == .relative(delta: delta))
        }
    }

    @Test
    func binaryOffsetGoldens() throws {
        let seven = EncoderProfile.binaryOffset(width: .seven)
        for (raw, delta) in [(65, 1), (63, -1), (127, 63), (0, -64), (64, 0)] {
            #expect(try seven.decode(raw: raw) == .relative(delta: delta))
        }
        let fourteen = EncoderProfile.binaryOffset(width: .fourteen)
        for (raw, delta) in [(8193, 1), (8191, -1), (16_383, 8191), (0, -8192), (8192, 0)] {
            #expect(try fourteen.decode(raw: raw) == .relative(delta: delta))
        }
    }

    @Test
    func signMagnitudeGoldens() throws {
        let seven = EncoderProfile.signMagnitude(width: .seven)
        for (raw, delta) in [(1, 1), (65, -1), (63, 63), (127, -63), (0, 0), (64, 0)] {
            #expect(try seven.decode(raw: raw) == .relative(delta: delta))
        }
        let fourteen = EncoderProfile.signMagnitude(width: .fourteen)
        for (raw, delta) in [(1, 1), (8193, -1), (8191, 8191), (16_383, -8191), (8192, 0)] {
            #expect(try fourteen.decode(raw: raw) == .relative(delta: delta))
        }
    }

    @Test
    func relativeProfilesAreDistinct() throws {
        let profiles = Self.sevenBitRelative
        for (raw, expected) in [(1, [-63, 1, 1]), (65, [1, -63, -1]), (64, [0, -64, 0]), (127, [63, -1, -63])] {
            #expect(try profiles.map { try $0.decode(raw: raw) } == expected.map { .relative(delta: $0) })
        }
        #expect(EncoderProfile.binaryOffset(width: .seven) != .twosComplement(width: .seven))
        #expect(EncoderProfile.twosComplement(width: .seven) != .twosComplement(width: .fourteen))
    }

    @Test
    func invalidRawValuesAndResolutionsAreRefused() throws {
        for profile in Self.sevenBitRelative {
            #expect(throws: EncoderDecodeError.rawOutOfRange(128, lower: 0, upper: 127)) {
                try profile.decode(raw: 128)
            }
            #expect(throws: EncoderDecodeError.rawOutOfRange(-1, lower: 0, upper: 127)) {
                try profile.decode(raw: -1)
            }
        }
        #expect(throws: EncoderDecodeError.rawOutOfRange(16_384, lower: 0, upper: 16_383)) {
            try EncoderProfile.signMagnitude(width: .fourteen).decode(raw: 16_384)
        }
        #expect(throws: EncoderDecodeError.rawOutOfRange(128, lower: 0, upper: 127)) {
            try EncoderProfile.absolute(resolution: 128).decode(raw: 128)
        }
        for resolution in [1, 16_385] {
            #expect(throws: EncoderDecodeError.invalidResolution(resolution)) {
                try EncoderProfile.absolute(resolution: resolution).decode(raw: 0)
            }
            #expect(throws: (any Error).self) {
                try Self.binding(Self.mix, unit: .percent, .absolute(resolution: resolution))
            }
        }
    }

    @Test
    func absoluteEndpointsAreExactAndMidpointIsLinear() throws {
        let profile = EncoderProfile.absolute(resolution: 128)
        #expect(try profile.decode(raw: 0) == .absolute(normalized: 0))
        #expect(try profile.decode(raw: 127) == .absolute(normalized: 1))
        let level = try Self.binding(Self.level, unit: .decibels, profile, lower: -90.1, upper: 10.3)
        let gain = try Self.descriptor(Self.level, unit: .decibels, range: -100...20)
        #expect(try Self.set(level, .absolute(normalized: 0), current: -20, gain) == -90.1)
        #expect(try Self.set(level, .absolute(normalized: 1), current: -20, gain) == 10.3)
        let linear = try Self.binding(Self.mix, unit: .percent, profile)
        let percent = try Self.descriptor(Self.mix, unit: .percent, range: 0...100)
        let operation = try linear.operation(for: .absolute(normalized: 0.5), current: .init(value: 30, unit: .percent),
                                             descriptor: percent)
        #expect(operation == .set(Self.mix, .init(value: 50, unit: .percent)))
    }

    @Test
    func relativeInputClampsAtBothBounds() throws {
        let binding = try Self.binding(Self.mix, unit: .percent, .twosComplement(width: .seven), step: 5)
        let percent = try Self.descriptor(Self.mix, unit: .percent, range: 0...100)
        #expect(try Self.set(binding, .relative(delta: 1), current: 98, percent) == 100)
        #expect(try Self.set(binding, .relative(delta: -64), current: 2, percent) == 0)
        #expect(try Self.set(binding, .relative(delta: 1), current: 100, percent) == nil)
        #expect(try Self.set(binding, .relative(delta: -1), current: 0, percent) == nil)
    }

    @Test
    func subRangeAndCeilingNarrowTheWritableRange() throws {
        let relative = try Self.binding(Self.mix, unit: .percent, .binaryOffset(width: .seven), step: 5,
                                        lower: 20, upper: 80)
        let absolute = try Self.binding(Self.mix, unit: .percent, .absolute(resolution: 128), lower: 20, upper: 80)
        let percent = try Self.descriptor(Self.mix, unit: .percent, range: 0...100)
        #expect(try Self.set(relative, .relative(delta: 1), current: 79, percent) == 80)
        #expect(try Self.set(relative, .relative(delta: -1), current: 22, percent) == 20)
        #expect(try Self.set(absolute, .absolute(normalized: 0), current: 50, percent) == 20)
        #expect(try Self.set(absolute, .absolute(normalized: 1), current: 50, percent) == 80)
        let capped = try Self.descriptor(Self.level, unit: .decibels, range: -90...10, ceiling: 0)
        let level = try Self.binding(Self.level, unit: .decibels, .twosComplement(width: .seven), step: 0.5)
        #expect(try level.validate(against: capped) == -90...0)
        #expect(try Self.set(level, .relative(delta: 63), current: -1, capped) == 0)
        let disjoint = try Self.binding(Self.mix, unit: .percent, .binaryOffset(width: .seven), step: 1,
                                        lower: 101, upper: 120)
        #expect(throws: ControlBindingRefusal.emptyRange(lower: 101, upper: 100)) {
            try disjoint.validate(against: percent)
        }
    }

    @Test
    func steppedParametersSnapToIntegralSteps() throws {
        let index = try Self.descriptor(Self.colour, unit: .index, range: 1...12, curve: .stepped)
        let absolute = try Self.binding(Self.colour, unit: .index, .absolute(resolution: 128))
        #expect(try Self.set(absolute, .absolute(normalized: 0.5), current: 1, index) == 7)
        #expect(try Self.set(absolute, .absolute(normalized: 0.04), current: 12, index) == 1)
        let relative = try Self.binding(Self.colour, unit: .index, .signMagnitude(width: .seven), step: 1,
                                        lower: 2.5, upper: 8.5)
        #expect(try relative.validate(against: index) == 3...8)
        #expect(try Self.set(relative, .relative(delta: 3), current: 7, index) == 8)
        #expect(try Self.set(relative, .relative(delta: 1), current: 1, index) == 3)
        #expect(try Self.set(relative, .relative(delta: -1), current: 1, index) == nil)
        let fractional = try Self.binding(Self.colour, unit: .index, .signMagnitude(width: .seven), step: 0.5)
        #expect(throws: ControlBindingRefusal.invalidStep(0.5)) { try fractional.validate(against: index) }
    }

    @Test(arguments: [ControlClass.hazardous, .structural])
    func unsafeTargetsCannotBeBound(controlClass: ControlClass) throws {
        let trim = try Self.descriptor(Self.level, unit: .decibels, range: 0...60, controlClass: controlClass)
        let binding = try Self.binding(Self.level, unit: .decibels, .twosComplement(width: .seven), step: 1)
        #expect(throws: ControlBindingRefusal.unboundableClass(controlClass)) { try binding.validate(against: trim) }
        #expect(throws: ControlBindingRefusal.unboundableClass(controlClass)) {
            try Self.set(binding, .relative(delta: 1), current: 20, trim)
        }
    }

    @Test
    func unitMismatchesAreRefused() throws {
        let percent = try Self.descriptor(Self.mix, unit: .percent, range: 0...100)
        let normalized = try Self.binding(Self.mix, unit: .normalized, .twosComplement(width: .seven), step: 0.01)
        #expect(throws: ControlBindingRefusal.unitMismatch(expected: .percent, found: .normalized)) {
            try normalized.validate(against: percent)
        }
        let binding = try Self.binding(Self.mix, unit: .percent, .twosComplement(width: .seven), step: 1)
        #expect(throws: ControlBindingRefusal.unitMismatch(expected: .percent, found: .decibels)) {
            try binding.operation(for: .relative(delta: 1), current: .init(value: 3, unit: .decibels),
                                  descriptor: percent)
        }
    }

    @Test
    func nonFiniteAndOutOfRangeInputsAreRefused() throws {
        let percent = try Self.descriptor(Self.mix, unit: .percent, range: 0...100)
        let relative = try Self.binding(Self.mix, unit: .percent, .twosComplement(width: .seven), step: 1)
        let absolute = try Self.binding(Self.mix, unit: .percent, .absolute(resolution: 128))
        #expect(throws: ControlBindingRefusal.nonFinite) {
            try Self.set(relative, .relative(delta: 1), current: .nan, percent)
        }
        #expect(throws: ControlBindingRefusal.nonFinite) {
            try Self.set(absolute, .absolute(normalized: .infinity), current: 5, percent)
        }
        #expect(throws: ControlBindingRefusal.inputOutOfRange(1.5)) {
            try Self.set(absolute, .absolute(normalized: 1.5), current: 5, percent)
        }
        #expect(throws: ControlBindingRefusal.inputMismatch) {
            try Self.set(absolute, .relative(delta: 1), current: 5, percent)
        }
        #expect(throws: ControlBindingRefusal.inputMismatch) {
            try Self.set(relative, .absolute(normalized: 0.5), current: 5, percent)
        }
        for step in [Double.nan, .infinity, 0, -1] {
            #expect(throws: (any Error).self) {
                try Self.binding(Self.mix, unit: .percent, .twosComplement(width: .seven), step: step)
            }
        }
        #expect(throws: (any Error).self) {
            try Self.binding(Self.mix, unit: .percent, .absolute(resolution: 128), step: 1)
        }
        #expect(throws: (any Error).self) { try Self.binding(Self.mix, unit: .percent, .twosComplement(width: .seven)) }
        #expect(throws: (any Error).self) {
            try Self.binding(Self.mix, unit: .percent, .twosComplement(width: .seven), step: 1, lower: 60, upper: 40)
        }
    }

    @Test
    func descriptorForAnotherParameterIsRefused() throws {
        let binding = try Self.binding(Self.mix, unit: .percent, .twosComplement(width: .seven), step: 1)
        let other = try Self.descriptor(Self.colour, unit: .percent, range: 0...100)
        #expect(throws: ControlBindingRefusal.descriptorMismatch(expected: Self.mix, found: Self.colour)) {
            try Self.set(binding, .relative(delta: 1), current: 5, other)
        }
    }

    @Test
    func zeroDeltaProducesNoCommandForEveryRelativeProfile() throws {
        let percent = try Self.descriptor(Self.mix, unit: .percent, range: 0...100)
        for (profile, zero) in zip(Self.sevenBitRelative, [64, 0, 64]) {
            let binding = try Self.binding(Self.mix, unit: .percent, profile, step: 1)
            let input = try profile.decode(raw: zero)
            #expect(input == .relative(delta: 0))
            #expect(try Self.set(binding, input, current: 50, percent) == nil)
        }
    }

    @Test
    func codableRoundTripKeepsUnknownFields() throws {
        let wire = #"{"future":{"a":1},"id":"bnd.enc2-mains","profile":{"twosComplement":{"width":7}},"#
            + #""source":"ctl.enc-2","step":0.5,"target":"par.mains.gain","unit":"decibels","upper":0}"#
        let decoded = try ContractCoding.decode(ControlBinding.self, from: Data(wire.utf8))
        #expect(decoded.fields == Self.encoder2Fields)
        #expect(decoded.unknownFields == ["future": .object(["a": .int(1)])])
        #expect(try ContractCoding.makeEncoder().encode(decoded) == Data(wire.utf8))
        let invalid = wire.replacingOccurrences(of: #""step":0.5,"#, with: "")
        #expect(throws: (any Error).self) { try ContractCoding.decode(ControlBinding.self, from: Data(invalid.utf8)) }
    }

    @Test
    func decodingAndMappingAreDeterministic() throws {
        let profiles = Self.sevenBitRelative + [.absolute(resolution: 128)]
        for profile in profiles {
            let first = try (0...127).map { try profile.decode(raw: $0) }
            #expect(try (0...127).map { try profile.decode(raw: $0) } == first)
            #expect(Set(first).count == (profile == .signMagnitude(width: .seven) ? 127 : 128))
        }
        let binding = try ControlBinding(Self.encoder2Fields)
        let gain = try Self.descriptor(Self.level, unit: .decibels, range: -90...10, ceiling: 0)
        let runs = try (0..<3).map { _ in
            try (-4...4).map { try Self.set(binding, .relative(delta: $0), current: -0.5, gain) }
        }
        #expect(runs.allSatisfy { $0 == runs[0] })
        #expect(runs[0] == [-2.5, -2, -1.5, -1, nil, 0, 0, 0, 0])
    }
}

extension ControlBindingTests {
    static let sevenBitRelative: [EncoderProfile] = [
        .binaryOffset(width: .seven), .twosComplement(width: .seven), .signMagnitude(width: .seven)
    ]

    static var encoder2Fields: ControlBindingFields {
        ControlBindingFields(
            id: BindingID(validated: "bnd.enc2-mains"), source: ControlSourceID(validated: "ctl.enc-2"),
            target: level, unit: .decibels, profile: .twosComplement(width: .seven), step: 0.5, upper: 0
        )
    }

    static func binding(
        _ target: ParameterID, unit: ParameterUnit, _ profile: EncoderProfile,
        step: Double? = nil, lower: Double? = nil, upper: Double? = nil, pickup: PickupMode? = nil
    ) throws -> ControlBinding {
        try ControlBinding(.init(id: BindingID(validated: "bnd.test"), source: ControlSourceID(validated: "ctl.test"),
                                 target: target, unit: unit, profile: profile, step: step, lower: lower, upper: upper,
                                 pickup: pickup ?? (profile.isRelative ? nil : .jump)))
    }

    static func descriptor(
        _ id: ParameterID, unit: ParameterUnit, range: ClosedRange<Double>, curve: ParameterCurve = .linear,
        ceiling: Double? = nil, controlClass: ControlClass = .live
    ) throws -> ParameterDescriptor {
        try ParameterDescriptor(.init(
            id: id, unit: unit, lower: range.lowerBound, upper: range.upperBound, defaultValue: range.lowerBound,
            ceiling: ceiling, curve: curve, ramp: .step, controlClass: controlClass, verification: .unverified
        ))
    }

    /// The value a binding sets, or `nil` when it produces no command.
    static func set(
        _ binding: ControlBinding, _ input: ControlInput, current: Double, _ descriptor: ParameterDescriptor
    ) throws -> Double? {
        let operation = try binding.operation(for: input, current: .init(value: current, unit: descriptor.unit),
                                              descriptor: descriptor)
        guard let operation else { return nil }
        guard case .set(let id, let value) = operation, id == descriptor.id, value.unit == descriptor.unit else {
            Issue.record("Unexpected operation \(operation)")
            return nil
        }
        return value.value
    }
}
