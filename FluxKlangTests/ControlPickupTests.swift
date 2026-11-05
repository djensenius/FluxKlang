import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

struct ControlPickupTests {
    typealias Fixture = ControlBindingTests
    static let width = ParameterID(validated: "par.space.width")
    static let colour = ParameterID(validated: "par.colour")

    @Test
    func catchHoldsUntilCrossingThenApplies() throws {
        let (binding, descriptor) = try Self.fader()
        var state = binding.initialPickupState
        #expect(state == .waiting(hardware: nil))
        var result = try Self.resolve(binding, 0.2, current: 0.5, descriptor, state)
        #expect(result.decision == .held(hardware: 0.2, target: 0.5, reason: .notCaught))
        #expect(result.state == .waiting(hardware: 0.2))
        state = result.state
        result = try Self.resolve(binding, 0.4, current: 0.5, descriptor, state)
        #expect(result.decision == .held(hardware: 0.4, target: 0.5, reason: .notCaught))
        result = try Self.resolve(binding, 0.6, current: 0.5, descriptor, result.state)
        #expect(result.decision == .apply(.set(Self.width, .init(value: 0.6, unit: .normalized))))
        #expect(result.state == .engaged(hardware: 0.6))
        result = try Self.resolve(binding, 0.7, current: 0.6, descriptor, result.state)
        #expect(result.decision == .apply(.set(Self.width, .init(value: 0.7, unit: .normalized))))
    }

    @Test
    func catchEngagesFromAboveAndOnExactEquality() throws {
        let (binding, descriptor) = try Self.fader()
        let above = try Self.resolve(binding, 0.25, current: 0.5, descriptor, .waiting(hardware: 0.75))
        #expect(above.decision == .apply(.set(Self.width, .init(value: 0.25, unit: .normalized))))
        let equal = try Self.resolve(binding, 0.5, current: 0.5, descriptor, .waiting(hardware: nil))
        #expect(equal == PickupResolution(decision: .unchanged, state: .engaged(hardware: 0.5)))
        let fromTarget = try Self.resolve(binding, 0.75, current: 0.5, descriptor, .waiting(hardware: 0.5))
        #expect(fromTarget.state == .engaged(hardware: 0.75))
    }

    @Test
    func unknownHardwarePositionHoldsUnlessEqual() throws {
        let (binding, descriptor) = try Self.fader()
        for position in [0.0, 0.25, 0.75, 1.0] {
            let result = try Self.resolve(binding, position, current: 0.5, descriptor, .waiting(hardware: nil))
            #expect(result.decision == .held(hardware: position, target: 0.5, reason: .notCaught))
            #expect(result.state == .waiting(hardware: position))
        }
    }

    @Test
    func hostChangeReturnsOnlyCatchToWaiting() throws {
        let (catchBinding, descriptor) = try Self.fader()
        #expect(catchBinding.hostChanged(.engaged(hardware: 0.2)) == .waiting(hardware: 0.2))
        #expect(catchBinding.hostChanged(.waiting(hardware: 0.3)) == .waiting(hardware: 0.3))
        #expect(catchBinding.hostChanged(.unavailable) == .unavailable)
        let waiting = catchBinding.hostChanged(.engaged(hardware: 0.2))
        let held = try Self.resolve(catchBinding, 0.3, current: 0.5, descriptor, waiting)
        #expect(held.decision == .held(hardware: 0.3, target: 0.5, reason: .notCaught))
        let (jump, _) = try Self.fader(.jump)
        #expect(jump.initialPickupState == .engaged(hardware: nil))
        #expect(jump.hostChanged(.engaged(hardware: 0.2)) == .engaged(hardware: 0.2))
        let relative = try Fixture.binding(Self.width, unit: .normalized, .twosComplement(width: .seven), step: 0.25)
        #expect(relative.initialPickupState == .engaged(hardware: nil))
        #expect(relative.hostChanged(.engaged(hardware: nil)) == .engaged(hardware: nil))
    }

