import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

// swiftlint:disable identifier_name
/// Fixtures of the spatial source panel tests (#116 SSP1). Self-contained: no other test file is used.
enum SpatialSourcePanelFixture {
    static let synth = SpatialSourceID(validated: "src.synth")

    static func speaker(_ id: StaticString, _ name: String?, x: Double, y: Double) throws -> SpatialSpeaker {
        try SpatialSpeaker(id: SpeakerID(validated: id), name: name, position: NeutralPoint(x: x, y: y), route: nil)
    }

    /// Front Left, Front Right, Rear Left and Rear Right at the corners, plus the unnamed `spk.c` at the centre.
    static func quad(withCentre: Bool = false) throws -> SpatialLayout {
        var speakers = [
            try speaker("spk.fl", "Front Left", x: -1, y: 1),
            try speaker("spk.fr", "Front Right", x: 1, y: 1),
            try speaker("spk.rl", "Rear Left", x: -1, y: -1),
            try speaker("spk.rr", "Rear Right", x: 1, y: -1)
        ]
        if withCentre { speakers.append(try speaker("spk.c", nil, x: 0, y: 0)) }
        return try SpatialLayout(speakers: speakers)
    }

    /// `src.synth`, named `Soft Synth` unless `name` says otherwise, at x 0.10, y 0.60 and width 0.50, stereo.
    static func placement(
        name: String? = "Soft Synth", x: Double = 0.10, y: Double = 0.60, width: Double = 0.50, channels: Int = 2
    ) throws -> SpatialSourcePlacement {
        try SpatialSourcePlacement(
            sourceID: synth, name: name, position: NeutralPoint(x: x, y: y), width: width, channelCount: channels
        )
    }

    static func editor(
        name: String? = "Soft Synth", x: Double = 0.10, y: Double = 0.60, width: Double = 0.50, channels: Int = 2,
        layout: SpatialLayout? = nil
    ) throws -> SpatialPlacementEditor {
        SpatialPlacementEditor(
            placement: try placement(name: name, x: x, y: y, width: width, channels: channels),
            layout: try layout ?? quad()
        )
    }

    static func panel(
        name: String? = "Soft Synth", x: Double = 0.10, y: Double = 0.60, width: Double = 0.50, channels: Int = 2,
        layout: SpatialLayout? = nil
    ) throws -> SpatialSourcePanelPresentation {
        .make(try editor(name: name, x: x, y: y, width: width, channels: channels, layout: layout))
    }
}
// swiftlint:enable identifier_name

#if os(macOS)
@Suite("Spatial source panel", .productionAccessAudit)
#else
@Suite("Spatial source panel")
#endif
struct SpatialSourcePanelPresentationTests {
    typealias Fixture = SpatialSourcePanelFixture

    @Test func titleNamesTheSourceAndItsID() throws {
        let named = try Fixture.panel()
        #expect(named.title == "Selected: Soft Synth (src.synth)")
        #expect(named.source == SpatialSourceID(validated: "src.synth"))
        let unnamed = try Fixture.panel(name: nil)
        #expect(unnamed.title == "Selected: src.synth")
        #expect(unnamed.source == SpatialSourceID(validated: "src.synth"))
    }

    @Test func rowsFollowTheSourceChannels() throws {
        let mono = try Fixture.panel(channels: 1)
        try #require(mono.rows.count == 2)
        #expect(mono.rows.map(\.axis) == [.x, .y])
        #expect(mono.rows.map(\.label) == ["X", "Y"])
        let stereo = try Fixture.panel()
        try #require(stereo.rows.count == 3)
        #expect(stereo.rows.map(\.axis) == [.x, .y, .width])
        #expect(stereo.rows.map(\.label) == ["X", "Y", "Width"])
        #expect(stereo.rows.map(\.id) == [.x, .y, .width])
    }

    @Test func docExampleRowsFollowTheDocument() throws {
        let panel = try Fixture.panel(x: 0.20, y: 0.40, width: 0.50)
        try #require(panel.rows.count == 3)
        let rows = panel.rows
        #expect(rows[0].numberText == "0.20")
        #expect(rows[0].wordsText == "slightly right of centre")
        #expect(rows[0].value == 0.20)
        #expect(rows[0].range == -1...1)
        #expect(rows[1].numberText == "0.40")
        #expect(rows[1].wordsText == "in front")
        #expect(rows[1].value == 0.40)
        #expect(rows[1].range == -1...1)
        #expect(rows[2].numberText == "0.50")
        #expect(rows[2].wordsText == nil)
        #expect(rows[2].value == 0.50)
        #expect(rows[2].range == 0...1)
    }

