import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// Shared #116 PL1 fixtures: a named, routed quad plus one unnamed, unrouted
/// speaker (`spk.c`), and sources built from plain doubles.
enum SpatialEditingFixture {
    struct Seat {
        let raw: String
        let name: String?
        let horizontal: Double
        let vertical: Double
        let routed: Bool
    }

    static let quad = [
        Seat(raw: "spk.fl", name: "Front Left", horizontal: -1, vertical: 1, routed: true),
        Seat(raw: "spk.fr", name: "Front Right", horizontal: 1, vertical: 1, routed: true),
        Seat(raw: "spk.rl", name: "Rear Left", horizontal: -1, vertical: -1, routed: true),
        Seat(raw: "spk.rr", name: "Rear Right", horizontal: 1, vertical: -1, routed: true),
        Seat(raw: "spk.c", name: nil, horizontal: 0, vertical: 0.8, routed: false)
    ]

    static func speaker(_ raw: String) throws -> SpeakerID { try SpeakerID(raw) }

    static func point(_ horizontal: Double, _ vertical: Double) throws -> NeutralPoint {
        try NeutralPoint(validatingX: horizontal, y: vertical)
    }

    /// The quad layout; `reroutes` maps a speaker to a different route.
    static func layout(reroutes: [String: String] = [:]) throws -> SpatialLayout {
        try SpatialLayout(speakers: quad.map { item in
            let route = reroutes[item.raw] ?? (item.routed ? "rte." + item.raw.dropFirst(4) : nil)
            return try SpatialSpeaker(id: SpeakerID(item.raw), name: item.name,
                                      position: point(item.horizontal, item.vertical),
                                      route: route.map(RouteID.init))
        })
    }

    static func routes() throws -> Set<RouteID> {
        Set(try ["rte.fl", "rte.fr", "rte.rl", "rte.rr"].map { try RouteID($0) })
    }

    static func source(_ horizontal: Double, _ vertical: Double, channels: Int = 2, width: Double = 0.5,
                       name: String? = "Soft Synth") throws -> SpatialSourcePlacement {
        try SpatialSourcePlacement(sourceID: SpatialSourceID("src.synth"), name: name,
                                   position: point(horizontal, vertical), width: width, channelCount: channels)
    }
}

@Suite("Spatial placement editing and spoken positions", .productionAccessAudit)
struct SpatialEditingTests {
    private typealias Fixture = SpatialEditingFixture
    private typealias Words = SpatialPositionDescription

    private struct AgreementCase {
        let start: (Double, Double)
        let key: SpatialArrowKey
        let drag: (Double, Double)
        let end: (Double, Double)
    }

    private struct BandEdge {
        let value: Double
        let band: SpatialPositionDescription.Band
        let right: String
        let front: String
    }

    private static func editor(_ horizontal: Double, _ vertical: Double, channels: Int = 2,
                               width: Double = 0.5) throws -> SpatialPlacementEditor {
        SpatialPlacementEditor(placement: try Fixture.source(horizontal, vertical, channels: channels, width: width),
                               layout: try Fixture.layout())
    }

