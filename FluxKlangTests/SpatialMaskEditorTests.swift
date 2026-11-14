import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

// swiftlint:disable identifier_name
/// Fixtures of the spatial mask editor tests (#116 SMK1). Self-contained: no other test file is used.
enum SpatialMaskEditorFixture {
    static let fl = SpeakerID(validated: "spk.fl")
    static let fr = SpeakerID(validated: "spk.fr")
    static let rl = SpeakerID(validated: "spk.rl")
    static let rr = SpeakerID(validated: "spk.rr")
    static let ghost = SpeakerID(validated: "spk.ghost")

    static func speaker(_ id: StaticString, x: Double, y: Double) throws -> SpatialSpeaker {
        try SpatialSpeaker(id: SpeakerID(validated: id), name: nil, position: NeutralPoint(x: x, y: y), route: nil)
    }

    private static func speaker(_ id: SpeakerID, x: Double, y: Double) throws -> SpatialSpeaker {
        try SpatialSpeaker(id: id, name: nil, position: NeutralPoint(x: x, y: y), route: nil)
    }

    /// `spk.fl`, `spk.fr`, `spk.rl`, `spk.rr` in that order.
    static func quad() throws -> SpatialLayout {
        try SpatialLayout(speakers: [
            speaker("spk.fl", x: -1, y: 1), speaker("spk.fr", x: 1, y: 1),
            speaker("spk.rl", x: -1, y: -1), speaker("spk.rr", x: 1, y: -1)
        ])
    }

    /// The same four speakers declared as `spk.rr`, `spk.fl`, `spk.rl`, `spk.fr`.
    static func shuffled() throws -> SpatialLayout {
        try SpatialLayout(speakers: [
            speaker("spk.rr", x: 1, y: -1), speaker("spk.fl", x: -1, y: 1),
            speaker("spk.rl", x: -1, y: -1), speaker("spk.fr", x: 1, y: 1)
        ])
    }

    static func trio() throws -> SpatialLayout {
        try SpatialLayout(speakers: [
            speaker("spk.a", x: -1, y: 0), speaker("spk.b", x: 0, y: 0), speaker("spk.c", x: 1, y: 0)
        ])
    }

    /// `spk.0` to `spk.63`.
    static func wide() throws -> SpatialLayout {
        try SpatialLayout(speakers: (0..<64).map { index in
            try speaker(SpeakerID("spk.\(index)"), x: 0, y: 0)
        })
    }

    static func mask(_ speaker: SpeakerID, _ state: SpeakerMaskState) -> SpatialOutputMask {
        SpatialOutputMask(speaker: speaker, state: state)
    }

    static func set(_ masks: [SpatialOutputMask], renormalize: Bool = false) throws -> SpatialMaskSet {
        try SpatialMaskSet(masks: masks, renormalizeSurvivors: renormalize)
    }

    static func editor(
        _ masks: [SpatialOutputMask] = [], renormalize: Bool = false, layout: SpatialLayout? = nil
    ) throws -> SpatialMaskEditor {
        try SpatialMaskEditor(masks: set(masks, renormalize: renormalize), layout: layout ?? quad())
    }

    /// An independent model of three speakers: per speaker a (muted, soloed) pair, and the flag.
    struct Model {
        var muted = [false, false, false]
        var soloed = [false, false, false]
        var flag = false

        func masks(_ ids: [SpeakerID]) -> [SpatialOutputMask] {
            var list: [SpatialOutputMask] = []
            for index in 0..<3 {
                if muted[index] { list.append(SpatialOutputMask(speaker: ids[index], state: .muted)) }
                if soloed[index] { list.append(SpatialOutputMask(speaker: ids[index], state: .soloed)) }
            }
            return list
        }
    }
}
// swiftlint:enable identifier_name

@Suite("Spatial mask editor", .productionAccessAudit)
struct SpatialMaskEditorTests {
    typealias Fixture = SpatialMaskEditorFixture

    private func masks(_ editor: SpatialMaskEditor) -> [SpatialOutputMask] { editor.masks.masks }