    @Test func voiceOverValues() throws {
        let panel = try Fixture.panel(x: 0.20, y: 0.40, width: 0.50)
        try #require(panel.rows.count == 3)
        #expect(panel.rows.map(\.accessibilityValue) == ["slightly right of centre, 0.20", "in front, 0.40", "0.50"])
    }

    @Test func sectionLabelIsTheSpokenDescription() throws {
        #expect(try Fixture.panel().accessibilityLabel
            == "Soft Synth, slightly right of centre, in front; x 0.10, y 0.60, width 0.50")
        #expect(try Fixture.panel(channels: 1).accessibilityLabel
            == "Soft Synth, slightly right of centre, in front; x 0.10, y 0.60")
        #expect(try Fixture.panel(name: nil).accessibilityLabel
            == "src.synth, slightly right of centre, in front; x 0.10, y 0.60, width 0.50")
    }

    @Test func printedValuesAndTheirWords() throws {
        let zero = try #require(try Fixture.panel(x: -0.0).rows.first)
        #expect(zero.numberText == "0.00")
        #expect(zero.wordsText == "centre")
        let edge = try #require(try Fixture.panel(x: 0.0499).rows.first)
        #expect(edge.numberText == "0.05")
        #expect(edge.wordsText == "slightly right of centre")
        let left = try #require(try Fixture.panel(x: -0.35).rows.first)
        #expect(left.numberText == "-0.35")
        #expect(left.wordsText == "left of centre")
        let panel = try Fixture.panel(y: -0.80)
        try #require(panel.rows.count == 3)
        #expect(panel.rows[1].numberText == "-0.80")
        #expect(panel.rows[1].wordsText == "far behind")
    }

    @Test func editsAreTheEditorsAccessibilityEdits() throws {
        let panel = try Fixture.panel()
        try #require(panel.rows.count == 3)
        for row in panel.rows {
            #expect(row.incrementEdit == SpatialPlacementEdit.accessibilityIncrement(row.axis))
            #expect(row.decrementEdit == SpatialPlacementEdit.accessibilityDecrement(row.axis))
        }
        #expect(panel.rows[0].incrementEdit == .nudge(.x, .increase, .coarse))
        #expect(panel.rows[1].decrementEdit == .nudge(.y, .decrease, .coarse))
    }

    @Test func applyingTheEditsChangesOnlyTheirAxis() throws {
        let editor = try Fixture.editor(x: 0.30, y: 0.30, width: 0.30)
        let panel = SpatialSourcePanelPresentation.make(editor)
        try #require(panel.rows.count == 3)

        var raised = editor
        try raised.apply(panel.rows[0].incrementEdit)
        #expect(raised.placement.position.x == 0.35)
        #expect(raised.placement.position.y == 0.30)
        #expect(raised.placement.width == 0.30)
        let raisedRow = try #require(SpatialSourcePanelPresentation.make(raised).rows.first)
        #expect(raisedRow.numberText == "0.35")
        #expect(raisedRow.wordsText == "right of centre")

        var down = editor
        try down.apply(panel.rows[0].decrementEdit)
        #expect(down.placement.position.x == 0.25)

        var yEdit = editor
        try yEdit.apply(panel.rows[1].incrementEdit)
        #expect(yEdit.placement.position.x == 0.30)
        #expect(yEdit.placement.position.y == 0.35)
        #expect(yEdit.placement.width == 0.30)

        var widthEdit = editor
        try widthEdit.apply(panel.rows[2].decrementEdit)
        #expect(widthEdit.placement.position.x == 0.30)
        #expect(widthEdit.placement.position.y == 0.30)
        #expect(widthEdit.placement.width == 0.25)
    }

    @Test func speakerActionsListTheSpeakersInLayoutOrder() throws {
        let panel = try Fixture.panel()
        try #require(panel.speakerActions.count == 4)
        #expect(panel.speakerActions.map(\.label)
            == ["Move to Front Left", "Move to Front Right", "Move to Rear Left", "Move to Rear Right"])
        #expect(panel.speakerActions.map(\.edit) == [
            .snap(.speaker(SpeakerID(validated: "spk.fl"))), .snap(.speaker(SpeakerID(validated: "spk.fr"))),
            .snap(.speaker(SpeakerID(validated: "spk.rl"))), .snap(.speaker(SpeakerID(validated: "spk.rr")))
        ])

        let withCentre = try Fixture.panel(layout: Fixture.quad(withCentre: true))
        try #require(withCentre.speakerActions.count == 5)
        let last = try #require(withCentre.speakerActions.last)
        #expect(last.label == "Move to spk.c")
        #expect(last.edit == .snap(.speaker(SpeakerID(validated: "spk.c"))))
        #expect(!withCentre.speakerActions.contains { $0.edit == .snap(.centre) })
    }

    @Test func aSpeakerNamedCentreStaysAmongTheSpeakerActions() throws {
        let layout = try SpatialLayout(speakers: [
            Fixture.speaker("spk.fl", "Front Left", x: -1, y: 1),
            Fixture.speaker("spk.cc", "centre", x: 0, y: 0)
        ])
        let panel = try Fixture.panel(layout: layout)
        try #require(panel.speakerActions.count == 2)
        let named = try #require(panel.speakerActions.last)
        #expect(named.label == "Move to centre")
        #expect(named.edit == .snap(.speaker(SpeakerID(validated: "spk.cc"))))
        #expect(!panel.speakerActions.contains { $0.edit == .snap(.centre) })
        try #require(panel.moveActions.count == 3)
        let last = try #require(panel.moveActions.last)
        #expect(last.label == "Move to centre")
        #expect(last.edit == .snap(.centre))
        #expect(panel.centreEdit == .snap(.centre))
    }

    @Test func moveActionsAndTheCentreControl() throws {
        let editor = try Fixture.editor(width: 0.40)
        let panel = SpatialSourcePanelPresentation.make(editor)
        #expect(panel.moveActions == editor.moveActions)
        try #require(panel.moveActions.count == 5)
        let last = try #require(panel.moveActions.last)
        #expect(last.label == "Move to centre")
        #expect(last.edit == .snap(.centre))
        #expect(panel.centreEdit == .snap(.centre))
        #expect(panel.centreTitle == "Centre")
        #expect(panel.moveToSpeakerTitle == "Move to speaker...")

        var moved = editor
        try moved.apply(panel.centreEdit)
        #expect(moved.placement.position.x == 0)
        #expect(moved.placement.position.y == 0)
        #expect(moved.placement.width == 0.40)
    }

    @Test func aLayoutWithoutSpeakers() throws {
        let empty = try SpatialLayout(speakers: [])
        let panel = try Fixture.panel(layout: empty)
        #expect(panel.speakerActions.isEmpty)
        #expect(panel.moveActions == [SpatialPlacementAction(label: "Move to centre", edit: .snap(.centre))])
        #expect(panel.centreEdit == .snap(.centre))
        #expect(panel.title == "Selected: Soft Synth (src.synth)")
        #expect(panel.rows.count == 3)
    }

    @Test func theValueReflectsTheEditorsCurrentPlacement() throws {
        var editor = try Fixture.editor(x: 0.30)
        let before = SpatialSourcePanelPresentation.make(editor)
        try editor.apply(.nudge(.x, .increase, .coarse))
        let after = SpatialSourcePanelPresentation.make(editor)
        let row = try #require(after.rows.first)
        #expect(row.numberText == "0.35")
        #expect(row.wordsText == "right of centre")
        #expect(after != before)
        #expect(try #require(before.rows.first).numberText == "0.30")
    }

    @Test func equalEditorsGiveEqualPresentations() throws {
        let base = try Fixture.panel()
        let same = try Fixture.panel()
        #expect(base == same)
        #expect(base.hashValue == same.hashValue)
        #expect(base != (try Fixture.panel(x: 0.15)))
        #expect(base != (try Fixture.panel(name: "Other")))
        #expect(base != (try Fixture.panel(width: 0.60)))
        #expect(base != (try Fixture.panel(channels: 1)))
        #expect(base != (try Fixture.panel(layout: Fixture.quad(withCentre: true))))
    }
}