    private static func expectPosition(_ editor: SpatialPlacementEditor, _ horizontal: Double, _ vertical: Double,
                                       width: Double? = nil, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(editor.placement.position.x == horizontal, sourceLocation: sourceLocation)
        #expect(editor.placement.position.y == vertical, sourceLocation: sourceLocation)
        if let width { #expect(editor.placement.width == width, sourceLocation: sourceLocation) }
    }

    /// Applies `edit`, requires the typed refusal and that nothing changed (preview agrees).
    private static func expectRefusal(_ editor: inout SpatialPlacementEditor, _ edit: SpatialPlacementEdit,
                                      _ expected: SpatialEditingRefusal,
                                      sourceLocation: SourceLocation = #_sourceLocation) {
        let before = editor
        #expect(throws: expected, sourceLocation: sourceLocation) { try before.preview(edit) }
        do {
            try editor.apply(edit)
            Issue.record("\(edit) was not refused", sourceLocation: sourceLocation)
        } catch {
            #expect(error == expected, sourceLocation: sourceLocation)
        }
        #expect(editor == before, sourceLocation: sourceLocation)
    }

    @Test func nudgesMoveOneAxisByCoarseOrFineSteps() throws {
        var editor = try Self.editor(0.1, 0.6)
        try editor.apply(.nudge(.x, .increase, .coarse))
        Self.expectPosition(editor, 0.15, 0.6, width: 0.5)
        try editor.apply(.nudge(.x, .increase, .fine))
        Self.expectPosition(editor, 0.16, 0.6, width: 0.5)
        try editor.apply(.nudge(.y, .decrease, .coarse))
        Self.expectPosition(editor, 0.16, 0.55, width: 0.5)
        try editor.apply(.nudge(.y, .increase, .fine))
        Self.expectPosition(editor, 0.16, 0.56, width: 0.5)
        try editor.apply(.nudge(.x, .decrease, .fine))
        Self.expectPosition(editor, 0.15, 0.56, width: 0.5)
        try editor.apply(.nudge(.width, .decrease, .coarse))
        Self.expectPosition(editor, 0.15, 0.56, width: 0.45)
        let outcome = try editor.apply(.nudge(.width, .increase, .fine))
        Self.expectPosition(editor, 0.15, 0.56, width: 0.46)
        #expect(!outcome.clamped)
        #expect(outcome.placement == editor.placement)
        #expect(editor.placement.sourceID.rawValue == "src.synth" && editor.placement.name == "Soft Synth")
    }

    @Test func nudgesStayOnTheHundredthsGrid() throws {
        var editor = try Self.editor(-1, 1)
        var vertical = 100
        for step in 1...40 {
            let fine = !step.isMultiple(of: 2)
            try editor.apply(.nudge(.x, .increase, .coarse))
            try editor.apply(.nudge(.y, .decrease, fine ? .fine : .coarse))
            vertical -= fine ? 1 : 5
            #expect(editor.placement.position.x == Double(-100 + 5 * step) / 100)
            #expect(editor.placement.position.y == Double(vertical) / 100)
        }
        var fromCentre = try Self.editor(0, 1)
        for _ in 0..<7 { try fromCentre.apply(.nudge(.x, .increase, .coarse)) }
        for _ in 0..<5 { try fromCentre.apply(.nudge(.y, .decrease, .coarse)) }
        #expect(fromCentre.placement.position.x == 0.35 && fromCentre.placement.position.y == 0.75)
        #expect(Words.words(fromCentre.placement.position) == "right of centre, far in front")
        var offGrid = try Self.editor(0.123, -0.456)
        try offGrid.apply(.nudge(.x, .increase, .coarse))
        try offGrid.apply(.nudge(.y, .decrease, .fine))
        Self.expectPosition(offGrid, 0.123 + 0.05, -0.456 - 0.01)
        #expect(SpatialPlacementEditor.stepped(-0.0, .increase, .coarse) == 0.05)
    }

    @Test func nudgesClampAtTheBounds() throws {
        var editor = try Self.editor(0.98, -0.98, width: 0.97)
        var clamps = [try editor.apply(.nudge(.x, .increase, .coarse)).clamped]
        Self.expectPosition(editor, 1, -0.98)
        clamps.append(try editor.apply(.nudge(.x, .increase, .fine)).clamped)
        Self.expectPosition(editor, 1, -0.98)
        clamps.append(try editor.apply(.nudge(.y, .decrease, .coarse)).clamped)
        Self.expectPosition(editor, 1, -1, width: 0.97)
        clamps.append(try editor.apply(.nudge(.width, .increase, .coarse)).clamped)
        Self.expectPosition(editor, 1, -1, width: 1)
        var low = try Self.editor(-0.99, 0.99, width: 0.02)
        clamps.append(try low.apply(.nudge(.x, .decrease, .coarse)).clamped)
        clamps.append(try low.apply(.nudge(.y, .increase, .coarse)).clamped)
        clamps.append(try low.apply(.nudge(.width, .decrease, .coarse)).clamped)
        Self.expectPosition(low, -1, 1, width: 0)
        #expect(clamps == Array(repeating: true, count: 7))
        var exact = try Self.editor(0.95, -0.95, width: 0.95)
        let reached = [
            try exact.apply(.nudge(.x, .increase, .coarse)).clamped,
            try exact.apply(.nudge(.y, .decrease, .coarse)).clamped,
            try exact.apply(.nudge(.width, .increase, .coarse)).clamped
        ]
        #expect(reached == [false, false, false])
        Self.expectPosition(exact, 1, -1, width: 1)
    }

    @Test func exactEntryRefusesOutOfRangeAndNeverClamps() throws {
        var editor = try Self.editor(0.1, 0.6)
        Self.expectRefusal(&editor, .setExact(.x, 1.2), .valueOutOfRange(.x, 1.2))
        let outside: [(SpatialEditAxis, Double)] = [
            (.x, Double(1).nextUp), (.x, Double(-1).nextDown), (.y, Double(1).nextUp), (.y, -1.2),
            (.width, Double(1).nextUp), (.width, -0.01), (.width, Double(-0.0).nextDown)
        ]
        for (axis, value) in outside {
            Self.expectRefusal(&editor, .setExact(axis, value), .valueOutOfRange(axis, value))
        }
        for axis in SpatialEditAxis.allCases {
            for value in [Double.nan, .infinity, -.infinity] {
                Self.expectRefusal(&editor, .setExact(axis, value), .nonFiniteValue(axis))
            }
        }
        let inRange = try editor.apply(.setExact(.x, 1))
        #expect(!inRange.clamped)
        Self.expectPosition(editor, 1, 0.6, width: 0.5)
        try editor.apply(.setExact(.y, -1))
        Self.expectPosition(editor, 1, -1, width: 0.5)
        try editor.apply(.setExact(.x, 0.123))
        try editor.apply(.setExact(.y, -0.0))
        Self.expectPosition(editor, 0.123, 0, width: 0.5)
        for width in [0.0, 1, 0.333] {
            try editor.apply(.setExact(.width, width))
            Self.expectPosition(editor, 0.123, 0, width: width)
        }
    }

    @Test func snapsToNamedSpeakersAndCentre() throws {
        var editor = try Self.editor(0.1, 0.6, width: 0.3)
        try editor.apply(.snap(.speaker(Fixture.speaker("spk.fr"))))
        Self.expectPosition(editor, 1, 1, width: 0.3)
        try editor.apply(.snap(.speaker(Fixture.speaker("spk.c"))))
        Self.expectPosition(editor, 0, 0.8, width: 0.3)
        let outcome = try editor.apply(.snap(.centre))
        Self.expectPosition(editor, 0, 0, width: 0.3)
        #expect(!outcome.clamped)
        let unknown = try Fixture.speaker("spk.zz")
        Self.expectRefusal(&editor, .snap(.speaker(unknown)), .unknownSpeaker(unknown))
    }

    @Test func widthEditsNeedAStereoSource() throws {
        var mono = try Self.editor(0.1, 0.6, channels: 1)
        let source = mono.placement.sourceID
        for edit: SpatialPlacementEdit in [.nudge(.width, .increase, .coarse), .accessibilityDecrement(.width),
                                           .setExact(.width, 0.2), .setExact(.width, .nan), .setExact(.width, 2)] {
            Self.expectRefusal(&mono, edit, .widthRequiresStereo(source))
        }
        try mono.apply(.nudge(.x, .increase, .coarse))
        try mono.apply(.setExact(.y, 0.2))
        Self.expectPosition(mono, 0.15, 0.2, width: 0.5)
    }

    @Test func keyboardAccessibilityAndDragAgree() throws {
        typealias Edit = SpatialPlacementEdit
        #expect(Edit.arrow(.rightArrow, fine: false) == .accessibilityIncrement(.x))
        #expect(Edit.arrow(.leftArrow, fine: false) == .accessibilityDecrement(.x))
        #expect(Edit.arrow(.upArrow, fine: false) == .accessibilityIncrement(.y))
        #expect(Edit.arrow(.downArrow, fine: false) == .accessibilityDecrement(.y))
        #expect(Edit.arrow(.rightArrow, fine: true) == .nudge(.x, .increase, .fine))
        #expect(Edit.arrow(.leftArrow, fine: true) == .nudge(.x, .decrease, .fine))
        #expect(Edit.arrow(.upArrow, fine: true) == .nudge(.y, .increase, .fine))
        #expect(Edit.arrow(.downArrow, fine: true) == .nudge(.y, .decrease, .fine))
        #expect(Edit.accessibilityIncrement(.width) == .nudge(.width, .increase, .coarse))
        let accessibility: [SpatialArrowKey: Edit] = [
            .upArrow: .accessibilityIncrement(.y), .downArrow: .accessibilityDecrement(.y),
            .leftArrow: .accessibilityDecrement(.x), .rightArrow: .accessibilityIncrement(.x)
        ]
        let cases = [
            AgreementCase(start: (0.1, 0.6), key: .rightArrow, drag: (0.15, 0.6), end: (0.15, 0.6)),
            AgreementCase(start: (0.1, 0.6), key: .upArrow, drag: (0.1, 0.65), end: (0.1, 0.65)),
            AgreementCase(start: (-0.2, 0.3), key: .leftArrow, drag: (-0.25, 0.3), end: (-0.25, 0.3)),
            AgreementCase(start: (0.1, -0.3), key: .downArrow, drag: (0.1, -0.35), end: (0.1, -0.35)),
            AgreementCase(start: (0.98, 0.6), key: .rightArrow, drag: (1.03, 0.6), end: (1, 0.6)),
            AgreementCase(start: (0.1, -0.97), key: .downArrow, drag: (0.1, -1.02), end: (0.1, -1))
        ]
        for item in cases {
            var keyboard = try Self.editor(item.start.0, item.start.1)
            var voiceOver = keyboard
            var pointer = keyboard
            let typed = try keyboard.apply(.arrow(item.key, fine: false))
            let adjusted = try voiceOver.apply(try #require(accessibility[item.key]))
            let dragged = try pointer.apply(.drag(proposedX: item.drag.0, proposedY: item.drag.1))
            #expect(typed == adjusted && typed == dragged)
            #expect(keyboard == voiceOver && keyboard == pointer)
            Self.expectPosition(keyboard, item.end.0, item.end.1, width: 0.5)
            #expect(typed.clamped == (item.start.0 > 0.95 || item.start.1 < -0.95))
        }
    }

    @Test func exactEntryAndDragsStorePositiveZero() throws {
        var editor = try Self.editor(0.1, 0.6, width: 0.5)
        try editor.apply(.setExact(.x, -0.0))
        try editor.apply(.setExact(.y, -0.0))
        try editor.apply(.setExact(.width, -0.0))
        Self.expectPosition(editor, 0, 0, width: 0)
        #expect(editor.placement.position.x.sign == .plus && editor.placement.position.y.sign == .plus)
        #expect(editor.placement.width.sign == .plus)
        var dragged = try Self.editor(0.1, 0.6)
        let outcome = try dragged.apply(.drag(proposedX: -0.0, proposedY: -0.0))
        #expect(!outcome.clamped)
        #expect(dragged.placement.position.x.sign == .plus && dragged.placement.position.y.sign == .plus)
    }

    @Test func dragClampsThroughTheNudgePathAndRefusesNonFinite() throws {
        var editor = try Self.editor(0.1, 0.6, width: 0.4)
        let outside = try editor.apply(.drag(proposedX: 1.5, proposedY: -3))
        Self.expectPosition(editor, 1, -1, width: 0.4)
        let justOutside = try editor.apply(.drag(proposedX: -1.0000001, proposedY: 0.25))
        Self.expectPosition(editor, -1, 0.25, width: 0.4)
        let inside = try editor.apply(.drag(proposedX: 0.333, proposedY: -0.0))
        Self.expectPosition(editor, 0.333, 0, width: 0.4)
        #expect(outside.clamped && justOutside.clamped && !inside.clamped)
        Self.expectRefusal(&editor, .drag(proposedX: .nan, proposedY: 0), .nonFiniteValue(.x))
        Self.expectRefusal(&editor, .drag(proposedX: 0, proposedY: .infinity), .nonFiniteValue(.y))
        Self.expectRefusal(&editor, .drag(proposedX: -.infinity, proposedY: .nan), .nonFiniteValue(.x))
    }

    @Test func refusalsLeaveTheEditorUnchanged() throws {
        var stereo = try Self.editor(-0.4, 0.2, width: 0.7)
        let unknown = try Fixture.speaker("spk.none")
        let refusals: [(SpatialPlacementEdit, SpatialEditingRefusal)] = [
            (.setExact(.x, 1.2), .valueOutOfRange(.x, 1.2)), (.setExact(.y, -7), .valueOutOfRange(.y, -7)),
            (.setExact(.width, 1.5), .valueOutOfRange(.width, 1.5)), (.setExact(.y, .nan), .nonFiniteValue(.y)),
            (.drag(proposedX: 0.5, proposedY: .nan), .nonFiniteValue(.y)),
            (.snap(.speaker(unknown)), .unknownSpeaker(unknown))
        ]
        for (edit, refusal) in refusals { Self.expectRefusal(&stereo, edit, refusal) }
        Self.expectPosition(stereo, -0.4, 0.2, width: 0.7)
    }

    @Test func moveActionsListSpeakersInLayoutOrderThenCentre() throws {
        var editor = try Self.editor(0.1, 0.6)
        let actions = editor.moveActions
        #expect(actions.map(\.label) == ["Move to Front Left", "Move to Front Right", "Move to Rear Left",
                                         "Move to Rear Right", "Move to spk.c", "Move to centre"])
        #expect(actions.last?.edit == .snap(.centre))
        #expect(actions.first?.edit == .snap(.speaker(try Fixture.speaker("spk.fl"))))
        try editor.apply(actions[3].edit)
        Self.expectPosition(editor, 1, -1)
    }