    @Test
    func jumpAndRelativeNeverWait() throws {
        let (jump, descriptor) = try Self.fader(.jump)
        let jumped = try Self.resolve(jump, 0.2, current: 0.5, descriptor, .engaged(hardware: nil))
        #expect(jumped.decision == .apply(.set(Self.width, .init(value: 0.2, unit: .normalized))))
        #expect(jumped.state == .engaged(hardware: 0.2))
        let relative = try Fixture.binding(Self.width, unit: .normalized, .twosComplement(width: .seven), step: 0.25)
        let turned = try relative.resolve(input: .relative(delta: 1), current: .init(value: 0.5, unit: .normalized),
                                          descriptor: descriptor, state: .waiting(hardware: 0.1))
        #expect(turned.decision == .apply(.set(Self.width, .init(value: 0.75, unit: .normalized))))
        #expect(turned.state == .engaged(hardware: nil))
    }

    @Test
    func hostValueOutsideRangeHoldsInBothDirectionsUntilBackInside() throws {
        let (binding, descriptor) = try Self.fader(lower: 0.2, upper: 0.8)
        var result = try Self.resolve(binding, 0.9, current: 0.95, descriptor, .waiting(hardware: 0.5))
        #expect(result.decision == .held(hardware: 0.9, target: 1, reason: .targetAboveRange))
        result = try Self.resolve(binding, 1, current: 0.95, descriptor, result.state)
        #expect(result.decision == .held(hardware: 1, target: 1, reason: .targetAboveRange))
        #expect(result.state == .waiting(hardware: 1))
        result = try Self.resolve(binding, 0, current: 0.1, descriptor, .waiting(hardware: 0.5))
        #expect(result.decision == .held(hardware: 0, target: 0, reason: .targetBelowRange))
        result = try Self.resolve(binding, 1, current: 0.5, descriptor, result.state)
        #expect(result.decision == .apply(.set(Self.width, .init(value: 0.8, unit: .normalized))))
        #expect(result.state == .engaged(hardware: 1))
        let (jump, _) = try Self.fader(.jump, lower: 0.2, upper: 0.8)
        let jumped = try Self.resolve(jump, 1, current: 0.95, descriptor, .engaged(hardware: nil))
        #expect(jumped.decision == .apply(.set(Self.width, .init(value: 0.8, unit: .normalized))))
    }

    @Test
    func targetAboveCeilingHolds() throws {
        let gain = ParameterID(validated: "par.mains.gain")
        let descriptor = try Fixture.descriptor(gain, unit: .decibels, range: -90...10, ceiling: 0)
        let binding = try Fixture.binding(gain, unit: .decibels, .absolute(resolution: 128), pickup: .catch)
        let result = try binding.resolve(input: .absolute(normalized: 1), current: .init(value: 6, unit: .decibels),
                                         descriptor: descriptor, state: .waiting(hardware: 0.5))
        #expect(result.decision == .held(hardware: 1, target: 1, reason: .targetAboveRange))
    }

    @Test
    func steppedCatchComparesSnappedValues() throws {
        let descriptor = try Fixture.descriptor(Self.colour, unit: .index, range: 0...10, curve: .stepped)
        let binding = try Fixture.binding(Self.colour, unit: .index, .absolute(resolution: 128), pickup: .catch)
        let near = try binding.resolve(input: .absolute(normalized: 0.34), current: .init(value: 3, unit: .index),
                                       descriptor: descriptor, state: .waiting(hardware: nil))
        #expect(near == PickupResolution(decision: .unchanged, state: .engaged(hardware: 0.34)))
        let below = try binding.resolve(input: .absolute(normalized: 0.24), current: .init(value: 3, unit: .index),
                                        descriptor: descriptor, state: .waiting(hardware: nil))
        #expect(below.decision == .held(hardware: 0.24, target: 0.3, reason: .notCaught))
        let crossed = try binding.resolve(input: .absolute(normalized: 0.34), current: .init(value: 2.5, unit: .index),
                                          descriptor: descriptor, state: .waiting(hardware: 0.04))
        #expect(crossed.decision == .apply(.set(Self.colour, .init(value: 3, unit: .index))))
        let sameStep = try binding.resolve(input: .absolute(normalized: 0.04), current: .init(value: 3, unit: .index),
                                           descriptor: descriptor, state: .waiting(hardware: 0.22))
        #expect(sameStep.state == .waiting(hardware: 0.04))
        let fromSnappedTarget = try binding.resolve(input: .absolute(normalized: 0.04),
                                                    current: .init(value: 3, unit: .index),
                                                    descriptor: descriptor, state: .waiting(hardware: 0.28))
        #expect(fromSnappedTarget.decision == .apply(.set(Self.colour, .init(value: 0, unit: .index))))
    }