    @Test func everyEditFromEveryStartOnThreeSpeakersMatchesTheModel() throws {
        let ids = [SpeakerID(validated: "spk.a"), SpeakerID(validated: "spk.b"), SpeakerID(validated: "spk.c")]
        let layout = try Fixture.trio()
        try #require(ids.count == 3)
        // Fourteen edits, each with the model's effect, written out by hand.
        let steps: [(SpatialMaskEdit, (inout Fixture.Model) -> Void)] = [
            (.setMuted(ids[0], true), { $0.muted[0] = true }), (.setMuted(ids[0], false), { $0.muted[0] = false }),
            (.setMuted(ids[1], true), { $0.muted[1] = true }), (.setMuted(ids[1], false), { $0.muted[1] = false }),
            (.setMuted(ids[2], true), { $0.muted[2] = true }), (.setMuted(ids[2], false), { $0.muted[2] = false }),
            (.setSoloed(ids[0], true), { $0.soloed[0] = true }), (.setSoloed(ids[0], false), { $0.soloed[0] = false }),
            (.setSoloed(ids[1], true), { $0.soloed[1] = true }), (.setSoloed(ids[1], false), { $0.soloed[1] = false }),
            (.setSoloed(ids[2], true), { $0.soloed[2] = true }), (.setSoloed(ids[2], false), { $0.soloed[2] = false }),
            (.setRenormalizeSurvivors(true), { $0.flag = true }), (.setRenormalizeSurvivors(false), { $0.flag = false })
        ]
        var cases = 0
        for code in 0..<64 {
            for flag in [false, true] {
                var before = Fixture.Model()
                try #require(before.muted.count == 3 && before.soloed.count == 3)
                for index in 0..<3 {
                    before.muted[index] = (code >> (2 * index)) & 1 == 1
                    before.soloed[index] = (code >> (2 * index + 1)) & 1 == 1
                }
                before.flag = flag
                for (edit, effect) in steps {
                    var after = before
                    effect(&after)
                    var editor = try Fixture.editor(
                        before.masks(ids), renormalize: flag, layout: layout
                    )
                    let previewed = try editor.preview(edit)
                    let applied = try editor.apply(edit)
                    let note = "start \(code) flag \(flag) edit \(edit)"
                    #expect(applied.masks.masks == after.masks(ids), "\(note) masks")
                    #expect(applied.masks.renormalizeSurvivors == after.flag, "\(note) flag")
                    let differs = after.masks(ids) != before.masks(ids) || after.flag != before.flag
                    #expect(applied.changed == differs, "\(note) changed")
                    try #require(after.muted.count == 3 && after.soloed.count == 3)
                    for index in 0..<3 {
                        #expect(editor.isMuted(ids[index]) == after.muted[index], "\(note) muted \(index)")
                        #expect(editor.isSoloed(ids[index]) == after.soloed[index], "\(note) soloed \(index)")
                    }
                    #expect(previewed == applied, "\(note) preview")
                    #expect(editor.masks == applied.masks, "\(note) stored")
                    cases += 1
                }
            }
        }
        #expect(cases == 1_792)
    }

    @Test func muteAndUnmuteReportChanges() throws {
        var editor = try Fixture.editor()
        let first = try editor.apply(.setMuted(Fixture.fl, true))
        #expect(first.masks.masks == [Fixture.mask(Fixture.fl, .muted)])
        #expect(first.changed)
        #expect(editor.isMuted(Fixture.fl))
        #expect(!editor.isSoloed(Fixture.fl))
        let again = try editor.apply(.setMuted(Fixture.fl, true))
        #expect(!again.changed)
        #expect(again.masks == first.masks)
        let off = try editor.apply(.setMuted(Fixture.fl, false))
        #expect(off.changed)
        #expect(!editor.isMuted(Fixture.fl))
        #expect(!editor.isSoloed(Fixture.fl))
        #expect(off.masks == SpatialMaskSet.none)
        let offAgain = try editor.apply(.setMuted(Fixture.fl, false))
        #expect(!offAgain.changed)
        #expect(offAgain.masks == SpatialMaskSet.none)
    }

    @Test func soloAndUnsoloReportChanges() throws {
        var editor = try Fixture.editor()
        let first = try editor.apply(.setSoloed(Fixture.fl, true))
        #expect(first.masks.masks == [Fixture.mask(Fixture.fl, .soloed)])
        #expect(first.changed)
        #expect(editor.isSoloed(Fixture.fl))
        #expect(!editor.isMuted(Fixture.fl))
        let again = try editor.apply(.setSoloed(Fixture.fl, true))
        #expect(!again.changed)
        #expect(again.masks == first.masks)
        let off = try editor.apply(.setSoloed(Fixture.fl, false))
        #expect(off.changed)
        #expect(!editor.isSoloed(Fixture.fl))
        #expect(!editor.isMuted(Fixture.fl))
        #expect(off.masks == SpatialMaskSet.none)
        let offAgain = try editor.apply(.setSoloed(Fixture.fl, false))
        #expect(!offAgain.changed)
        #expect(offAgain.masks == SpatialMaskSet.none)
    }

