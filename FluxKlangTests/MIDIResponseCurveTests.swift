import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// Construction, bounds and refusal order of `MIDIResponseCurve`. Golden values, transforms and ownership are in the
/// extensions of this suite.
struct MIDIResponseCurveTests {
    static func points(_ pairs: [(UInt8, UInt8)]) -> [MIDICurvePoint] {
        pairs.map { MIDICurvePoint(input: $0.0, output: $0.1) }
    }

    static func curve(_ domain: MIDICurveDomain, _ pairs: [(UInt8, UInt8)]) throws -> MIDIResponseCurve {
        try MIDIResponseCurve.make(domain: domain, points: points(pairs))
    }

    static func refusal(_ domain: MIDICurveDomain, _ pairs: [(UInt8, UInt8)]) -> MIDICurveRefusal? {
        do {
            _ = try MIDIResponseCurve.make(domain: domain, points: points(pairs))
            return nil
        } catch {
            return error
        }
    }

    /// `count` points with strictly ascending inputs from the domain start to 127 and outputs equal to the inputs.
    static func ascendingPairs(_ domain: MIDICurveDomain, count: Int) -> [(UInt8, UInt8)] {
        let start = Int(domain.lowestValue)
        let width = 127 - start
        var pairs: [(UInt8, UInt8)] = []
        for index in 0..<count {
            let value = UInt8(start + index * width / (count - 1))
            pairs.append((value, value))
        }
        return pairs
    }

    static func outputs(_ curve: MIDIResponseCurve, at inputs: [UInt8]) -> [UInt8] {
        inputs.compactMap { curve.output(for: $0) }
    }

    @Test func curveAcceptsTwoAndSixteenPointsAndRefusesZeroOneAndSeventeen() {
        let two = Self.refusal(.velocity, [(1, 1), (127, 127)])
        let sixteen = Self.refusal(.velocity, Self.ascendingPairs(.velocity, count: 16))
        let sixteenController = Self.refusal(.controller, Self.ascendingPairs(.controller, count: 16))
        let none = Self.refusal(.velocity, [])
        let one = Self.refusal(.velocity, [(1, 1)])
        let seventeen = Self.refusal(.velocity, Self.ascendingPairs(.velocity, count: 17))
        let noRefusal: MIDICurveRefusal? = nil
        let zeroPoints: MIDICurveRefusal? = .tooFewPoints(0)
        let onePoint: MIDICurveRefusal? = .tooFewPoints(1)
        let seventeenPoints: MIDICurveRefusal? = .tooManyPoints(17)
        #expect(two == noRefusal)
        #expect(sixteen == noRefusal)
        #expect(sixteenController == noRefusal)
        #expect(none == zeroPoints)
        #expect(one == onePoint)
        #expect(seventeen == seventeenPoints)
    }

    @Test func curveRefusesAFirstInputAwayFromTheDomainStart() {
        let velocity = Self.refusal(.velocity, [(2, 5), (127, 5)])
        let velocityZero = Self.refusal(.velocity, [(0, 5), (127, 5)])
        let controller = Self.refusal(.controller, [(1, 0), (127, 0)])
        let expected: MIDICurveRefusal? = .firstInputNotAtDomainStart
        #expect(velocity == expected)
        #expect(velocityZero == expected)
        #expect(controller == expected)
    }

    @Test func curveRefusesALastInputBelow127() {
        let low = Self.refusal(.velocity, [(1, 1), (100, 100)])
        let high = Self.refusal(.controller, [(0, 0), (126, 126)])
        let expected: MIDICurveRefusal? = .lastInputNot127
        #expect(low == expected)
        #expect(high == expected)
    }

    @Test func curveRefusesInputsThatDoNotStrictlyAscendAndNamesTheFirstIndex() {
        let repeated = Self.refusal(.velocity, [(1, 1), (50, 50), (50, 60), (127, 127)])
        let descending = Self.refusal(.velocity, [(1, 1), (30, 30), (90, 50), (60, 60), (30, 70), (127, 127)])
        let repeatedIndex: MIDICurveRefusal? = .inputsNotAscending(index: 2)
        let descendingIndex: MIDICurveRefusal? = .inputsNotAscending(index: 3)
        #expect(repeated == repeatedIndex)
        #expect(descending == descendingIndex)
    }