    @Test func describesTheRulingExample() throws {
        #expect(Words.describe(try Fixture.point(0.1, 0.6)) == "slightly right of centre, in front; x 0.10, y 0.60")
    }

    @Test func bandEdgesBelongToTheOuterBand() throws {
        let slight = (right: "slightly right of centre", front: "slightly in front")
        let edges = [
            BandEdge(value: 0, band: .centre, right: "centre", front: "centre"),
            BandEdge(value: -0.0, band: .centre, right: "centre", front: "centre"),
            BandEdge(value: 0.004, band: .centre, right: "centre", front: "centre"),
            BandEdge(value: 0.04, band: .centre, right: "centre", front: "centre"),
            BandEdge(value: 0.0449, band: .centre, right: "centre", front: "centre"),
            BandEdge(value: Double(0.05).nextDown, band: .slight, right: slight.right, front: slight.front),
            BandEdge(value: 0.05, band: .slight, right: slight.right, front: slight.front),
            BandEdge(value: 0.34, band: .slight, right: slight.right, front: slight.front),
            BandEdge(value: 0.3449, band: .slight, right: slight.right, front: slight.front),
            BandEdge(value: Double(0.35).nextDown, band: .plain, right: "right of centre", front: "in front"),
            BandEdge(value: 0.35, band: .plain, right: "right of centre", front: "in front"),
            BandEdge(value: 0.74, band: .plain, right: "right of centre", front: "in front"),
            BandEdge(value: 0.7449, band: .plain, right: "right of centre", front: "in front"),
            BandEdge(value: Double(0.75).nextDown, band: .far, right: "far right", front: "far in front"),
            BandEdge(value: 0.75, band: .far, right: "far right", front: "far in front"),
            BandEdge(value: 1, band: .far, right: "far right", front: "far in front")
        ]
        for edge in edges {
            #expect(Words.band(edge.value) == edge.band && Words.band(-edge.value) == edge.band)
            #expect(Words.words(forX: edge.value) == edge.right)
            #expect(Words.words(forY: edge.value) == edge.front)
            #expect(Words.words(forX: -edge.value) == edge.right.replacing("right", with: "left"))
            #expect(Words.words(forY: -edge.value) == edge.front.replacing("in front", with: "behind"))
        }
    }