    @Test
    func zeroWidthRangeEngagesImmediately() throws {
        let (binding, descriptor) = try Self.fader(lower: 0.5, upper: 0.5)
        let result = try Self.resolve(binding, 0.9, current: 0.5, descriptor, .waiting(hardware: nil))
        #expect(result == PickupResolution(decision: .unchanged, state: .engaged(hardware: 0.9)))
        let outside = try Self.resolve(binding, 0.9, current: 0.7, descriptor, .waiting(hardware: nil))
        #expect(outside.decision == .held(hardware: 0.9, target: 1, reason: .targetAboveRange))
    }

    @Test
    func unavailableAndInvalidInputsRefuseWithoutState() throws {
        let (binding, descriptor) = try Self.fader()
        #expect(throws: ControlBindingRefusal.pickupUnavailable) {
            try Self.resolve(binding, 0.5, current: 0.5, descriptor, .unavailable)
        }
        #expect(throws: ControlBindingRefusal.inputOutOfRange(1.5)) {
            try Self.resolve(binding, 1.5, current: 0.5, descriptor, .waiting(hardware: nil))
        }
        #expect(throws: ControlBindingRefusal.nonFinite) {
            try Self.resolve(binding, 0.6, current: 0.5, descriptor, .waiting(hardware: .nan))
        }
        for stored in [7.0, -0.1, Double.infinity] {
            let refusal = stored.isFinite ? ControlBindingRefusal.inputOutOfRange(stored) : .nonFinite
            #expect(throws: refusal) {
                try Self.resolve(binding, 0.6, current: 0.5, descriptor, .waiting(hardware: stored))
            }
        }
        #expect(throws: ControlBindingRefusal.inputMismatch) {
            try binding.resolve(input: .relative(delta: 1), current: .init(value: 0.5, unit: .normalized),
                                descriptor: descriptor, state: .engaged(hardware: nil))
        }
    }

    @Test
    func inversePositionRoundTripsAndHitsEnds() throws {
        typealias Binding = ControlBinding
        let range = -90.0...0.0
        #expect(try Binding.position(of: -90, over: range, curve: .linear) == 0)
        #expect(try Binding.position(of: 0, over: range, curve: .linear) == 1)
        #expect(try Binding.position(of: -45, over: range, curve: .linear) == 0.5)
        #expect(try Binding.position(of: -200, over: range, curve: .linear) == 0)
        #expect(try Binding.position(of: 6, over: range, curve: .linear) == 1)
        #expect(try Binding.position(of: 3, over: 3...3, curve: .stepped) == 0)
        for raw in 0...127 {
            let normalized = Double(raw) / 127
            let value = try Binding.value(at: normalized, over: range, curve: .linear)
            #expect(abs(try Binding.position(of: value, over: range, curve: .linear) - normalized) < 1e-12)
        }
        #expect(throws: ControlBindingRefusal.undefinedCurve(.faderTaper)) {
            try Binding.position(of: 0, over: range, curve: .faderTaper)
        }
        #expect(throws: ControlBindingRefusal.nonFinite) { try Binding.position(of: .nan, over: range, curve: .linear) }
    }

    @Test
    func extremeBoundsRefuseUnrepresentableRange() throws {
        let extreme = -Double.greatestFiniteMagnitude...Double.greatestFiniteMagnitude
        let refusal = ControlBindingRefusal.unrepresentableRange(lower: extreme.lowerBound, upper: extreme.upperBound)
        #expect(throws: refusal) { try ControlBinding.value(at: 0, over: extreme, curve: .linear) }
        #expect(throws: refusal) { try ControlBinding.position(of: 0, over: extreme, curve: .linear) }
        let gain = ParameterID(validated: "par.mains.gain")
        let descriptor = try Fixture.descriptor(gain, unit: .decibels, range: extreme)
        let absolute = try Fixture.binding(gain, unit: .decibels, .absolute(resolution: 128), pickup: .catch)
        #expect(throws: refusal) { try absolute.validate(against: descriptor) }
        #expect(throws: refusal) {
            try absolute.resolve(input: .absolute(normalized: 0), current: .init(value: 0, unit: .decibels),
                                 descriptor: descriptor, state: .waiting(hardware: nil))
        }
        let relative = try Fixture.binding(gain, unit: .decibels, .twosComplement(width: .seven), step: 1)
        #expect(try Fixture.set(relative, .relative(delta: 1), current: 0, descriptor) == 1)
    }

    @Test
    func pickupModeIsRequiredForAbsoluteAndForbiddenForRelative() throws {
        #expect(throws: (any Error).self) {
            try Fixture.binding(Self.width, unit: .normalized, .twosComplement(width: .seven), step: 1, pickup: .catch)
        }
        #expect(throws: (any Error).self) {
            try ControlBinding(.init(id: BindingID(validated: "bnd.x"), source: ControlSourceID(validated: "ctl.x"),
                                     target: Self.width, unit: .normalized, profile: .absolute(resolution: 128)))
        }
        let wire = #"{"id":"bnd.fader3-width","pickup":"catch","profile":{"absolute":{"resolution":128}},"#
            + #""source":"ctl.fader-3","target":"par.space.width","unit":"normalized"}"#
        let decoded = try ContractCoding.decode(ControlBinding.self, from: Data(wire.utf8))
        #expect(decoded.fields.pickup == .catch)
        #expect(try ContractCoding.makeEncoder().encode(decoded) == Data(wire.utf8))
        for invalid in [#""pickup":"relative","#, ""] {
            let edited = Data(wire.replacingOccurrences(of: #""pickup":"catch","#, with: invalid).utf8)
            #expect(throws: (any Error).self) { try ContractCoding.decode(ControlBinding.self, from: edited) }
        }
        let relative = #"{"id":"bnd.enc2-mains","pickup":"catch","profile":{"twosComplement":{"width":7}},"#
            + #""source":"ctl.enc-2","step":0.5,"target":"par.mains.gain","unit":"decibels"}"#
        let modeRule = ControlValidationError.invalid("Absolute bindings require a pickup mode; relative bindings none")
        #expect(throws: modeRule) { try ContractCoding.decode(ControlBinding.self, from: Data(relative.utf8)) }
    }
}

extension ControlPickupTests {
    static func fader(_ mode: PickupMode = .catch, lower: Double? = nil,
                      upper: Double? = nil) throws -> (ControlBinding, ParameterDescriptor) {
        let binding = try Fixture.binding(width, unit: .normalized, .absolute(resolution: 128),
                                          lower: lower, upper: upper, pickup: mode)
        return (binding, try Fixture.descriptor(width, unit: .normalized, range: 0...1))
    }

    static func resolve(_ binding: ControlBinding, _ position: Double, current: Double,
                        _ descriptor: ParameterDescriptor, _ state: PickupState) throws -> PickupResolution {
        try binding.resolve(input: .absolute(normalized: position), current: .init(value: current, unit: .normalized),
                            descriptor: descriptor, state: state)
    }
}
