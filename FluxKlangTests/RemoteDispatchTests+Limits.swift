import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension RemoteDispatchTests {
    static func paddedID(_ index: Int) -> String {
        let digits = String(index)
        return "bnd." + String(repeating: "0", count: 3 - digits.count) + digits
    }

    /// `count` jump bindings `bnd.000`, `bnd.001`, ... on `source`, each aimed at level A.
    static func manyBindings(_ count: Int, source: ControlSourceID = pad70) throws -> [ControlBinding] {
        try (0..<count).map { index in
            try binding(BindingID(paddedID(index)), target: levelA, source: source)
        }
    }

    /// A pickup table with every binding in a state that is not its default.
    static func movedTable(_ bindings: [ControlBinding]) -> [BindingID: PickupState] {
        Dictionary(uniqueKeysWithValues: bindings.map { ($0.id, PickupState.waiting(hardware: 0.4)) })
    }

    private static func limitCall(_ bindings: [ControlBinding]) throws -> Call {
        var limited = try call()
        limited.bindings = bindings
        limited.pickup = movedTable(bindings)
        return limited
    }

    @Test func proposeEvaluatesExactlyTheMaximumNumberOfBindings() throws {
        let result = try Self.limitCall(Self.manyBindings(256)).run()
        #expect(result.proposals.map(\.binding.rawValue) == (0..<256).map(Self.paddedID))
        #expect(result.proposals.allSatisfy { $0.operation == .set(Self.levelA, Self.normalized(1)) })
        #expect(result.held.isEmpty)
        #expect(result.refusals.isEmpty)
        #expect(result.pickup.count == 256)
        #expect(result.pickup.values.allSatisfy { $0 == .engaged(hardware: 1) })
    }

    @Test func proposeRefusesOneBindingBeyondTheMaximumWithTheSuppliedCount() throws {
        Self.expectRefused(try Self.limitCall(Self.manyBindings(257)), .tooManyBindings(257))
    }

    @Test func theBindingCapRefusalCarriesTheSuppliedCountWhateverItIs() throws {
        Self.expectRefused(try Self.limitCall(Self.manyBindings(300)), .tooManyBindings(300))
    }

    @Test func theBindingCapCountsBindingsThatDoNotMatchTheInput() throws {
        let atCap = try Self.limitCall(Self.manyBindings(256, source: Self.pad71)).run()
        Self.expectIdle(atCap, pickup: Self.movedTable(try Self.manyBindings(256, source: Self.pad71)))
        let beyond = try Self.limitCall(Self.manyBindings(257, source: Self.pad71))
        Self.expectRefused(beyond, .tooManyBindings(257))
    }

    @Test func aRepeatedBindingIdRefusesTheWholeCallEvenWhenTheOthersAreValid() throws {
        var call = try Self.movedCall()
        call.bindings.append(try Self.binding(Self.aJump, target: Self.levelB))
        Self.expectRefused(call, .duplicateBinding(Self.aJump))
    }

    @Test func aRepeatedBindingIdRefusesEvenWhenTheCopyDoesNotMatchTheInput() throws {
        var call = try Self.movedCall()
        call.bindings.append(try Self.binding(Self.aJump, target: Self.levelB, source: Self.pad71))
        Self.expectRefused(call, .duplicateBinding(Self.aJump))
    }

    @Test func theSmallestRepeatedBindingIdIsNamedWhateverTheInputOrder() throws {
        let standard = try Self.standardBindings()
        let aCopy = try Self.binding(Self.aJump, target: Self.levelB)
        let cCopy = try Self.binding(Self.cFull, target: Self.levelA)
        for extra in [[cCopy, aCopy], [aCopy, cCopy]] {
            var call = try Self.movedCall()
            call.bindings = standard + extra
            Self.expectRefused(call, .duplicateBinding(Self.aJump))
        }
    }
}