    @Test func bandsFollowThePrintedHundredths() throws {
        let rounded = try Fixture.point(0.0499, 0.3499)
        #expect(Words.describe(rounded) == "slightly right of centre, in front; x 0.05, y 0.35")
        #expect(Words.words(rounded) == Words.words(try Fixture.point(0.05, 0.35)))
        for hundredths in -100...100 {
            for offset in [-0.0051, -0.005, -0.0049, 0, 0.0049, 0.005, 0.0051] {
                let value = Double(hundredths) / 100 + offset
                let printed = try #require(Double(Words.number(value)))
                #expect(Words.band(value) == Words.band(printed), "\(value) prints \(printed)")
            }
        }
    }

    @Test func numbersUseTwoDecimalsAndNeverNegativeZero() {
        let cases: [(Double, String)] = [
            (0.1, "0.10"), (0.6, "0.60"), (-0.35, "-0.35"), (1, "1.00"), (-1, "-1.00"), (0, "0.00"),
            (-0.0, "0.00"), (-0.004, "0.00"), (0.125, "0.13"), (-0.125, "-0.13"), (0.07, "0.07"),
            (0.999, "1.00"), (0.049, "0.05"), (-0.5, "-0.50")
        ]
        for (value, text) in cases { #expect(Words.number(value) == text) }
    }

    @Test func describesCentreBothAxesAndSourceElements() throws {
        #expect(Words.describe(try Fixture.point(0, 0)) == "centre; x 0.00, y 0.00")
        #expect(Words.describe(try Fixture.point(0.049, -0.049))
            == "slightly right of centre, slightly behind; x 0.05, y -0.05")
        #expect(Words.describe(try Fixture.point(0.0049, -0.0049)) == "centre; x 0.00, y 0.00")
        #expect(Words.describe(try Fixture.point(0, 0.6)) == "centre, in front; x 0.00, y 0.60")
        #expect(Words.describe(try Fixture.point(0.6, 0)) == "right of centre, centre; x 0.60, y 0.00")
        #expect(Words.describe(try Fixture.point(-0.8, -0.2)) == "far left, slightly behind; x -0.80, y -0.20")
        let stereo = try Fixture.source(0.1, 0.6)
        #expect(Words.describe(stereo) == "Soft Synth, slightly right of centre, in front; x 0.10, y 0.60, width 0.50")
        let mono = try Fixture.source(0, 0, channels: 1, name: nil)
        #expect(Words.describe(mono) == "src.synth, centre; x 0.00, y 0.00")
        #expect(Words.value(of: .x, in: stereo) == "slightly right of centre, 0.10")
        #expect(Words.value(of: .y, in: stereo) == "in front, 0.60")
        #expect(Words.value(of: .width, in: stereo) == "0.50")
        #expect(Words.value(of: .x, in: mono) == "centre, 0.00" && Words.value(of: .y, in: mono) == "centre, 0.00")
        #expect(Words.value(of: .width, in: mono) == nil)
    }
}
