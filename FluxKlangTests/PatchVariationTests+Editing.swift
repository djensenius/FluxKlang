import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

@Suite("Patch variation editing", .productionAccessAudit)
struct PatchVariationEditingTests {
    typealias Fixture = PatchVariationTests
    static let verse = Fixture.verse
    static let chorus = Fixture.chorus
    static let bridge = PatchVariationID(validated: "bridge")

    static func value(_ number: Double, _ unit: ParameterUnit) -> ParameterValue {
        ParameterValue(value: number, unit: unit)
    }

    /// verse: gain -6, mix 0.5 (gain carries an extension bag); chorus: mode 3.
    static func editor() throws -> PatchVariationEditor {
        var gain = Fixture.delta(Fixture.gain, -6, .decibels)
        gain.extensions = ["note": .string("kept")]
        return try PatchVariationEditor.make(PatchVariationSet(variations: [
            PatchVariation(id: verse, label: "Verse", deltas: [gain, Fixture.delta(Fixture.mix, 0.5, .normalized)]),
            PatchVariation(id: chorus, label: "Chorus", deltas: [Fixture.delta(Fixture.mode, 3, .index)])
        ]))
    }

    static func capture(
        _ editor: inout PatchVariationEditor, _ parameters: [ParameterID],
        _ current: [ParameterID: ParameterValue], into id: PatchVariationID = verse,
        baseline: PatchBaseline? = nil, table: PatchParameterTable? = nil
    ) throws(PatchVariationEditRefusal) {
        let table = table ?? (try? Fixture.table())!
        try editor.capture(parameters, from: current, into: id, baseline: baseline ?? .defaults(table), table: table)
    }

    /// Runs `edit` on a copy, expects `refusal`, and expects the copy unchanged.
    static func expectRefused(
        _ editor: PatchVariationEditor, _ refusal: PatchVariationEditRefusal,
        sourceLocation: SourceLocation = #_sourceLocation,
        _ edit: (inout PatchVariationEditor) throws -> Void
    ) {
        var copy = editor
        #expect(throws: refusal, sourceLocation: sourceLocation) { try edit(&copy) }
        #expect(copy == editor, sourceLocation: sourceLocation)
    }

    @Test
    func equalValueGivesNoDeltaAndRemovesAnExistingOne() throws {
        var editor = try Self.editor()
        // Baseline defaults: gain -90 dB, mix 0, mode 1.
        try Self.capture(&editor, [Fixture.gain], [Fixture.gain: Self.value(-90, .decibels)])
        #expect(editor.set[Self.verse]?.deltas == [Fixture.delta(Fixture.mix, 0.5, .normalized)])
        try Self.capture(&editor, [Fixture.mode], [Fixture.mode: Self.value(1, .index)])
        #expect(editor.set[Self.verse]?.deltas == [Fixture.delta(Fixture.mix, 0.5, .normalized)])
        try Self.capture(&editor, [Fixture.mix], [Fixture.mix: Self.value(0, .normalized)])
        #expect(editor.set[Self.verse]?.deltas == [])
        // -0.0 equals the +0.0 baseline: no delta is stored for the sign of zero.
        try Self.capture(&editor, [Fixture.mix], [Fixture.mix: Self.value(-0.0, .normalized)])
        #expect(editor.set[Self.verse]?.deltas == [])
        try Self.capture(&editor, [Fixture.mix], [Fixture.mix: Self.value(0.5, .normalized)])
        try Self.capture(&editor, [Fixture.mix], [Fixture.mix: Self.value(-0.0, .normalized)])
        #expect(editor.set[Self.verse]?.deltas == [])
        let baseline = try PatchBaseline([Fixture.mix: Self.value(0.25, .normalized)], table: Fixture.table())
        try Self.capture(&editor, [Fixture.mix], [Fixture.mix: Self.value(0.25, .normalized)], baseline: baseline)
        #expect(editor.set[Self.verse]?.deltas == [])
        try Self.capture(&editor, [Fixture.mix], [Fixture.mix: Self.value(0, .normalized)], baseline: baseline)
        #expect(editor.set[Self.verse]?.deltas == [Fixture.delta(Fixture.mix, 0, .normalized)])
    }

