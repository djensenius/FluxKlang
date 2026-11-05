import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

@Suite("Patch variation repair")
struct PatchVariationRepairTests {
    typealias Fixture = PatchVariationTests
    static let key = Fixture.key

    static func id(_ raw: String) throws -> PatchVariationID { try PatchVariationID(raw) }

    static func variation(_ id: String, _ label: String = "L", deltas: [JSONValue] = []) -> JSONValue {
        .object(["id": .string(id), "label": .string(label), "deltas": .array(deltas)])
    }

    static func delta(_ parameter: String, _ value: Double = 0.5, unit: String = "normalized") -> JSONValue {
        .object(["parameter": .string(parameter), "value": .double(value), "unit": .string(unit)])
    }

    static func stored(_ variations: [JSONValue], version: JSONValue = .int(1)) -> JSONValue {
        .object(["version": version, "variations": .array(variations)])
    }

    static func patch(_ value: JSONValue, foreign: [String: JSONValue] = ["other": .int(1)]) -> ProjectPatch {
        var extensions = foreign
        extensions[key] = value
        return Fixture.patch(extensions: extensions)
    }

    static func numbered(_ count: Int) -> [JSONValue] { (0..<count).map { variation("v.\($0)", "V \($0)") } }

    static let source = #"{"extensions":{"a.first":{"list":[1,2.5,"x",null],"z":true},"#
        + #""fluxklang.patchVariations":{"variations":"oops","version":1},"zz.last":-0.125},"#
        + #""graph":"graph.main","id":"patch.a","label":"Patch","stray":{"q":1}}"#

    @Test
    func discardLeavesOtherExtensionKeysUntouched() throws {
        let original = try Fixture.patch(raw: Self.source)
        #expect(throws: PatchVariationError.malformed) { try PatchVariationExtension.read(from: original) }
        let discarded = try PatchVariationRepair.discard(from: original)
        let expected = #"{"extensions":{"a.first":{"list":[1,2.5,"x",null],"z":true},"zz.last":-0.125},"#
            + #""graph":"graph.main","id":"patch.a","label":"Patch","stray":{"q":1}}"#
        #expect(try Fixture.canonical(discarded) == Data(expected.utf8))
        for name in ["a.first", "zz.last"] {
            #expect(try Fixture.canonical(discarded.extensions?[name]) == Fixture.canonical(original.extensions?[name]))
        }
        #expect(discarded.unknownFields == original.unknownFields)
        #expect(try PatchVariationExtension.content(of: discarded) == .absent)
        let only = Fixture.patch(extensions: [Self.key: Self.stored(Self.numbered(129))])
        #expect(try PatchVariationRepair.discard(from: only) == Fixture.patch())
    }

    @Test
    func discardTakesAnyReadableOrUnreadableCurrentValue() throws {
        let values: [JSONValue] = [
            Self.stored(Self.numbered(2)), Self.stored(Self.numbered(129)), .string("nope"), .null,
            Self.stored([], version: .string("1")), Self.stored([], version: .int(0)),
            Self.stored([Self.variation("bad id")])
        ]
        for value in values {
            let discarded = try PatchVariationRepair.discard(from: Self.patch(value))
            #expect(discarded == Fixture.patch(extensions: ["other": .int(1)]))
        }
    }