    @Test func curveRefusesOutputsOutsideTheDomainAndNamesTheFirstIndex() {
        let zeroVelocity = Self.refusal(.velocity, [(1, 0), (127, 127)])
        let firstOfTwo = Self.refusal(.velocity, [(1, 1), (64, 130), (127, 200)])
        let controllerHigh = Self.refusal(.controller, [(0, 0), (64, 5), (100, 6), (127, 128)])
        let zeroAtStart: MIDICurveRefusal? = .outputOutsideDomain(index: 0)
        let atOne: MIDICurveRefusal? = .outputOutsideDomain(index: 1)
        let atThree: MIDICurveRefusal? = .outputOutsideDomain(index: 3)
        #expect(zeroVelocity == zeroAtStart)
        #expect(firstOfTwo == atOne)
        #expect(controllerHigh == atThree)
    }

    @Test func controllerCurveMayZeroAnOutputWhileVelocityCurveRefusesIt() throws {
        let controller = try Self.curve(.controller, [(0, 0), (127, 0)])
        let atFifty = controller.output(for: 50)
        let expected: UInt8? = 0
        #expect(atFifty == expected)
    }

    @Test func velocityCurveRefusesAnyDecreaseButAcceptsRisingAndConstant() {
        let falling = Self.refusal(.velocity, [(1, 100), (64, 50), (127, 127)])
        let fullyFalling = Self.refusal(.velocity, [(1, 127), (127, 1)])
        let constant = Self.refusal(.velocity, [(1, 40), (127, 40)])
        let rising = Self.refusal(.velocity, [(1, 1), (64, 64), (127, 127)])
        let expected: MIDICurveRefusal? = .notMonotone
        let noRefusal: MIDICurveRefusal? = nil
        #expect(falling == expected)
        #expect(fullyFalling == expected)
        #expect(constant == noRefusal)
        #expect(rising == noRefusal)
    }

    @Test func controllerCurveAcceptsEitherDirectionButRefusesAMixOfBoth() {
        let rising = Self.refusal(.controller, [(0, 0), (64, 100), (127, 127)])
        let falling = Self.refusal(.controller, [(0, 127), (64, 30), (127, 0)])
        let constant = Self.refusal(.controller, [(0, 9), (127, 9)])
        let mixed = Self.refusal(.controller, [(0, 0), (64, 100), (127, 50)])
        let mixedOtherWay = Self.refusal(.controller, [(0, 100), (64, 20), (127, 90)])
        let noRefusal: MIDICurveRefusal? = nil
        let expected: MIDICurveRefusal? = .notMonotone
        #expect(rising == noRefusal)
        #expect(falling == noRefusal)
        #expect(constant == noRefusal)
        #expect(mixed == expected)
        #expect(mixedOtherWay == expected)
    }

    @Test func curveReportsTooManyPointsBeforeAWrongFirstInput() {
        var pairs = Self.ascendingPairs(.velocity, count: 17)
        pairs[0] = (2, 2)
        let refused = Self.refusal(.velocity, pairs)
        let expected: MIDICurveRefusal? = .tooManyPoints(17)
        #expect(refused == expected)
    }

    @Test func curveReportsTooFewPointsBeforeAWrongFirstInput() {
        let refused = Self.refusal(.velocity, [(5, 5)])
        let expected: MIDICurveRefusal? = .tooFewPoints(1)
        #expect(refused == expected)
    }

    @Test func curveReportsAWrongFirstInputBeforeAWrongLastInput() {
        let refused = Self.refusal(.velocity, [(2, 5), (100, 5)])
        let expected: MIDICurveRefusal? = .firstInputNotAtDomainStart
        #expect(refused == expected)
    }