    @Test func muteAndSoloAreIndependentAndTheRendererAgrees() throws {
        let layout = try Fixture.quad()
        var editor = try Fixture.editor()
        try editor.apply(.setMuted(Fixture.fl, true))
        try editor.apply(.setSoloed(Fixture.fl, true))
        #expect(masks(editor) == [Fixture.mask(Fixture.fl, .muted), Fixture.mask(Fixture.fl, .soloed)])
        #expect(editor.masks.passes(layout: layout, availableRoutes: nil) == [.masked, .masked, .masked, .masked])
        try editor.apply(.setMuted(Fixture.fl, false))
        #expect(masks(editor) == [Fixture.mask(Fixture.fl, .soloed)])
        #expect(editor.masks.passes(layout: layout, availableRoutes: nil) == [.pass, .masked, .masked, .masked])
        try editor.apply(.setSoloed(Fixture.fl, false))
        #expect(editor.masks == SpatialMaskSet.none)
        #expect(editor.masks.passes(layout: layout, availableRoutes: nil) == [.pass, .pass, .pass, .pass])
        try editor.apply(.setMuted(Fixture.rr, true))
        try editor.apply(.setSoloed(Fixture.fr, true))
        #expect(editor.masks.passes(layout: layout, availableRoutes: nil) == [.masked, .pass, .masked, .masked])
    }

    @Test func theSetIsOrderedByIDWhateverTheLayoutAndEditOrder() throws {
        var first = try Fixture.editor(layout: Fixture.shuffled())
        try first.apply(.setMuted(Fixture.rr, true))
        try first.apply(.setMuted(Fixture.fl, true))
        try first.apply(.setMuted(Fixture.rl, true))
        var second = try Fixture.editor(layout: Fixture.shuffled())
        try second.apply(.setMuted(Fixture.fl, true))
        try second.apply(.setMuted(Fixture.rl, true))
        try second.apply(.setMuted(Fixture.rr, true))
        let expected = [
            Fixture.mask(Fixture.fl, .muted), Fixture.mask(Fixture.rl, .muted), Fixture.mask(Fixture.rr, .muted)
        ]
        #expect(masks(first) == expected)
        #expect(masks(second) == expected)
        #expect(first.masks == second.masks)
    }

    @Test func unknownSpeakersAreRefusedAndNothingChanges() throws {
        let ghost = Fixture.ghost
        let edits: [SpatialMaskEdit] = [
            .setMuted(ghost, true), .setMuted(ghost, false), .setSoloed(ghost, true), .setSoloed(ghost, false)
        ]
        for edit in edits {
            var editor = try Fixture.editor([Fixture.mask(Fixture.fl, .muted)], renormalize: true)
            let before = editor
            #expect(throws: SpatialRenderError.unknownMaskSpeaker(ghost)) { try editor.preview(edit) }
            #expect(throws: SpatialRenderError.unknownMaskSpeaker(ghost)) { try editor.apply(edit) }
            #expect(editor == before)
        }
    }

