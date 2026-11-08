import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// Hand-computed values; DESIGN.md shows the arithmetic. None of these is produced by the production formula.
extension MIDIResponseCurveTests {
    @Test func linearCurvesMapEveryInputInTheirDomainToItself() {
        let velocity = MIDIResponseCurve.linear(.velocity)
        let controller = MIDIResponseCurve.linear(.controller)
        let velocityInputs: [UInt8] = Array(1...127)
        let controllerInputs: [UInt8] = Array(0...127)
        let velocityOutputs = Self.outputs(velocity, at: velocityInputs)
        let controllerOutputs = Self.outputs(controller, at: controllerInputs)
        #expect(velocityOutputs == velocityInputs)
        #expect(controllerOutputs == controllerInputs)
    }

    @Test func linearCurvesEqualTheCurvesBuiltFromTheirEndPoints() throws {
        let velocity = try Self.curve(.velocity, [(1, 1), (127, 127)])
        let controller = try Self.curve(.controller, [(0, 0), (127, 127)])
        let linearVelocity = MIDIResponseCurve.linear(.velocity)
        let linearController = MIDIResponseCurve.linear(.controller)
        #expect(velocity == linearVelocity)
        #expect(controller == linearController)
    }

    @Test func aThreePointVelocityCurveMatchesTheHandComputedValues() throws {
        let curve = try Self.curve(.velocity, [(1, 1), (64, 32), (127, 127)])
        let inputs: [UInt8] = [1, 2, 32, 63, 64, 65, 96, 126, 127]
        let expected: [UInt8] = [1, 1, 16, 32, 32, 34, 80, 125, 127]
        let actual = Self.outputs(curve, at: inputs)
        #expect(actual == expected)
    }

    @Test func anInvertedControllerCurveMatchesTheHandComputedValues() throws {
        let curve = try Self.curve(.controller, [(0, 127), (127, 0)])
        let inputs: [UInt8] = [0, 1, 63, 64, 126, 127]
        let expected: [UInt8] = [127, 126, 64, 63, 1, 0]
        let actual = Self.outputs(curve, at: inputs)
        #expect(actual == expected)
    }

    @Test func aFixedVelocityMapsEveryVelocityToItsValue() throws {
        let curve = try MIDIResponseCurve.fixedVelocity(100)
        let inputs: [UInt8] = Array(1...127)
        let expected = [UInt8](repeating: 100, count: 127)
        let actual = Self.outputs(curve, at: inputs)
        #expect(actual == expected)
    }

    @Test func aLimitedVelocityMatchesTheHandComputedValues() throws {
        let curve = try MIDIResponseCurve.limitedVelocity(low: 20, high: 90)
        let inputs: [UInt8] = [1, 2, 64, 126, 127]
        let expected: [UInt8] = [20, 21, 55, 89, 90]
        let actual = Self.outputs(curve, at: inputs)
        #expect(actual == expected)
    }

    @Test func aRiseOfOneHalfRoundsUp() throws {
        let curve = try Self.curve(.velocity, [(1, 1), (3, 2), (127, 127)])
        let inputs: [UInt8] = [1, 2, 3]
        let expected: [UInt8] = [1, 2, 2]
        let actual = Self.outputs(curve, at: inputs)
        #expect(actual == expected)
    }

    @Test func aFallOfOneHalfRoundsTowardPositiveInfinity() throws {
        let curve = try Self.curve(.controller, [(0, 127), (2, 126), (127, 0)])
        let inputs: [UInt8] = [0, 1, 2]
        let expected: [UInt8] = [127, 127, 126]
        let actual = Self.outputs(curve, at: inputs)
        #expect(actual == expected)
    }

    @Test func aFallOfTwoThirdsRoundsDownNotTowardZeroAtInputsTwoAndFour() throws {
        let curve = try Self.curve(.controller, [(0, 127), (3, 126), (127, 0)])
        let inputs: [UInt8] = [1, 2, 3, 4, 65, 127]
        let expected: [UInt8] = [127, 126, 126, 125, 63, 0]
        let actual = Self.outputs(curve, at: inputs)
        #expect(actual == expected)
    }
}
