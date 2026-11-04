import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension ControlBindingTests {
    @Test
    func relativeTurnNeverMovesAgainstItsDirection() throws {
        let capped = try Self.descriptor(Self.level, unit: .decibels, range: -90...10, ceiling: 0)
        let level = try Self.binding(Self.level, unit: .decibels, .twosComplement(width: .seven), step: 0.5)
        #expect(try Self.set(level, .relative(delta: 1), current: 3, capped) == nil)
        #expect(try Self.set(level, .relative(delta: -1), current: 3, capped) == 0)
        let percent = try Self.descriptor(Self.mix, unit: .percent, range: 0...100)
        let floor = try Self.binding(Self.mix, unit: .percent, .binaryOffset(width: .seven), step: 5,
                                     lower: 20, upper: 80)
        #expect(try Self.set(floor, .relative(delta: -1), current: 10, percent) == nil)
        #expect(try Self.set(floor, .relative(delta: 1), current: 10, percent) == 20)
    }

    @Test
    func faderTaperRefusesAbsoluteButAllowsRelativeSteps() throws {
        let gain = try Self.descriptor(Self.level, unit: .decibels, range: -90...10, curve: .faderTaper)
        let absolute = try Self.binding(Self.level, unit: .decibels, .absolute(resolution: 128))
        #expect(throws: ControlBindingRefusal.undefinedCurve(.faderTaper)) { try absolute.validate(against: gain) }
        #expect(throws: ControlBindingRefusal.undefinedCurve(.faderTaper)) {
            try Self.set(absolute, .absolute(normalized: 0.25), current: -20, gain)
        }
        #expect(throws: ControlBindingRefusal.undefinedCurve(.faderTaper)) {
            try ControlBinding.value(at: 0.5, over: -90...10, curve: .faderTaper)
        }
        let relative = try Self.binding(Self.level, unit: .decibels, .signMagnitude(width: .seven), step: 0.5)
        #expect(try Self.set(relative, .relative(delta: 1), current: -10, gain) == -9.5)
        #expect(try Self.set(relative, .relative(delta: -3), current: -10, gain) == -11.5)
    }

    @Test
    func steppedTurnsFromNonIntegralHostTruthMoveAtMostDeltaSteps() throws {
        let index = try Self.descriptor(Self.colour, unit: .index, range: 1...12, curve: .stepped)
        let single = try Self.binding(Self.colour, unit: .index, .twosComplement(width: .seven), step: 1)
        #expect(try Self.set(single, .relative(delta: 1), current: 2.5, index) == 3)
        #expect(try Self.set(single, .relative(delta: -1), current: 2.5, index) == 2)
        #expect(try Self.set(single, .relative(delta: 2), current: 2.5, index) == 4)
        let double = try Self.binding(Self.colour, unit: .index, .twosComplement(width: .seven), step: 2)
        #expect(try Self.set(double, .relative(delta: 1), current: 2.5, index) == 4)
        #expect(try Self.set(double, .relative(delta: -1), current: 2.5, index) == 1)
    }

    @Test
    func extremeDeltasClampAtBothBounds() throws {
        let percent = try Self.descriptor(Self.mix, unit: .percent, range: 0...100)
        let binding = try Self.binding(Self.mix, unit: .percent, .twosComplement(width: .seven), step: 5)
        #expect(try Self.set(binding, .relative(delta: .max), current: 50, percent) == 100)
        #expect(try Self.set(binding, .relative(delta: .min), current: 50, percent) == 0)
        #expect(try Self.set(binding, .relative(delta: .max), current: 100, percent) == nil)
        #expect(try Self.set(binding, .relative(delta: .min), current: 0, percent) == nil)
        #expect(try Self.set(binding, .relative(delta: .min), current: 100, percent) == 0)
        #expect(try Self.set(binding, .relative(delta: .max), current: 0, percent) == 100)
        let index = try Self.descriptor(Self.colour, unit: .index, range: 1...12, curve: .stepped)
        let stepped = try Self.binding(Self.colour, unit: .index, .twosComplement(width: .seven), step: 1)
        #expect(try Self.set(stepped, .relative(delta: .max), current: 2.5, index) == 12)
        #expect(try Self.set(stepped, .relative(delta: .min), current: 2.5, index) == 1)
    }

    @Test
    func bindingUpperAboveCeilingIsCappedAtCeiling() throws {
        let capped = try Self.descriptor(Self.level, unit: .decibels, range: -90...10, ceiling: 0)
        let absolute = try Self.binding(Self.level, unit: .decibels, .absolute(resolution: 128), upper: 6)
        #expect(try absolute.validate(against: capped) == -90...0)
        #expect(try Self.set(absolute, .absolute(normalized: 1), current: -20, capped) == 0)
    }

    @Test(arguments: [ControlClass.safety, .proposal])
    func safetyAndProposalTargetsCannotExistAsBindableDescriptors(controlClass: ControlClass) {
        #expect(throws: (any Error).self) {
            try Self.descriptor(Self.mix, unit: .percent, range: 0...100, controlClass: controlClass)
        }
    }

    @Test
    func profileWireFormatKeepsNestedUnknownsAndRefusesUnknownCases() throws {
        let wire = #"{"id":"bnd.enc2-mains","profile":{"twosComplement":{"later":true,"width":7}},"#
            + #""source":"ctl.enc-2","step":0.5,"target":"par.mains.gain","unit":"decibels","upper":0}"#
        let decoded = try ContractCoding.decode(ControlBinding.self, from: Data(wire.utf8))
        #expect(decoded.fields == Self.encoder2Fields)
        #expect(try ContractCoding.makeEncoder().encode(decoded) == Data(wire.utf8))
        for replacement in [#"{"relativeOffset":{"width":7}}"#, #"{"twosComplement":{"width":8}}"#,
                            #"{"twosComplement":{}}"#] {
            let invalid = wire.replacingOccurrences(of: #"{"twosComplement":{"later":true,"width":7}}"#,
                                                    with: replacement)
            #expect(throws: (any Error).self) {
                try ContractCoding.decode(ControlBinding.self, from: Data(invalid.utf8))
            }
        }
    }

    @Test(arguments: EncoderBitWidth.allCases)
    func relativeDecodesMatchIndependentFormulas(width: EncoderBitWidth) throws {
        let bits = width.rawValue
        let half = bits == 7 ? 64 : 8192
        let raws = bits == 7 ? Array(0...127) : Array(stride(from: 0, to: 16_384, by: 61)) + [8191, 8192, 16_383]
        for raw in raws {
            let signExtended = (raw << (Int.bitWidth - bits)) >> (Int.bitWidth - bits)
            #expect(try EncoderProfile.twosComplement(width: width).decode(raw: raw) == .relative(delta: signExtended))
            #expect(try EncoderProfile.binaryOffset(width: width).decode(raw: raw) == .relative(delta: raw - half))
            let signMagnitude = raw >= half ? half - raw : raw
            #expect(try EncoderProfile.signMagnitude(width: width).decode(raw: raw) == .relative(delta: signMagnitude))
        }
    }
}