    @Test func theStartingSetMustFitTheLayout() throws {
        let first = SpeakerID(validated: "spk.x1")
        let second = SpeakerID(validated: "spk.x2")
        let strange = try Fixture.set([Fixture.mask(second, .muted), Fixture.mask(first, .soloed)])
        #expect(throws: SpatialRenderError.unknownMaskSpeaker(first)) {
            try SpatialMaskEditor(masks: strange, layout: Fixture.quad())
        }
        let known = try Fixture.set(
            [Fixture.mask(Fixture.rr, .soloed), Fixture.mask(Fixture.fl, .muted)], renormalize: true
        )
        let accepted = try SpatialMaskEditor(masks: known, layout: Fixture.quad())
        #expect(accepted.masks == known)
        #expect(masks(accepted) == [Fixture.mask(Fixture.fl, .muted), Fixture.mask(Fixture.rr, .soloed)])
        let fresh = try SpatialMaskEditor(layout: Fixture.quad())
        #expect(fresh.masks == SpatialMaskSet.none)
    }

    @Test func theFlagEditsKeepTheMasks() throws {
        let start = [Fixture.mask(Fixture.fl, .muted), Fixture.mask(Fixture.rr, .soloed)]
        var editor = try Fixture.editor(start)
        let enabled = try editor.apply(.setRenormalizeSurvivors(true))
        #expect(enabled.changed)
        #expect(enabled.masks.masks == start)
        #expect(enabled.masks.renormalizeSurvivors)
        let again = try editor.apply(.setRenormalizeSurvivors(true))
        #expect(!again.changed)
        let off = try editor.apply(.setRenormalizeSurvivors(false))
        #expect(off.changed)
        #expect(off.masks.masks == start)
        #expect(!off.masks.renormalizeSurvivors)
        try editor.apply(.setRenormalizeSurvivors(true))
        let added = try editor.apply(.setMuted(Fixture.fr, true))
        #expect(added.masks.renormalizeSurvivors)
        #expect(added.masks.masks.count == 3)
        let removed = try editor.apply(.setMuted(Fixture.fr, false))
        #expect(removed.masks.renormalizeSurvivors)
        #expect(removed.masks.masks == start)
    }

    @Test func anEmptyLayoutRefusesMaskEditsButTakesTheFlag() throws {
        var editor = try SpatialMaskEditor(layout: SpatialLayout(speakers: []))
        let edits: [SpatialMaskEdit] = [
            .setMuted(Fixture.fl, true), .setMuted(Fixture.fl, false),
            .setSoloed(Fixture.fl, true), .setSoloed(Fixture.fl, false)
        ]
        for edit in edits {
            #expect(throws: SpatialRenderError.unknownMaskSpeaker(Fixture.fl)) { try editor.apply(edit) }
        }
        #expect(masks(editor).isEmpty)
        let flag = try editor.apply(.setRenormalizeSurvivors(true))
        #expect(flag.changed)
        #expect(flag.masks.masks.isEmpty)
        #expect(editor.masks.renormalizeSurvivors)
    }

    @Test func aFullLayoutHoldsAllOneHundredTwentyEightMasks() throws {
        let layout = try Fixture.wide()
        var editor = try SpatialMaskEditor(layout: layout)
        let ids = try (0..<64).map { try SpeakerID("spk.\($0)") }
        for id in ids {
            let muted = try editor.apply(.setMuted(id, true))
            let soloed = try editor.apply(.setSoloed(id, true))
            #expect(muted.changed)
            #expect(soloed.changed)
        }
        #expect(masks(editor).count == 128)
        #expect(masks(editor).count == SpatialMaskSet.maximumMasks)
        let sortedNames = (0..<64).map { "spk.\($0)" }.sorted()
        #expect(masks(editor).map(\.speaker.rawValue) == sortedNames.flatMap { [$0, $0] })
        #expect(masks(editor).map(\.state) == sortedNames.flatMap { _ in [SpeakerMaskState.muted, .soloed] })
        let passes = editor.masks.passes(layout: layout, availableRoutes: nil)
        #expect(passes.count == 64)
        #expect(passes.allSatisfy { $0 == .masked })
        let data = try JSONEncoder().encode(editor.masks)
        #expect(try JSONDecoder().decode(SpatialMaskSet.self, from: data) == editor.masks)
        for id in ids { try editor.apply(.setMuted(id, false)) }
        #expect(masks(editor).count == 64)
        #expect(masks(editor).allSatisfy { $0.state == .soloed })
    }

    @Test func editorsAreValues() throws {
        let editor = try Fixture.editor([Fixture.mask(Fixture.fl, .muted)])
        let before = editor
        _ = try editor.preview(.setSoloed(Fixture.fr, true))
        #expect(editor == before)
        var copy = editor
        try copy.apply(.setMuted(Fixture.rl, true))
        #expect(editor == before)
        #expect(copy != editor)
        var left = try Fixture.editor(layout: Fixture.quad())
        var right = try Fixture.editor(layout: Fixture.quad())
        for edit in [SpatialMaskEdit.setMuted(Fixture.rr, true), .setSoloed(Fixture.fl, true)] {
            try left.apply(edit)
            try right.apply(edit)
        }
        #expect(left == right)
        #expect(left.hashValue == right.hashValue)
    }
}
