import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// Construction of `MIDIValueTransform`: bounds, protected controllers, refusal order and canonical ordering.
extension MIDIResponseCurveTests {
    static let velocityLinear = MIDIResponseCurve.linear(.velocity)
    static let controllerLinear = MIDIResponseCurve.linear(.controller)

    /// The controllers hand-listed as protected: bank select, data entry, pedals, data step, selectors, mode.
    static let protectedNumbers: [UInt8] = [
        0, 6, 32, 38, 64, 65, 66, 67, 96, 97, 98, 99, 100, 101, 120, 121, 122, 123, 124, 125, 126, 127
    ]

    static func entry(_ controller: UInt8, _ curve: MIDIResponseCurve = controllerLinear) -> MIDIControllerCurve {
        MIDIControllerCurve(controller: controller, curve: curve)
    }

    static func entries(_ numbers: [UInt8]) -> [MIDIControllerCurve] {
        numbers.map { entry($0) }
    }

    static func transformRefusal(
        velocity: MIDIResponseCurve? = nil, pressure: MIDIResponseCurve? = nil, controllers: [MIDIControllerCurve] = []
    ) -> MIDICurveRefusal? {
        do {
            _ = try MIDIValueTransform.make(velocity: velocity, pressure: pressure, controllers: controllers)
            return nil
        } catch {
            return error
        }
    }

    @Test func transformAcceptsSixteenControllerCurvesAndRefusesSeventeen() {
        let sixteen: [UInt8] = [1, 2, 3, 4, 5, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17]
        let seventeen: [UInt8] = sixteen + [18]
        let accepted = Self.transformRefusal(controllers: Self.entries(sixteen))
        let refused = Self.transformRefusal(controllers: Self.entries(seventeen))
        let noRefusal: MIDICurveRefusal? = nil
        let expected: MIDICurveRefusal? = .tooManyControllers(17)
        #expect(accepted == noRefusal)
        #expect(refused == expected)
    }

    @Test func transformRefusesACurveInTheWrongDomainInEachSlot() {
        let velocitySlot = Self.transformRefusal(velocity: Self.controllerLinear)
        let pressureSlot = Self.transformRefusal(pressure: Self.velocityLinear)
        let controllerSlot = Self.transformRefusal(controllers: [Self.entry(10, Self.velocityLinear)])
        let expected: MIDICurveRefusal? = .wrongDomain
        #expect(velocitySlot == expected)
        #expect(pressureSlot == expected)
        #expect(controllerSlot == expected)
    }

    @Test func transformRefusesAWrongDomainCurveInTheVelocitySlotAlone() {
        let refused = Self.transformRefusal(velocity: Self.controllerLinear)
        let expected: MIDICurveRefusal? = .wrongDomain
        #expect(refused == expected)
    }

    @Test func transformRefusesAWrongDomainCurveInThePressureSlotAlone() {
        let refused = Self.transformRefusal(pressure: Self.velocityLinear)
        let expected: MIDICurveRefusal? = .wrongDomain
        #expect(refused == expected)
    }

    @Test func transformRefusesAWrongDomainCurveInAControllerSlotAlone() {
        let refused = Self.transformRefusal(controllers: [Self.entry(10, Self.velocityLinear)])
        let expected: MIDICurveRefusal? = .wrongDomain
        #expect(refused == expected)
    }

    @Test func transformNamesTheFirstOffendingControllerInTheOrderGiven() {
        let outOfRange = Self.transformRefusal(controllers: Self.entries([20, 150, 200]))
        let protected = Self.transformRefusal(controllers: Self.entries([20, 64, 0]))
        let duplicate = Self.transformRefusal(controllers: Self.entries([5, 7, 5, 7]))
        let expectedRange: MIDICurveRefusal? = .controllerOutOfRange(150)
        let expectedProtected: MIDICurveRefusal? = .protectedController(64)
        let expectedDuplicate: MIDICurveRefusal? = .duplicateController(5)
        #expect(outOfRange == expectedRange)
        #expect(protected == expectedProtected)
        #expect(duplicate == expectedDuplicate)
    }

    @Test func transformReportsTooManyControllersBeforeAWrongDomain() {
        var controllers = Self.entries([1, 2, 3, 4, 5, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18])
        controllers[0] = Self.entry(1, Self.velocityLinear)
        let refused = Self.transformRefusal(controllers: controllers)
        let expected: MIDICurveRefusal? = .tooManyControllers(17)
        #expect(refused == expected)
    }

    @Test func transformReportsAWrongDomainBeforeAControllerOutOfRange() {
        let wrongCurve = Self.entry(10, Self.velocityLinear)
        let outOfRangeFirst = Self.transformRefusal(controllers: [Self.entry(200), wrongCurve])
        let wrongDomainFirst = Self.transformRefusal(controllers: [wrongCurve, Self.entry(200)])
        let expected: MIDICurveRefusal? = .wrongDomain
        #expect(outOfRangeFirst == expected)
        #expect(wrongDomainFirst == expected)
    }

