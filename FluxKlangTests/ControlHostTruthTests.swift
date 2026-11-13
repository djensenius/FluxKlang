import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

@Suite(.productionAccessAudit)
struct ControlHostTruthTests {
    typealias Fixture = ControlBindingTests
    static let mix = ParameterID(validated: "par.verb.mix")
    static let width = ParameterID(validated: "par.space.width")
    static let level = ParameterID(validated: "par.mains.gain")

    @Test
    func resolvesThroughCatalogExactlyLikeDescriptorResolve() throws {
        let percent = try Fixture.descriptor(Self.mix, unit: .percent, range: 0...100)
        let normalized = try Fixture.descriptor(Self.width, unit: .normalized, range: 0...1)
        let truth = try Self.truth([percent, normalized], [Self.mix: 30, Self.width: 0.5])
        let relative = try Fixture.binding(Self.mix, unit: .percent, .twosComplement(width: .seven), step: 2)
        let jump = try Fixture.binding(Self.mix, unit: .percent, .absolute(resolution: 128))
        let catchFader = try Fixture.binding(Self.width, unit: .normalized, .absolute(resolution: 128), pickup: .catch)
        let cases: [(ControlBinding, [(ControlInput, PickupState)])] = [
            (relative, [(.relative(delta: 3), .engaged(hardware: nil))]),
            (jump, [(.absolute(normalized: 0.25), .engaged(hardware: nil))]),
            (catchFader, [(.absolute(normalized: 0.2), .waiting(hardware: nil)),
                          (.absolute(normalized: 0.7), .waiting(hardware: 0.2))])
        ]
        for (binding, inputs) in cases {
            let descriptor = try #require(truth.catalog[binding.target])
            let current = try #require(truth.values[descriptor.id])
            for (input, state) in inputs {
                let direct = try binding.resolve(input: input, current: current, descriptor: descriptor, state: state)
                #expect(try binding.resolve(input: input, truth: truth, state: state) == direct)
            }
        }
        let turned = try relative.resolve(input: .relative(delta: 3), truth: truth, state: .engaged(hardware: nil))
        #expect(turned.decision == .apply(.set(Self.mix, .init(value: 36, unit: .percent))))
    }