    @Test
    func futureVersionCannotBeRepaired() throws {
        let futures: [(JSONValue, Int)] = [
            (Self.stored(Self.numbered(1), version: .int(2)), 2),
            (.object(["version": .double(3), "variations": .string("opaque")]), 3),
            (.object(["version": .uint(.max)]), Int.max)
        ]
        for (value, version) in futures {
            let patch = Self.patch(value)
            #expect(throws: PatchVariationEditRefusal.futureVersionNotRepairable(version)) {
                try PatchVariationRepair.discard(from: patch)
            }
            #expect(throws: PatchVariationEditRefusal.futureVersionNotRepairable(version)) {
                try PatchVariationRepair.salvage(patch)
            }
            #expect(try PatchVariationExtension.content(of: patch) == .future(version: version))
        }
    }

    @Test
    func absentKeyHasNothingToRepair() throws {
        for patch in [Fixture.patch(), Fixture.patch(extensions: ["other": .int(1)])] {
            #expect(throws: PatchVariationEditRefusal.nothingToRepair) { try PatchVariationRepair.discard(from: patch) }
            #expect(throws: PatchVariationEditRefusal.nothingToRepair) { try PatchVariationRepair.salvage(patch) }
        }
    }

    @Test
    func salvagingOneHundredTwentyNineKeepsTheFirstOneHundredTwentyEight() throws {
        let patch = Self.patch(Self.stored(Self.numbered(129)))
        let salvage = try PatchVariationRepair.salvage(patch)
        #expect(salvage.drops == [.overVariationLimit(index: 128, try Self.id("v.128"))])
        let set = try PatchVariationExtension.read(from: salvage.patch)
        #expect(set.variations == Array(try Fixture.numbered(128)))
        #expect(salvage.patch.extensions?["other"] == .int(1))
        let more = try PatchVariationRepair.salvage(Self.patch(Self.stored(Self.numbered(131))))
        #expect(more.drops == [
            .overVariationLimit(index: 128, try Self.id("v.128")),
            .overVariationLimit(index: 129, try Self.id("v.129")),
            .overVariationLimit(index: 130, try Self.id("v.130"))
        ])
    }

    @Test
    func limitCountsOnlyKeptVariations() throws {
        var items = Self.numbered(128)
        items.insert(Self.variation("v.0", "Again"), at: 1)
        items.insert(.int(7), at: 0)
        let salvage = try PatchVariationRepair.salvage(Self.patch(Self.stored(items)))
        #expect(salvage.drops == [.malformedVariation(index: 0), .duplicateVariation(index: 2, try Self.id("v.0"))])
        #expect(try PatchVariationExtension.read(from: salvage.patch).variations.count == 128)
        let relabelled = try PatchVariationRepair.salvage(Self.patch(Self.stored([
            Self.variation("x", ""), Self.variation("x", "X")
        ])))
        #expect(relabelled.drops == [.invalidLabel(index: 0, try Self.id("x"))])
        #expect(try PatchVariationExtension.read(from: relabelled.patch).variations.map(\.label) == ["X"])
    }

    @Test
    func salvageReportsEveryDropInDocumentOrder() throws {
        var kept = Self.variation("keep", "Keep", deltas: [
            Self.delta("par.mix"), Self.delta("bad id"), Self.delta("par.gain", unit: "furlongs"),
            Self.delta("par.mix", 0.25), .string("x"), Self.delta("par.gain", -3, unit: "decibels")
        ])
        if case .object(var fields) = kept {
            fields["stray"] = .int(9)
            fields["extensions"] = .object(["note": .bool(true)])
            kept = .object(fields)
        }
        let items: [JSONValue] = [
            Self.variation("bad id"), Self.variation("label", " padded", deltas: [.null]), kept,
            .object(["id": .string("nodeltas"), "label": .string("N")]), Self.variation("keep", "Twin"),
            .object(["id": .string("labelnum"), "label": .int(1), "deltas": .array([])]),
            Self.variation("second", "Second", deltas: [.null])
        ]
        let salvage = try PatchVariationRepair.salvage(Self.patch(Self.stored(items)))
        let keep = try Self.id("keep")
        let second = try Self.id("second")
        #expect(salvage.drops == [
            .malformedVariation(index: 0), .invalidLabel(index: 1, try Self.id("label")),
            .malformedDelta(keep, index: 1), .malformedDelta(keep, index: 2),
            .duplicateDelta(keep, index: 3, ParameterID(validated: "par.mix")), .malformedDelta(keep, index: 4),
            .malformedVariation(index: 3), .duplicateVariation(index: 4, keep), .malformedVariation(index: 5),
            .malformedDelta(second, index: 0)
        ])
        let set = try PatchVariationExtension.read(from: salvage.patch)
        var expected = PatchVariation(id: keep, label: "Keep", deltas: [
            Fixture.delta(Fixture.mix, 0.5, .normalized), Fixture.delta(Fixture.gain, -3, .decibels)
        ], extensions: ["note": .bool(true)])
        expected.unknownFields = ["stray": .int(9)]
        #expect(set.variations == [expected, PatchVariation(id: second, label: "Second")])
    }

    @Test
    func salvageDeltaLimitPins() throws {
        let deltas = (0...4096).map { Self.delta("p.\($0)") }
        let salvage = try PatchVariationRepair.salvage(Self.patch(Self.stored([
            Self.variation("over", "Over", deltas: deltas),
            Self.variation("at", "At", deltas: Array(deltas.prefix(4096)))
        ])))
        #expect(salvage.drops == [.overDeltaLimit(try Self.id("over"), index: 4096, ParameterID(validated: "p.4096"))])
        let set = try PatchVariationExtension.read(from: salvage.patch)
        #expect(set.variations.map(\.deltas.count) == [4096, 4096])
        #expect(set.variations[0].deltas.last?.parameter == ParameterID(validated: "p.4095"))
        let duplicateAfter = try PatchVariationRepair.salvage(Self.patch(Self.stored([
            Self.variation("over", "Over", deltas: deltas + [Self.delta("p.0")])
        ])))
        #expect(duplicateAfter.drops == [
            .overDeltaLimit(try Self.id("over"), index: 4096, ParameterID(validated: "p.4096")),
            .duplicateDelta(try Self.id("over"), index: 4097, ParameterID(validated: "p.0"))
        ])
    }

    @Test
    func salvageKeepsSetFieldsAndDropsMalformedSetExtensions() throws {
        let value: JSONValue = .object([
            "version": .double(1), "variations": .array([Self.variation("v", " bad")]), "stray": .string("kept"),
            "extensions": .string("not an object")
        ])
        let salvage = try PatchVariationRepair.salvage(Self.patch(value))
        #expect(salvage.drops == [.malformedSetExtensions, .invalidLabel(index: 0, try Self.id("v"))])
        let set = try PatchVariationExtension.read(from: salvage.patch)
        #expect(set.variations.isEmpty && set.extensions == nil && set.unknownFields == ["stray": .string("kept")])
        let annotated = try PatchVariationRepair.salvage(Self.patch(.object([
            "version": .int(1), "variations": .array(Self.numbered(129)), "extensions": .object(["s": .int(7)])
        ])))
        #expect(try PatchVariationExtension.read(from: annotated.patch).extensions == ["s": .int(7)])
        let nullBag = try PatchVariationRepair.salvage(Self.patch(.object([
            "version": .int(1), "variations": .array([.null]), "extensions": .null
        ])))
        #expect(nullBag.drops == [.malformedVariation(index: 0)])
    }

    @Test
    func salvageThatKeepsNothingRemovesTheKey() throws {
        let salvage = try PatchVariationRepair.salvage(Self.patch(Self.stored([.null, Self.variation("x", "")])))
        #expect(salvage.drops == [.malformedVariation(index: 0), .invalidLabel(index: 1, try Self.id("x"))])
        #expect(salvage.patch == Fixture.patch(extensions: ["other": .int(1)]))
        let alone = try PatchVariationRepair.salvage(Self.patch(Self.stored([.null]), foreign: [:]))
        #expect(alone.patch == Fixture.patch())
    }

    @Test
    func readableSetIsReturnedUnchanged() throws {
        let value: JSONValue = .object(["version": .double(1), "variations": .array(Self.numbered(2))])
        let patch = Self.patch(value)
        let salvage = try PatchVariationRepair.salvage(patch)
        #expect(salvage.drops.isEmpty)
        #expect(salvage.patch == patch)
        #expect(salvage.patch.extensions?[Self.key] == value)
    }

    @Test
    func valuesWithoutItemsAreNotSalvageable() throws {
        let cases: [(JSONValue, PatchVariationSalvageBlocker)] = [
            (.string("nope"), .notAnObject), (.array([]), .notAnObject), (.null, .notAnObject),
            (.object(["variations": .array([])]), .malformedVersion),
            (Self.stored(Self.numbered(1), version: .string("1")), .malformedVersion),
            (Self.stored(Self.numbered(1), version: .int(0)), .malformedVersion),
            (Self.stored(Self.numbered(1), version: .double(1.5)), .malformedVersion),
            (.object(["version": .int(1)]), .variationsNotAnArray),
            (.object(["version": .int(1), "variations": .string("oops")]), .variationsNotAnArray)
        ]
        for (value, blocker) in cases {
            let patch = Self.patch(value)
            #expect(throws: PatchVariationEditRefusal.notSalvageable(blocker)) {
                try PatchVariationRepair.salvage(patch)
            }
        }
        #expect(throws: PatchVariationEditRefusal.notSalvageable(.variationsNotAnArray)) {
            try PatchVariationRepair.salvage(Fixture.patch(raw: Self.source))
        }
    }

    @Test
    func repairIsNeverPartOfReading() throws {
        let patch = Self.patch(Self.stored(Self.numbered(129)))
        let refusal = PatchVariationError.tooManyVariations(count: 129, maximum: 128)
        #expect(throws: refusal) { try PatchVariationExtension.read(from: patch) }
        #expect(throws: PatchVariationEditRefusal.invalid(refusal)) { try PatchVariationEditor.open(patch) }
        _ = try PatchVariationRepair.salvage(patch)
        _ = try PatchVariationRepair.discard(from: patch)
        #expect(patch == Self.patch(Self.stored(Self.numbered(129))))
        let salvaged = try PatchVariationRepair.salvage(patch).patch
        var editor = try PatchVariationEditor.open(salvaged)
        #expect(throws: PatchVariationEditRefusal.invalid(refusal)) { try editor.add(Self.id("again"), label: "Again") }
        try editor.delete(Self.id("v.0"))
        try editor.add(try Self.id("again"), label: "Again")
        #expect(try PatchVariationExtension.read(from: editor.write(to: salvaged)) == editor.set)
        #expect(throws: PatchVariationEditRefusal.invalid(.malformed)) { try editor.write(to: Self.patch(.null)) }
    }
}