    @Test func transformReportsAControllerOutOfRangeBeforeAProtectedController() {
        let protectedFirst = Self.transformRefusal(controllers: Self.entries([64, 200]))
        let outOfRangeFirst = Self.transformRefusal(controllers: Self.entries([200, 64]))
        let expected: MIDICurveRefusal? = .controllerOutOfRange(200)
        #expect(protectedFirst == expected)
        #expect(outOfRangeFirst == expected)
    }

    @Test func transformReportsAProtectedControllerBeforeADuplicate() {
        let duplicateFirst = Self.transformRefusal(controllers: Self.entries([10, 10, 64]))
        let protectedFirst = Self.transformRefusal(controllers: Self.entries([64, 10, 10]))
        let expected: MIDICurveRefusal? = .protectedController(64)
        #expect(duplicateFirst == expected)
        #expect(protectedFirst == expected)
    }

    @Test func transformRefusesADuplicateControllerAndNamesIt() {
        let refused = Self.transformRefusal(controllers: Self.entries([30, 10, 20, 10]))
        let expected: MIDICurveRefusal? = .duplicateController(10)
        #expect(refused == expected)
    }

    @Test func transformRefusesExactlyTheHandListedProtectedControllers() {
        var refusedNumbers: [UInt8] = []
        var acceptedNumbers: [UInt8] = []
        for number: UInt8 in 0...127 {
            let refusal = Self.transformRefusal(controllers: Self.entries([number]))
            let protectedRefusal: MIDICurveRefusal? = .protectedController(number)
            let noRefusal: MIDICurveRefusal? = nil
            if refusal == protectedRefusal { refusedNumbers.append(number) }
            if refusal == noRefusal { acceptedNumbers.append(number) }
        }
        let allNumbers: [UInt8] = Array(0...127)
        let expectedAccepted = allNumbers.filter { !Self.protectedNumbers.contains($0) }
        #expect(refusedNumbers == Self.protectedNumbers)
        #expect(acceptedNumbers == expectedAccepted)
    }

    @Test func transformRefusesControllerNumbersAbove127() {
        let first = Self.transformRefusal(controllers: Self.entries([128]))
        let last = Self.transformRefusal(controllers: Self.entries([255]))
        let expectedFirst: MIDICurveRefusal? = .controllerOutOfRange(128)
        let expectedLast: MIDICurveRefusal? = .controllerOutOfRange(255)
        #expect(first == expectedFirst)
        #expect(last == expectedLast)
    }

    @Test func transformSortsControllerCurvesSoOrderDoesNotChangeTheValue() throws {
        let scrambled = try MIDIValueTransform.make(
            velocity: nil, pressure: nil, controllers: Self.entries([30, 10, 20])
        )
        let ordered = try MIDIValueTransform.make(
            velocity: nil, pressure: nil, controllers: Self.entries([10, 20, 30])
        )
        let numbers = scrambled.controllers.map(\.controller)
        let expectedNumbers: [UInt8] = [10, 20, 30]
        #expect(scrambled == ordered)
        #expect(numbers == expectedNumbers)
    }

    @Test func transformKeepsTheSlotsItWasGiven() throws {
        let fixed = try MIDIResponseCurve.fixedVelocity(90)
        let transform = try MIDIValueTransform.make(velocity: fixed, pressure: Self.controllerLinear, controllers: [])
        let velocitySlot = transform.velocity
        let pressureSlot = transform.pressure
        let expectedVelocity: MIDIResponseCurve? = fixed
        let expectedPressure: MIDIResponseCurve? = Self.controllerLinear
        #expect(velocitySlot == expectedVelocity)
        #expect(pressureSlot == expectedPressure)
        #expect(transform.controllers.isEmpty)
    }

    @Test func theIdentityTransformHasNoCurvesAndEqualsAnEmptyBuild() throws {
        let built = try MIDIValueTransform.make(velocity: nil, pressure: nil, controllers: [])
        let identity = MIDIValueTransform.identity
        let noCurve: MIDIResponseCurve? = nil
        #expect(built == identity)
        #expect(identity.velocity == noCurve)
        #expect(identity.pressure == noCurve)
        #expect(identity.controllers.isEmpty)
    }

    @Test func transformsBuiltTwiceFromTheSameInputsAreEqual() throws {
        let curve = try Self.curve(.controller, [(0, 127), (127, 0)])
        let first = try MIDIValueTransform.make(velocity: nil, pressure: curve, controllers: [Self.entry(10, curve)])
        let second = try MIDIValueTransform.make(velocity: nil, pressure: curve, controllers: [Self.entry(10, curve)])
        let other = try MIDIValueTransform.make(velocity: nil, pressure: curve, controllers: [Self.entry(11, curve)])
        #expect(first == second)
        #expect(first != other)
    }
}