    @Test
    func removedTargetIsRefusedEvenAfterAnEarlierApply() throws {
        let percent = try Fixture.descriptor(Self.mix, unit: .percent, range: 0...100)
        let normalized = try Fixture.descriptor(Self.width, unit: .normalized, range: 0...1)
        let binding = try Fixture.binding(Self.mix, unit: .percent, .twosComplement(width: .seven), step: 2)
        let before = try Self.truth([percent, normalized], [Self.mix: 30, Self.width: 0.5])
        let applied = try binding.resolve(input: .relative(delta: 1), truth: before, state: .engaged(hardware: nil))
        #expect(applied.decision == .apply(.set(Self.mix, .init(value: 32, unit: .percent))))
        let removed = try Self.truth([normalized], [Self.mix: 32, Self.width: 0.5])
        #expect(throws: ControlBindingRefusal.targetMissing(Self.mix)) {
            try binding.resolve(input: .relative(delta: 1), truth: removed, state: applied.state)
        }
        let otherRemoved = try Self.truth([percent], [Self.mix: 32])
        let still = try binding.resolve(input: .relative(delta: 1), truth: otherRemoved, state: applied.state)
        #expect(still.decision == .apply(.set(Self.mix, .init(value: 34, unit: .percent))))
    }

    @Test
    func missingHostValueIsRefusedNeverDefaulted() throws {
        let percent = try Fixture.descriptor(Self.mix, unit: .percent, range: 0...100)
        let normalized = try Fixture.descriptor(Self.width, unit: .normalized, range: 0...1)
        let truth = try Self.truth([percent, normalized], [Self.width: 0.5])
        let relative = try Fixture.binding(Self.mix, unit: .percent, .twosComplement(width: .seven), step: 2)
        #expect(throws: ControlBindingRefusal.valueUnavailable(Self.mix)) {
            try relative.resolve(input: .relative(delta: 1), truth: truth, state: .engaged(hardware: nil))
        }
        let jump = try Fixture.binding(Self.mix, unit: .percent, .absolute(resolution: 128))
        #expect(throws: ControlBindingRefusal.valueUnavailable(Self.mix)) {
            try jump.resolve(input: .absolute(normalized: 0.5), truth: truth, state: .engaged(hardware: nil))
        }
        #expect(throws: ControlBindingRefusal.targetMissing(Self.level)) { try truth.target(Self.level) }
        let (descriptor, value) = try truth.target(Self.width)
        #expect(descriptor == normalized)
        #expect(value == ParameterValue(value: 0.5, unit: .normalized))
    }

    @Test
    func retypedTargetIsRefused() throws {
        let binding = try Fixture.binding(Self.mix, unit: .percent, .twosComplement(width: .seven), step: 2)
        let retyped = try Fixture.descriptor(Self.mix, unit: .normalized, range: 0...1)
        let truth = try Self.truth([retyped], [Self.mix: 0.3])
        #expect(throws: ControlBindingRefusal.unitMismatch(expected: .normalized, found: .percent)) {
            try binding.resolve(input: .relative(delta: 1), truth: truth, state: .engaged(hardware: nil))
        }
        let percent = try Fixture.descriptor(Self.mix, unit: .percent, range: 0...100)
        let staleValue = try ControlHostTruth(catalog: try ParameterCatalog([percent]),
                                              values: [Self.mix: .init(value: 0.3, unit: .normalized)])
        #expect(throws: ControlBindingRefusal.unitMismatch(expected: .percent, found: .normalized)) {
            try binding.resolve(input: .relative(delta: 1), truth: staleValue, state: .engaged(hardware: nil))
        }
    }

    @Test(arguments: [ControlClass.hazardous, .structural])
    func reclassedTargetIsRefusedOnTheNextInput(controlClass: ControlClass) throws {
        let binding = try Fixture.binding(Self.level, unit: .decibels, .absolute(resolution: 128))
        let live = try Fixture.descriptor(Self.level, unit: .decibels, range: -90...0)
        let before = try Self.truth([live], [Self.level: -20])
        let first = try binding.resolve(input: .absolute(normalized: 0.5), truth: before,
                                        state: .engaged(hardware: nil))
        #expect(first.decision == .apply(.set(Self.level, .init(value: -45, unit: .decibels))))
        let reclassed = try Fixture.descriptor(Self.level, unit: .decibels, range: -90...0, controlClass: controlClass)
        let after = try Self.truth([reclassed], [Self.level: -45])
        #expect(throws: ControlBindingRefusal.unboundableClass(controlClass)) {
            try binding.resolve(input: .absolute(normalized: 0.6), truth: after, state: first.state)
        }
    }

    @Test
    func shrunkRangeClampsToNewHostRange() throws {
        let shrunk = try Fixture.descriptor(Self.mix, unit: .percent, range: 0...60)
        let truth = try Self.truth([shrunk], [Self.mix: 58])
        let relative = try Fixture.binding(Self.mix, unit: .percent, .twosComplement(width: .seven), step: 2)
        let turned = try relative.resolve(input: .relative(delta: 5), truth: truth, state: .engaged(hardware: nil))
        #expect(turned.decision == .apply(.set(Self.mix, .init(value: 60, unit: .percent))))
        let jump = try Fixture.binding(Self.mix, unit: .percent, .absolute(resolution: 128))
        let top = try jump.resolve(input: .absolute(normalized: 1), truth: truth, state: .engaged(hardware: nil))
        #expect(top.decision == .apply(.set(Self.mix, .init(value: 60, unit: .percent))))
        let capped = try Fixture.descriptor(Self.width, unit: .normalized, range: 0...1, ceiling: 0.5)
        let fader = try Fixture.binding(Self.width, unit: .normalized, .absolute(resolution: 128), pickup: .catch)
        let lowered = try Self.truth([capped], [Self.width: 0.8])
        let held = try fader.resolve(input: .absolute(normalized: 1), truth: lowered, state: .waiting(hardware: 0.9))
        #expect(held.decision == .held(hardware: 1, target: 1, reason: .targetAboveRange))
        #expect(held.state == .waiting(hardware: 1))
    }

    @Test
    func vanishedRangeIsRefused() throws {
        let binding = try Fixture.binding(Self.mix, unit: .percent, .twosComplement(width: .seven), step: 2, lower: 70)
        let narrowed = try Fixture.descriptor(Self.mix, unit: .percent, range: 0...50)
        #expect(throws: ControlBindingRefusal.emptyRange(lower: 70, upper: 50)) {
            try binding.resolve(input: .relative(delta: 1), truth: try Self.truth([narrowed], [Self.mix: 40]),
                                state: .engaged(hardware: nil))
        }
    }

    @Test
    func valueCountIsBoundedAndCatalogIDsAreUnique() throws {
        let catalog = try ParameterCatalog([Fixture.descriptor(Self.mix, unit: .percent, range: 0...100)])
        let values = try (0..<4097).map { (try ParameterID("par.v\($0)"), ParameterValue(value: 1, unit: .percent)) }
        let full = Dictionary(uniqueKeysWithValues: values.prefix(4096))
        #expect(try ControlHostTruth(catalog: catalog, values: full).values.count == 4096)
        #expect(throws: ControlHostTruthRefusal.tooManyValues(4097)) {
            try ControlHostTruth(catalog: catalog, values: Dictionary(uniqueKeysWithValues: values))
        }
        let percent = try Fixture.descriptor(Self.mix, unit: .percent, range: 0...100)
        #expect(throws: DuplicateIDError(rawValue: "par.verb.mix")) { try ParameterCatalog([percent, percent]) }
    }

    @Test
    func nonFiniteHostValuesAreKeptButRefuseTheirBinding() throws {
        let percent = try Fixture.descriptor(Self.mix, unit: .percent, range: 0...100)
        let relative = try Fixture.binding(Self.mix, unit: .percent, .twosComplement(width: .seven), step: 2)
        let fader = try Fixture.binding(Self.mix, unit: .percent, .absolute(resolution: 128), pickup: .catch)
        for value in [Double.nan, .infinity, -.infinity] {
            let truth = try Self.truth([percent], [Self.mix: value])
            let kept = try #require(truth.values[Self.mix]?.value)
            #expect(kept.isNaN == value.isNaN && (value.isNaN || kept == value))
            #expect(throws: ControlBindingRefusal.nonFinite) {
                try relative.resolve(input: .relative(delta: 1), truth: truth, state: .engaged(hardware: nil))
            }
            #expect(throws: ControlBindingRefusal.nonFinite) {
                try fader.resolve(input: .absolute(normalized: 0.5), truth: truth, state: .waiting(hardware: 0.2))
            }
        }
    }

    // Compile-time fence: ControlHostTruth's storage is private and its only initializer validates, so no caller
    // can skip the value cap or edit truth after it was checked.
    #if false
    static let catalog = try? ParameterCatalog([])
    static let unchecked = ControlHostTruth(storedCatalog: catalog, storedValues: [:])
    static let memberwise = ControlHostTruth(catalog: catalog, values: [:])
    static func edit(_ truth: inout ControlHostTruth) { truth.storedValues = [:]; truth.values = [:] }
    #endif

    @Test
    func hostTruthRefusalsPrecedeStaleController() throws {
        let percent = try Fixture.descriptor(Self.mix, unit: .percent, range: 0...100)
        let binding = try Fixture.binding(Self.mix, unit: .percent, .absolute(resolution: 128), pickup: .catch)
        let input = ControlInput.absolute(normalized: 0.5)
        #expect(throws: ControlBindingRefusal.targetMissing(Self.mix)) {
            try binding.resolve(input: input, truth: try Self.truth([], [Self.mix: 50]), state: .unavailable)
        }
        #expect(throws: ControlBindingRefusal.valueUnavailable(Self.mix)) {
            try binding.resolve(input: input, truth: try Self.truth([percent], [:]), state: .unavailable)
        }
        #expect(throws: ControlBindingRefusal.pickupUnavailable) {
            try binding.resolve(input: input, truth: try Self.truth([percent], [Self.mix: 50]), state: .unavailable)
        }
    }
}

extension ControlHostTruthTests {
    /// Host truth whose values carry each listed descriptor's unit; values for absent descriptors use `.percent`.
    static func truth(_ descriptors: [ParameterDescriptor],
                      _ values: [ParameterID: Double]) throws -> ControlHostTruth {
        let catalog = try ParameterCatalog(descriptors)
        let typed = values.reduce(into: [ParameterID: ParameterValue]()) { result, entry in
            result[entry.key] = ParameterValue(value: entry.value, unit: catalog[entry.key]?.unit ?? .percent)
        }
        return try ControlHostTruth(catalog: catalog, values: typed)
    }
}