    @Test func curveReportsAWrongLastInputBeforeInputsThatDoNotAscend() {
        let refused = Self.refusal(.velocity, [(1, 1), (80, 80), (60, 60), (100, 100)])
        let expected: MIDICurveRefusal? = .lastInputNot127
        #expect(refused == expected)
    }

    @Test func curveReportsInputsThatDoNotAscendBeforeAnOutputOutsideTheDomain() {
        let refused = Self.refusal(.velocity, [(1, 1), (80, 80), (60, 60), (127, 0)])
        let expected: MIDICurveRefusal? = .inputsNotAscending(index: 2)
        #expect(refused == expected)
    }

    @Test func curveReportsAnOutputOutsideTheDomainBeforeADecreasingPair() {
        let refused = Self.refusal(.velocity, [(1, 100), (64, 50), (127, 0)])
        let expected: MIDICurveRefusal? = .outputOutsideDomain(index: 2)
        #expect(refused == expected)
    }

    @Test func fixedVelocityAcceptsOneAndOneHundredTwentySevenAndRefusesZeroAndAbove() throws {
        let one = try MIDIResponseCurve.fixedVelocity(1)
        let top = try MIDIResponseCurve.fixedVelocity(127)
        let expectedPoints = Self.points([(1, 127), (127, 127)])
        #expect(top.points == expectedPoints)
        let atMiddle = one.output(for: 64)
        let expectedOne: UInt8? = 1
        #expect(atMiddle == expectedOne)
        for value: UInt8 in [0, 128, 255] {
            var caught: MIDICurveRefusal?
            do { _ = try MIDIResponseCurve.fixedVelocity(value) } catch { caught = error }
            let expected: MIDICurveRefusal? = .fixedVelocityOutOfRange(value)
            #expect(caught == expected)
        }
    }

    @Test func limitedVelocityChecksTheOrderFirstAndThenTheDomain() throws {
        let equal = try MIDIResponseCurve.limitedVelocity(low: 40, high: 40)
        let equalPoints = Self.points([(1, 40), (127, 40)])
        #expect(equal.points == equalPoints)
        var results: [MIDICurveRefusal?] = []
        for limits: [UInt8] in [[0, 50], [60, 59], [130, 5], [10, 128]] {
            do { _ = try MIDIResponseCurve.limitedVelocity(low: limits[0], high: limits[1]) } catch {
                results.append(error)
            }
        }
        let expected: [MIDICurveRefusal?] = [
            .outputOutsideDomain(index: 0), .limitOrder, .limitOrder, .outputOutsideDomain(index: 1)
        ]
        #expect(results == expected)
    }

    @Test func outputIsNilOutsideTheDomain() throws {
        let velocity = try MIDIResponseCurve.fixedVelocity(100)
        let controller = MIDIResponseCurve.linear(.controller)
        let nothing: UInt8? = nil
        let hundred: UInt8? = 100
        let zero: UInt8? = 0
        let velocityAtZero = velocity.output(for: 0)
        let velocityAtOne = velocity.output(for: 1)
        let velocityAbove = velocity.output(for: 128)
        let controllerAtZero = controller.output(for: 0)
        let controllerAbove = controller.output(for: 255)
        #expect(velocityAtZero == nothing)
        #expect(velocityAtOne == hundred)
        #expect(velocityAbove == nothing)
        #expect(controllerAtZero == zero)
        #expect(controllerAbove == nothing)
    }

    @Test func curvesBuiltFromTheSamePointsAreEqualAndDifferentPointsAreNot() throws {
        let first = try Self.curve(.velocity, [(1, 1), (64, 32), (127, 127)])
        let second = try Self.curve(.velocity, [(1, 1), (64, 32), (127, 127)])
        let other = try Self.curve(.velocity, [(1, 1), (64, 33), (127, 127)])
        let otherDomain = try Self.curve(.controller, [(0, 1), (64, 32), (127, 127)])
        #expect(first == second)
        #expect(first != other)
        #expect(first != otherDomain)
    }
}
