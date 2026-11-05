import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension PatchVariationTests {
    static func value(_ value: Double, _ unit: ParameterUnit) -> ParameterValue {
        ParameterValue(value: value, unit: unit)
    }

    /// verse: gain -6, mix 0.5; chorus: gain 0, mode 3.
    static func songPatch(_ id: StaticString = "patch.a", verseMix: Double = 0.5) throws -> ProjectPatch {
        let set = PatchVariationSet(variations: [
            PatchVariation(id: verse, label: "Verse", deltas: [
                delta(gain, -6, .decibels), delta(mix, verseMix, .normalized)
            ]),
            PatchVariation(id: chorus, label: "Chorus", deltas: [delta(mode, 3, .index), delta(gain, 0, .decibels)])
        ])
        return try PatchVariationExtension.write(set, to: patch(id))
    }

    static func plan(
        _ set: PatchVariationSet, baseline: PatchBaseline? = nil,
        from: PatchVariationID? = nil, to: PatchVariationID? = verse
    ) throws -> PatchRecallPlan {
        let table = try table()
        return try set.recallPlan(patch: PatchID(validated: "patch.a"), table: table,
                                  baseline: baseline ?? .defaults(table), from: from, to: to)
    }

    static func single(_ deltas: PatchParameterDelta...) -> PatchVariationSet {
        PatchVariationSet(variations: [PatchVariation(id: verse, label: "Verse", deltas: deltas)])
    }

    @Test
    func baselineDefaultsCoverExactlyLiveParameters() throws {
        let baseline = PatchBaseline.defaults(try Self.table())
        #expect(baseline.values == [
            Self.gain: Self.value(-90, .decibels), Self.mix: Self.value(0, .normalized),
            Self.mode: Self.value(1, .index)
        ])
    }

    @Test
    func baselineRefusesUnknownNonLiveAndInvalidValues() throws {
        let table = try Self.table()
        let unknown = ParameterID(validated: "par.unknown")
        let cases: [([ParameterID: ParameterValue], PatchVariationError)] = [
            ([unknown: Self.value(0, .normalized)], .unknownParameter(nil, unknown)),
            ([Self.routing: Self.value(0, .normalized)], .nonLiveParameter(nil, Self.routing, .structural)),
            ([Self.mix: Self.value(2, .normalized)], .invalidValue(nil, Self.mix, .outOfRange(2, lower: 0, upper: 1))),
            ([Self.mix: Self.value(1, .normalized), Self.gain: Self.value(0, .percent)],
             .invalidValue(nil, Self.gain, .unitMismatch(expected: .decibels, found: .percent))),
            ([Self.routing: Self.value(0, .normalized), Self.gain: Self.value(20, .decibels)],
             .invalidValue(nil, Self.gain, .outOfRange(20, lower: -90, upper: 10)))
        ]
        for (values, expected) in cases {
            #expect(throws: expected) { try PatchBaseline(values, table: table) }
        }
        let custom = try PatchBaseline([Self.mix: Self.value(1, .normalized)], table: table)
        #expect(custom.values.count == 1)
    }

    @Test
    func deltaValuesAreCheckedWhenPlanning() throws {
        let unknown = ParameterID(validated: "par.unknown")
        let cases: [(PatchParameterDelta, PatchVariationError?)] = [
            (Self.delta(unknown, 0, .normalized), .unknownParameter(Self.verse, unknown)),
            (Self.delta(Self.routing, 1, .normalized), .nonLiveParameter(Self.verse, Self.routing, .structural)),
            (Self.delta(Self.danger, 1, .normalized), .nonLiveParameter(Self.verse, Self.danger, .hazardous)),
            (Self.delta(Self.gain, 0, .normalized),
             .invalidValue(Self.verse, Self.gain, .unitMismatch(expected: .decibels, found: .normalized))),
            (Self.delta(Self.gain, -90, .decibels), nil),
            (Self.delta(Self.gain, (-90.0).nextDown, .decibels),
             .invalidValue(Self.verse, Self.gain, .outOfRange((-90.0).nextDown, lower: -90, upper: 10))),
            (Self.delta(Self.gain, 6, .decibels), nil),
            (Self.delta(Self.gain, (6.0).nextUp, .decibels),
             .invalidValue(Self.verse, Self.gain, .aboveCeiling((6.0).nextUp, ceiling: 6))),
            (Self.delta(Self.gain, (10.0).nextUp, .decibels),
             .invalidValue(Self.verse, Self.gain, .outOfRange((10.0).nextUp, lower: -90, upper: 10))),
            (Self.delta(Self.mix, 1, .normalized), nil),
            (Self.delta(Self.mix, (1.0).nextUp, .normalized),
             .invalidValue(Self.verse, Self.mix, .outOfRange((1.0).nextUp, lower: 0, upper: 1))),
            (Self.delta(Self.mode, 4, .index), nil),
            (Self.delta(Self.mode, 2.5, .index), .invalidValue(Self.verse, Self.mode, .notIntegral(2.5))),
            (Self.delta(Self.mix, .nan, .normalized), .invalidValue(Self.verse, Self.mix, .nonFinite))
        ]
        for (delta, expected) in cases {
            if let expected {
                #expect(throws: expected) { try Self.plan(Self.single(delta)) }
                #expect(throws: expected) { try Self.plan(Self.single(delta), from: Self.verse, to: nil) }
            } else {
                let base = PatchBaseline.defaults(try Self.table()).values[delta.parameter]
                let expected = base == delta.value ? [] : [delta.value]
                #expect(try Self.plan(Self.single(delta)).changes.map(\.to) == expected)
            }
        }
        #expect(throws: PatchVariationError.invalidValue(Self.verse, Self.mix, .nonFinite)) {
            let infinite = Self.single(Self.delta(Self.mix, .infinity, .normalized))
            return try PatchVariationExtension.write(infinite, to: Self.patch())
        }
    }

    @Test
    func deltaOutsideTheBaselineIsRefused() throws {
        let table = try Self.table()
        let baseline = try PatchBaseline([Self.gain: Self.value(0, .decibels)], table: table)
        let set = Self.single(Self.delta(Self.gain, -1, .decibels), Self.delta(Self.mix, 0.5, .normalized))
        #expect(throws: PatchVariationError.missingBaselineValue(Self.verse, Self.mix)) {
            try Self.plan(set, baseline: baseline)
        }
        #expect(throws: PatchVariationError.missingBaselineValue(Self.verse, Self.mix)) {
            try baseline.effectiveValues(of: set.variations[0])
        }
        let missingFirst = Self.single(Self.delta(Self.mix, 0.5, .normalized), Self.delta(Self.routing, 1, .normalized))
        #expect(throws: PatchVariationError.missingBaselineValue(Self.verse, Self.mix)) {
            try Self.plan(missingFirst, baseline: baseline)
        }
    }

    @Test
    func effectiveValuesOverlayTheBaselineDeterministically() throws {
        let baseline = PatchBaseline.defaults(try Self.table())
        let forward = PatchVariation(id: Self.verse, label: "Verse", deltas: [
            Self.delta(Self.mode, 2, .index), Self.delta(Self.gain, -6, .decibels)
        ])
        var reversed = forward
        reversed.deltas.reverse()
        let expected = [
            PatchParameterSetting(parameter: Self.gain, value: Self.value(-6, .decibels)),
            PatchParameterSetting(parameter: Self.mix, value: Self.value(0, .normalized)),
            PatchParameterSetting(parameter: Self.mode, value: Self.value(2, .index))
        ]
        #expect(try baseline.effectiveValues(of: forward) == expected)
        #expect(try baseline.effectiveValues(of: reversed) == expected)
        #expect(try baseline.effectiveValues(of: nil).map(\.value) == [
            Self.value(-90, .decibels), Self.value(0, .normalized), Self.value(1, .index)
        ])
    }

    @Test
    func recallPlansCarryOnlyChangedLiveParameters() throws {
        let patch = try Self.songPatch()
        let table = try Self.table()
        let baseline = PatchBaseline.defaults(table)
        func plan(_ from: PatchVariationID?, _ to: PatchVariationID?) throws -> PatchRecallPlan {
            try PatchRecallPlanner.plan(for: patch, table: table, baseline: baseline, from: from, to: to)
        }
        let toVerse = try plan(nil, Self.verse)
        #expect(toVerse == PatchRecallPlan(patch: patch.id, from: nil, to: Self.verse, changes: [
            PatchParameterChange(parameter: Self.gain, from: Self.value(-90, .decibels), to: Self.value(-6, .decibels)),
            PatchParameterChange(parameter: Self.mix, from: Self.value(0, .normalized),
                                 to: Self.value(0.5, .normalized))
        ]))
        let back = try plan(Self.verse, nil)
        let inverted = toVerse.changes.map { PatchParameterChange(parameter: $0.parameter, from: $0.to, to: $0.from) }
        #expect(back.changes == inverted)
        #expect(try plan(Self.verse, Self.verse).changes.isEmpty)
        #expect(try plan(nil, nil).changes.isEmpty)
        #expect(try plan(Self.verse, Self.chorus).changes == [
            PatchParameterChange(parameter: Self.gain, from: Self.value(-6, .decibels), to: Self.value(0, .decibels)),
            PatchParameterChange(parameter: Self.mix, from: Self.value(0.5, .normalized),
                                 to: Self.value(0, .normalized)),
            PatchParameterChange(parameter: Self.mode, from: Self.value(1, .index), to: Self.value(3, .index))
        ])
        let sameAsBase = try Self.songPatch(verseMix: 0)
        let unchanged = try PatchRecallPlanner.plan(for: sameAsBase, table: table, baseline: baseline,
                                                    from: nil, to: Self.verse)
        #expect(unchanged.changes.map(\.parameter) == [Self.gain])
        for change in try plan(Self.chorus, Self.verse).changes {
            #expect(table[change.parameter]?.controlClass == .live)
        }
    }

    @Test
    func recallRefusesMissingReferencesInOrder() throws {
        let patch = try Self.songPatch()
        let table = try Self.table()
        let baseline = PatchBaseline.defaults(table)
        let missing = PatchVariationID(validated: "bridge")
        let other = PatchVariationID(validated: "outro")
        #expect(throws: PatchVariationError.unknownVariation(missing)) {
            try PatchRecallPlanner.plan(for: patch, table: table, baseline: baseline, from: missing, to: other)
        }
        #expect(throws: PatchVariationError.unknownVariation(other)) {
            try PatchRecallPlanner.plan(for: patch, table: table, baseline: baseline, from: Self.verse, to: other)
        }
        let badFrom = PatchVariation(id: Self.verse, label: "Verse", deltas: [Self.delta(Self.routing, 1, .normalized)])
        let badTo = PatchVariation(id: Self.chorus, label: "Chorus", deltas: [Self.delta(Self.danger, 1, .normalized)])
        let both = PatchVariationSet(variations: [badTo, badFrom])
        #expect(throws: PatchVariationError.nonLiveParameter(Self.verse, Self.routing, .structural)) {
            try Self.plan(both, from: Self.verse, to: Self.chorus)
        }
        let duplicated = PatchVariationSet(variations: [badFrom, badFrom])
        #expect(throws: PatchVariationError.duplicateVariation(Self.verse)) { try Self.plan(duplicated) }
        let unrelated = PatchVariationSet(
            variations: Self.single(Self.delta(Self.mix, 1, .normalized)).variations + [badTo]
        )
        #expect(try Self.plan(unrelated).changes.count == 1)
        let invalidBaseline = PatchBaseline.defaults(try PatchParameterTable(ParameterCatalog([
            Self.descriptor(Self.mix, unit: .normalized, 0...1), Self.descriptor(Self.routing, unit: .percent, 0...100)
        ])))
        #expect(throws: PatchVariationError.nonLiveParameter(nil, Self.routing, .structural)) {
            try Self.plan(unrelated, baseline: invalidBaseline)
        }
    }

    @Test
    func patchesStayIndependent() throws {
        let table = try Self.table()
        let baseline = PatchBaseline.defaults(table)
        let first = try Self.songPatch("patch.a", verseMix: 0.25)
        var second = try Self.songPatch("patch.b", verseMix: 0.75)
        func plan(_ patch: ProjectPatch) throws -> PatchRecallPlan {
            try PatchRecallPlanner.plan(for: patch, table: table, baseline: baseline, from: nil, to: Self.verse)
        }
        let before = try plan(first)
        #expect(before.patch == first.id)
        let planB = try plan(second)
        #expect(planB.patch == second.id)
        #expect(planB.changes.last?.to == Self.value(0.75, .normalized))
        #expect(before.changes.last?.to == Self.value(0.25, .normalized))
        second = try PatchVariationExtension.write(PatchVariationSet(), to: second)
        #expect(try plan(first) == before)
        #expect(throws: PatchVariationError.unknownVariation(Self.verse)) {
            try PatchRecallPlanner.plan(for: second, table: table, baseline: baseline, from: nil, to: Self.verse)
        }
    }
}