    @Test
    func captureUpdatesInPlaceAppendsInListOrderAndKeepsUnlisted() throws {
        var editor = try Self.editor()
        try Self.capture(&editor, [Fixture.mode, Fixture.gain], [
            Fixture.gain: Self.value(-3, .decibels), Fixture.mode: Self.value(4, .index),
            Fixture.mix: Self.value(1, .normalized)
        ])
        var gain = Fixture.delta(Fixture.gain, -3, .decibels)
        gain.extensions = ["note": .string("kept")]
        #expect(editor.set[Self.verse]?.deltas == [
            gain, Fixture.delta(Fixture.mix, 0.5, .normalized), Fixture.delta(Fixture.mode, 4, .index)
        ])
        #expect(editor.set[Self.chorus] == (try Self.editor()).set[Self.chorus])
        let before = editor
        try Self.capture(&editor, [], [:])
        #expect(editor == before)
    }

    @Test
    func unknownAndNonLiveParametersRefuseTheWholeCapture() throws {
        let editor = try Self.editor()
        let unknown = ParameterID(validated: "par.unknown")
        let current: [ParameterID: ParameterValue] = [
            Fixture.mix: Self.value(1, .normalized), unknown: Self.value(0, .normalized),
            Fixture.routing: Self.value(1, .normalized), Fixture.danger: Self.value(1, .normalized)
        ]
        let cases: [([ParameterID], PatchVariationEditRefusal)] = [
            ([Fixture.mix, unknown], .invalid(.unknownParameter(Self.verse, unknown))),
            ([unknown, Fixture.mix], .invalid(.unknownParameter(Self.verse, unknown))),
            ([Fixture.mix, Fixture.routing], .invalid(.nonLiveParameter(Self.verse, Fixture.routing, .structural))),
            ([Fixture.mix, Fixture.danger], .invalid(.nonLiveParameter(Self.verse, Fixture.danger, .hazardous)))
        ]
        for (parameters, refusal) in cases {
            Self.expectRefused(editor, refusal) { try Self.capture(&$0, parameters, current) }
        }
        // Refused even when no current value is supplied for it.
        Self.expectRefused(editor, .invalid(.unknownParameter(Self.verse, unknown))) {
            try Self.capture(&$0, [Fixture.mix, unknown], [Fixture.mix: Self.value(1, .normalized)])
        }
        Self.expectRefused(editor, .invalid(.nonLiveParameter(Self.verse, Fixture.routing, .structural))) {
            try Self.capture(&$0, [Fixture.routing], [:])
        }
    }

    @Test
    func otherCaptureRefusalsLeaveTheSetUnchanged() throws {
        let editor = try Self.editor()
        let mix = [Fixture.mix: Self.value(1, .normalized)]
        Self.expectRefused(editor, .missingCurrentValue(Fixture.gain)) {
            try Self.capture(&$0, [Fixture.mix, Fixture.gain], mix)
        }
        Self.expectRefused(editor, .repeatedParameter(Fixture.mix)) {
            try Self.capture(&$0, [Fixture.mix, Fixture.mix], mix)
        }
        let range = PatchVariationEditRefusal.invalid(
            .invalidValue(Self.verse, Fixture.mix, .outOfRange(2, lower: 0, upper: 1))
        )
        Self.expectRefused(editor, range) {
            try Self.capture(&$0, [Fixture.mix], [Fixture.mix: Self.value(2, .normalized)])
        }
        Self.expectRefused(editor, .invalid(.invalidValue(Self.verse, Fixture.gain, .aboveCeiling(8, ceiling: 6)))) {
            try Self.capture(&$0, [Fixture.gain], [Fixture.gain: Self.value(8, .decibels)])
        }
        Self.expectRefused(editor, .invalid(.unknownVariation(Self.bridge))) {
            try Self.capture(&$0, [Fixture.mix], mix, into: Self.bridge)
        }
        let partial = try PatchBaseline([Fixture.gain: Self.value(0, .decibels)], table: Fixture.table())
        Self.expectRefused(editor, .invalid(.missingBaselineValue(Self.verse, Fixture.mix))) {
            try Self.capture(&$0, [Fixture.mix], mix, baseline: partial)
        }
        let otherTable = try PatchParameterTable(ParameterCatalog([
            Fixture.descriptor(Fixture.mix, unit: .normalized, 0...1),
            Fixture.descriptor(Fixture.gain, unit: .normalized, 0...1, controlClass: .structural)
        ]))
        Self.expectRefused(editor, .invalid(.nonLiveParameter(nil, Fixture.gain, .structural))) {
            try Self.capture(&$0, [Fixture.mix], mix, baseline: partial, table: otherTable)
        }
    }

    @Test
    func captureDeltaLimitPins() throws {
        let ids = try (0..<4096).map { try ParameterID("p.\($0)") }
        let table = try PatchParameterTable(ParameterCatalog(ids.map {
            try Fixture.descriptor($0, unit: .normalized, 0...1)
        }))
        let current = Dictionary(uniqueKeysWithValues: ids.map { ($0, Self.value(0.5, .normalized)) })
        var editor = try PatchVariationEditor.make(PatchVariationSet(variations: [
            PatchVariation(id: Self.verse, label: "Verse"),
            PatchVariation(id: Self.chorus, label: "Chorus", deltas: [Fixture.delta(Fixture.mix, 0.5, .normalized)])
        ]))
        try Self.capture(&editor, ids, current, table: table)
        #expect(editor.set[Self.verse]?.deltas.count == 4096)
        #expect(editor.set[Self.verse]?.deltas.last == Fixture.delta(ids[4095], 0.5, .normalized))
        Self.expectRefused(editor, .invalid(.tooManyDeltas(Self.chorus, count: 4097, maximum: 4096))) {
            try Self.capture(&$0, ids, current, into: Self.chorus, table: table)
        }
        try Self.capture(&editor, Array(ids.dropLast()), current, into: Self.chorus, table: table)
        #expect(editor.set[Self.chorus]?.deltas.count == 4096)
    }

    @Test
    func renameAndBadLabelsLeaveTheSetUnchanged() throws {
        var editor = try Self.editor()
        try editor.rename(Self.verse, to: "Verse 2 \u{2014} lead")
        #expect(editor.set[Self.verse]?.label == "Verse 2 \u{2014} lead")
        let bad = ["", " a", "a ", "a\nb", "a\u{200B}b", "a\u{2028}b", String(repeating: "a", count: 257)]
        for label in bad {
            Self.expectRefused(editor, .invalid(.invalidLabel(Self.verse))) { try $0.rename(Self.verse, to: label) }
            Self.expectRefused(editor, .invalid(.invalidLabel(Self.bridge))) {
                try $0.duplicate(Self.verse, as: Self.bridge, label: label)
            }
            Self.expectRefused(editor, .invalid(.invalidLabel(Self.bridge))) { try $0.add(Self.bridge, label: label) }
        }
        try editor.rename(Self.chorus, to: String(repeating: "a", count: 256))
        #expect(editor.set[Self.chorus]?.label.utf8.count == 256)
        // Labels are measured in UTF-8 bytes, not characters.
        let euros = String(repeating: "\u{20AC}", count: 86)
        #expect(euros.count == 86 && euros.utf8.count == 258)
        Self.expectRefused(editor, .invalid(.invalidLabel(Self.verse))) { try $0.rename(Self.verse, to: euros) }
        Self.expectRefused(editor, .invalid(.invalidLabel(Self.bridge))) { try $0.add(Self.bridge, label: euros) }
        let acutes = String(repeating: "\u{E9}", count: 128)
        #expect(acutes.utf8.count == 256)
        try editor.rename(Self.verse, to: acutes)
        #expect(editor.set[Self.verse]?.label == acutes)
        Self.expectRefused(editor, .invalid(.unknownVariation(Self.bridge))) { try $0.rename(Self.bridge, to: "B") }
    }

    @Test
    func duplicateCopiesAfterTheSourceUnderTheCallersID() throws {
        var editor = try Self.editor()
        var source = editor.set.variations[0]
        source.extensions = ["v": .bool(true)]
        source.unknownFields = ["stray": .int(1)]
        editor = try PatchVariationEditor.make(PatchVariationSet(variations: [source, editor.set.variations[1]]))
        try editor.duplicate(Self.verse, as: Self.bridge, label: "Bridge")
        #expect(editor.set.variations.map(\.id) == [Self.verse, Self.bridge, Self.chorus])
        var expected = source
        expected.id = Self.bridge
        expected.label = "Bridge"
        #expect(editor.set[Self.bridge] == expected)
        #expect(editor.set[Self.verse] == source)
        Self.expectRefused(editor, .invalid(.duplicateVariation(Self.chorus))) {
            try $0.duplicate(Self.verse, as: Self.chorus, label: "Again")
        }
        Self.expectRefused(editor, .invalid(.duplicateVariation(Self.verse))) {
            try $0.duplicate(Self.verse, as: Self.verse, label: "Same")
        }
        Self.expectRefused(editor, .invalid(.unknownVariation(PatchVariationID(validated: "none")))) {
            try $0.duplicate(PatchVariationID(validated: "none"), as: PatchVariationID(validated: "new"), label: "N")
        }
        try editor.duplicate(Self.chorus, as: PatchVariationID(validated: "tail"), label: "Tail")
        #expect(editor.set.variations.last?.id == PatchVariationID(validated: "tail"))
    }

    @Test
    func variationCountPinsForDuplicateAndAdd() throws {
        var editor = try PatchVariationEditor.make(PatchVariationSet(variations: Fixture.numbered(127)))
        try editor.duplicate(PatchVariationID("v.0"), as: Self.bridge, label: "Bridge")
        #expect(editor.set.variations.count == 128)
        #expect(editor.set.variations[1].id == Self.bridge)
        let full = editor
        let refusal = PatchVariationEditRefusal.invalid(.tooManyVariations(count: 129, maximum: 128))
        Self.expectRefused(full, refusal) { try $0.duplicate(Self.bridge, as: Self.chorus, label: "Chorus") }
        Self.expectRefused(full, refusal) { try $0.add(Self.chorus, label: "Chorus") }
        var almost = try PatchVariationEditor.make(PatchVariationSet(variations: Fixture.numbered(127)))
        try almost.add(Self.chorus, label: "Chorus")
        #expect(almost.set.variations.count == 128)
        #expect(almost.set.variations.last == PatchVariation(id: Self.chorus, label: "Chorus"))
        Self.expectRefused(try Self.editor(), .invalid(.duplicateVariation(Self.verse))) {
            try $0.add(Self.verse, label: "Again")
        }
    }

    @Test
    func reorderRequiresAnExactPermutation() throws {
        var editor = try Self.editor()
        try editor.add(Self.bridge, label: "Bridge")
        let none = PatchVariationID(validated: "none")
        let cases: [([PatchVariationID], PatchVariationEditRefusal)] = [
            ([Self.chorus, Self.verse], .reorderIncomplete(expected: 3, found: 2)),
            ([], .reorderIncomplete(expected: 3, found: 0)),
            ([Self.chorus, Self.verse, Self.chorus], .reorderRepeatedVariation(Self.chorus)),
            ([Self.chorus, Self.chorus, Self.verse, Self.bridge], .reorderRepeatedVariation(Self.chorus)),
            ([Self.chorus, Self.verse, Self.bridge, Self.chorus], .reorderRepeatedVariation(Self.chorus)),
            ([Self.chorus, Self.verse, none], .reorderUnknownVariation(none)),
            ([Self.chorus, Self.verse, Self.bridge, none], .reorderUnknownVariation(none))
        ]
        for (order, refusal) in cases {
            Self.expectRefused(editor, refusal) { try $0.reorder(order) }
        }
        let before = editor.set.variations
        try editor.reorder([Self.bridge, Self.verse, Self.chorus])
        #expect(editor.set.variations == [before[2], before[0], before[1]])
        try editor.reorder([Self.bridge, Self.verse, Self.chorus])
        #expect(editor.set.variations == [before[2], before[0], before[1]])
        var empty = try PatchVariationEditor.make(PatchVariationSet())
        try empty.reorder([])
        #expect(empty.set == PatchVariationSet())
    }

    @Test
    func deleteRemovesOnlyThatVariationAndDoesNotCascade() throws {
        let shows: JSONValue = .object(["cues": .array([.object(["variation": .string("verse")])])])
        let patch = try Self.editor().write(to: Fixture.patch(extensions: ["fluxklang.shows": shows]))
        var editor = try PatchVariationEditor.open(patch)
        try editor.delete(Self.verse)
        #expect(editor.set.variations.map(\.id) == [Self.chorus])
        Self.expectRefused(editor, .invalid(.unknownVariation(Self.verse))) { try $0.delete(Self.verse) }
        let written = try editor.write(to: patch)
        #expect(written.extensions?["fluxklang.shows"] == shows)
        #expect(try PatchVariationExtension.read(from: written) == editor.set)
        try editor.delete(Self.chorus)
        #expect(try editor.write(to: patch).extensions?.keys.sorted() == ["fluxklang.shows"])
    }

    @Test
    func factoriesValidateAndOpeningNeverRepairs() throws {
        let over = PatchVariationSet(variations: try Fixture.numbered(129))
        #expect(throws: PatchVariationEditRefusal.invalid(.tooManyVariations(count: 129, maximum: 128))) {
            try PatchVariationEditor.make(over)
        }
        let label = PatchVariationSet(variations: [PatchVariation(id: Self.verse, label: " x")])
        #expect(throws: PatchVariationEditRefusal.invalid(.invalidLabel(Self.verse))) {
            try PatchVariationEditor.make(label)
        }
        let stored = Fixture.patch(extensions: [Fixture.key: try Fixture.raw(over)])
        #expect(throws: PatchVariationEditRefusal.invalid(.tooManyVariations(count: 129, maximum: 128))) {
            try PatchVariationEditor.open(stored)
        }
        let future = Fixture.patch(extensions: [Fixture.key: .object(["version": .int(2)])])
        #expect(throws: PatchVariationEditRefusal.invalid(.futureVersionReadOnly(2))) {
            try PatchVariationEditor.open(future)
        }
        #expect(throws: PatchVariationEditRefusal.invalid(.futureVersionReadOnly(2))) {
            try Self.editor().write(to: future)
        }
        #expect(try PatchVariationEditor.open(Fixture.patch()).set == PatchVariationSet())
        let editor = try Self.editor()
        #expect(try PatchVariationEditor.open(editor.write(to: Fixture.patch())) == editor)
    }

    @Test
    func staleNonLiveDeltaSurvivesEditsAndRecallStillRefusesIt() throws {
        let stale = Fixture.delta(Fixture.routing, 1, .normalized)
        var editor = try PatchVariationEditor.make(PatchVariationSet(variations: [
            PatchVariation(id: Self.verse, label: "Verse", deltas: [stale])
        ]))
        try editor.rename(Self.verse, to: "Renamed")
        try editor.duplicate(Self.verse, as: Self.bridge, label: "Bridge")
        try Self.capture(&editor, [Fixture.mix], [Fixture.mix: Self.value(0.5, .normalized)])
        #expect(editor.set[Self.verse]?.deltas == [stale, Fixture.delta(Fixture.mix, 0.5, .normalized)])
        #expect(editor.set[Self.bridge]?.deltas == [stale])
        let table = try Fixture.table()
        let patch = try editor.write(to: Fixture.patch())
        for id in [Self.verse, Self.bridge] {
            #expect(throws: PatchVariationError.nonLiveParameter(id, Fixture.routing, .structural)) {
                try PatchRecallPlanner.plan(for: patch, table: table, baseline: .defaults(table), from: nil, to: id)
            }
        }
    }
}
