//
//  PerformPanelSurfaceTests.swift
//  FluxKlangTests
//
//  The perform panel surface (#102 PNS1): fixtures, placement, the focus order, per-entry refusals and the pinned
//  refusal order. Caps, pickup, the recall display, purity and the source scan are in the +Limits file.
//

import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

@Suite("Perform panel surface (#102 PNS1)", .productionAccessAudit)
struct PerformPanelSurfaceTests {
    typealias XYEntry = PerformPanelSurfaceXYEntry
    typealias RecallEntry = PerformPanelSurfaceRecallEntry

    static let openFacts = PerformPanelSurfaceXYFacts(resyncing: false, permitted: true, targetExists: true)

    static func layout(_ count: Int, width: WorkspaceWidthClass = .regular) throws -> PerformPanelLayout {
        try PerformPanelLayoutTests.build(try PerformPanelLayoutTests.entries(count), width: width)
    }

    static func cellID(_ raw: String) throws -> PerformPanelSurfaceCellID { try PerformPanelSurfaceCellID(raw) }

    static func epoch(_ generation: Int = 1) throws -> HostEpoch {
        HostEpoch(host: try HostID("host.main"), generation: try Generation(generation))
    }

    static func pad(waiting: Bool = false, position: Int = 5) throws -> PerformXYPad {
        let range = try PerformXYAxisRange.make(lower: 0, upper: 10)
        return try PerformXYPad.make(
            xRange: range, yRange: range, position: PerformXYPoint(x: position, y: position),
            pickup: waiting ? .waiting : .engaged, captureRadius: 1
        )
    }

    static func xyEntry(_ name: String, label: String? = nil, xTarget: String? = nil, yTarget: String? = nil,
                        controlClass: ControlClass = .live) throws -> XYEntry {
        try XYEntry(
            id: cellID("xy.\(name)"), label: label ?? "XY \(name)", xTarget: ParameterID(xTarget ?? "par.x.\(name)"),
            yTarget: ParameterID(yTarget ?? "par.y.\(name)"), controlClass: controlClass, pad: pad(), facts: openFacts
        )
    }

    static func altered(_ entry: XYEntry, pad: PerformXYPad? = nil, facts: PerformPanelSurfaceXYFacts? = nil,
                        id: String? = nil) throws -> XYEntry {
        try XYEntry(
            id: id.map { try cellID($0) } ?? entry.id, label: entry.label, xTarget: entry.xTarget,
            yTarget: entry.yTarget, controlClass: entry.controlClass, pad: pad ?? entry.pad,
            facts: facts ?? entry.facts
        )
    }

    static func recallFacts(controlClass: ControlClass = .live, resyncing: Bool = false, permitted: Bool = true,
                            targetExists: Bool = true,
                            readiness: ReadinessState = .ready) throws -> PerformRecallFacts {
        try PerformRecallFacts(
            epoch: epoch(), resyncing: resyncing, permitted: permitted, targetExists: targetExists,
            controlClass: controlClass, readiness: readiness
        )
    }

    static func recallEntry(_ name: String, label: String? = nil, patch: String? = nil, variation: String? = nil,
                            phase: PerformRecallPhase = .idle) throws -> RecallEntry {
        let target = try PerformRecallTarget(
            patch: PatchID(patch ?? "patch.\(name)"), variation: variation.map { try PerformRecallVariationID($0) }
        )
        return try RecallEntry(
            id: cellID("rc.\(name)"), label: label ?? "Recall \(name)", target: target, phase: phase,
            facts: recallFacts()
        )
    }

    static func alteredRecall(_ entry: RecallEntry, facts: PerformRecallFacts? = nil,
                              id: String? = nil) throws -> RecallEntry {
        try RecallEntry(
            id: id.map { try cellID($0) } ?? entry.id, label: entry.label, target: entry.target, phase: entry.phase,
            facts: facts ?? entry.facts
        )
    }

    static func surface(_ base: PerformPanelLayout, xy pads: [XYEntry] = [], recalls: [RecallEntry] = [],
                        previous: PerformPanelSurface? = nil) throws -> PerformPanelSurface {
        try PerformPanelSurface.make(layout: base, xy: pads, recalls: recalls, previous: previous)
    }

    /// The refusal of a surface over a layout of `cells` faders, or nil when it is accepted.
    static func refusal(_ cells: Int = 3, xy pads: [XYEntry] = [],
                        recalls: [RecallEntry] = []) throws -> PerformPanelSurfaceRefusal? {
        let base = try layout(cells)
        do {
            _ = try PerformPanelSurface.make(layout: base, xy: pads, recalls: recalls, previous: nil)
            return nil
        } catch {
            return error
        }
    }

    /// Row times one hundred plus column, so one golden list holds both coordinates.
    static func places(_ cells: [PerformPanelSurfaceXYCell]) -> [Int] { cells.map { $0.row * 100 + $0.column } }

    static func recallPlaces(_ cells: [PerformPanelSurfaceRecallCell]) -> [Int] {
        cells.map { $0.row * 100 + $0.column }
    }

    static func pads(_ names: [String]) throws -> [XYEntry] {
        var built: [XYEntry] = []
        for name in names { built.append(try xyEntry(name)) }
        return built
    }

    static func recalls(_ names: [String]) throws -> [RecallEntry] {
        var built: [RecallEntry] = []
        for name in names { built.append(try recallEntry(name)) }
        return built
    }

    // MARK: Empty blocks, placement

    @Test func noAddedCellsKeepTheLayoutItsCellCountAndItsMappedFocusOrderWithNoAnnouncements() throws {
        let base = try Self.layout(3)
        let built = try Self.surface(base)
        #expect(built.layout == base)
        #expect(built.xyCells.isEmpty)
        #expect(built.recallCells.isEmpty)
        #expect(built.cellCount == 3)
        let mapped = base.focusOrder.map { PerformPanelSurfaceStop.panel($0) }
        #expect(built.focusOrder == mapped)
        #expect(built.xyAnnouncements.isEmpty)
    }

    @Test func fiveXYCellsAtTwoColumnsGetTheHandTypedRowsAndColumns() throws {
        let base = try Self.layout(3, width: .compact)
        let built = try Self.surface(base, xy: try Self.pads(["a", "b", "c", "d", "e"]))
        #expect(base.columns == 2)
        let expected = [0, 1, 100, 101, 200]
        #expect(Self.places(built.xyCells) == expected)
    }

    @Test func fiveXYCellsAtFourColumnsGetTheHandTypedRowsAndColumns() throws {
        let base = try Self.layout(3)
        let built = try Self.surface(base, xy: try Self.pads(["a", "b", "c", "d", "e"]))
        #expect(base.columns == 4)
        let expected = [0, 1, 2, 3, 100]
        #expect(Self.places(built.xyCells) == expected)
    }

    @Test func theRecallBlockRestartsAtRowZeroAfterTheXYBlock() throws {
        let base = try Self.layout(3, width: .compact)
        let built = try Self.surface(
            base, xy: try Self.pads(["a", "b", "c"]), recalls: try Self.recalls(["r", "s", "t"]))
        let expected = [0, 1, 100]
        #expect(Self.places(built.xyCells) == expected)
        #expect(Self.recallPlaces(built.recallCells) == expected)
        let nine = 3 + 3 + 3
        #expect(built.cellCount == nine)
        let wide = try Self.surface(try Self.layout(3), recalls: try Self.recalls(["a", "b", "c", "d", "e"]))
        let wideExpected = [0, 1, 2, 3, 100]
        #expect(Self.recallPlaces(wide.recallCells) == wideExpected)
    }

    @Test func entriesKeepInputOrderAndTheLayoutSectionsAreUnchanged() throws {
        let base = try Self.layout(3)
        let built = try Self.surface(base, xy: try Self.pads(["c", "a", "b"]), recalls: try Self.recalls(["z", "y"]))
        let xyIDs = built.xyCells.map(\.id.rawValue)
        let recallIDs = built.recallCells.map(\.id.rawValue)
        let expectedXY = ["xy.c", "xy.a", "xy.b"]
        let expectedRecall = ["rc.z", "rc.y"]
        #expect(xyIDs == expectedXY)
        #expect(recallIDs == expectedRecall)
        #expect(built.layout.sections == base.sections)
        #expect(built.cellCount == 8)
    }

    @Test func anEmptyLayoutTakesOneHundredTwentyEightXYCells() throws {
        let limit = PerformPanelLimits.maximumEntries
        let names = (0..<limit).map { "n\($0)" }
        let built = try Self.surface(try Self.layout(0), xy: try Self.pads(names))
        #expect(built.xyCells.count == limit)
        #expect(built.cellCount == limit)
    }

    // MARK: Focus order

    @Test func theFocusOrderIsTheMappedLayoutStopsThenXYThenRecallInInputOrder() throws {
        let built = try Self.surface(
            try Self.layout(3), xy: try Self.pads(["a", "b"]), recalls: try Self.recalls(["r", "s"])
        )
        let expected: [PerformPanelSurfaceStop] = [
            .panel(.safety(.panic)), .panel(.safety(.safeMute)),
            .panel(.cell(PerformPanelLayoutTests.id(0))), .panel(.cell(PerformPanelLayoutTests.id(1))),
            .panel(.cell(PerformPanelLayoutTests.id(2))),
            .xy(try Self.cellID("xy.a")), .xy(try Self.cellID("xy.b")),
            .recall(try Self.cellID("rc.r")), .recall(try Self.cellID("rc.s"))
        ]
        #expect(built.focusOrder == expected)
    }

    @Test func aGroupedLayoutKeepsItsHeaderStopsBeforeTheAddedCells() throws {
        let grouped = [try PerformPanelLayoutTests.entry(0, group: "Mix"), try PerformPanelLayoutTests.entry(1)]
        let base = try PerformPanelLayoutTests.build(grouped)
        let built = try Self.surface(base, xy: try Self.pads(["a"]))
        let expected: [PerformPanelSurfaceStop] = [
            .panel(.safety(.panic)), .panel(.safety(.safeMute)), .panel(.groupHeader("Mix")),
            .panel(.cell(PerformPanelLayoutTests.id(0))), .panel(.cell(PerformPanelLayoutTests.id(1))),
            .xy(try Self.cellID("xy.a"))
        ]
        #expect(built.focusOrder == expected)
    }

    @Test func thePanicAndSafeMuteStopsComeFirstWithZeroOneAndOneHundredTwentyEightAddedCells() throws {
        for count in [0, 1, PerformPanelLimits.maximumEntries] {
            let names = (0..<count).map { "n\($0)" }
            let built = try Self.surface(try Self.layout(0), xy: try Self.pads(names))
            let stops = built.focusOrder
            let expectedCount = count + 2
            try #require(stops.count == expectedCount)
            #expect(stops[0] == .panel(.safety(.panic)))
            #expect(stops[1] == .panel(.safety(.safeMute)))
        }
    }

    @Test func theFocusOrderIsTheSameForRegularAndCompactWidths() throws {
        let pads = try Self.pads(["a", "b", "c"])
        let regular = try Self.surface(try Self.layout(3), xy: pads, recalls: try Self.recalls(["r"]))
        let compact = try Self.surface(try Self.layout(3, width: .compact), xy: pads, recalls: try Self.recalls(["r"]))
        #expect(regular.layout.columns != compact.layout.columns)
        #expect(regular.focusOrder == compact.focusOrder)
    }

    // MARK: Per-entry refusals

    @Test func onlyALiveXYClassIsAcceptedAndEveryOtherClassNamesItsSlotAndClass() throws {
        let accepted = try Self.refusal(xy: [try Self.xyEntry("a")])
        #expect(accepted == nil)
        let others: [ControlClass] = [.hazardous, .structural, .safety, .proposal]
        for other in others {
            let found = try Self.refusal(xy: [try Self.xyEntry("a"), try Self.xyEntry("b", controlClass: other)])
            #expect(found == .classNotPerformable(.xy(1), other))
        }
    }

    @Test func anXYLabelOfOneAndOneHundredTwentyEightBytesIsAcceptedAndZeroAndOneHundredTwentyNineAreRefused() throws {
        let lowest = PerformCellLimits.labelBytes.lowerBound
        let highest = PerformCellLimits.labelBytes.upperBound
        let lengths = [lowest, lowest + 1, highest - 1, highest]
        for length in lengths {
            let label = String(repeating: "a", count: length)
            #expect(try Self.refusal(xy: [try Self.xyEntry("a", label: label)]) == nil)
        }
        let empty = try Self.refusal(xy: [try Self.xyEntry("a"), try Self.xyEntry("b", label: "")])
        #expect(empty == .emptyLabel(.xy(1)))
        let over = highest + 1
        let long = try Self.refusal(xy: [try Self.xyEntry("a", label: String(repeating: "a", count: over))])
        #expect(long == .labelTooLong(.xy(0), bytes: over))
    }

    @Test func anXYLabelIsCountedInUTF8BytesNotCharacters() throws {
        let pairs = PerformCellLimits.labelBytes.upperBound / 2
        let full = String(repeating: "\u{E9}", count: pairs)
        let over = String(repeating: "\u{E9}", count: pairs + 1)
        #expect(try Self.refusal(xy: [try Self.xyEntry("a", label: full)]) == nil)
        let found = try Self.refusal(xy: [try Self.xyEntry("a", label: over)])
        let bytes = PerformCellLimits.labelBytes.upperBound + 2
        #expect(found == .labelTooLong(.xy(0), bytes: bytes))
    }

    @Test func aRecallLabelFollowsTheSameByteLimitsAndNamesItsRecallSlot() throws {
        let lowest = PerformCellLimits.labelBytes.lowerBound
        let highest = PerformCellLimits.labelBytes.upperBound
        for length in [lowest, highest - 1, highest] {
            let accepted = try Self.recallEntry("a", label: String(repeating: "b", count: length))
            #expect(try Self.refusal(recalls: [accepted]) == nil)
        }
        let empty = try Self.refusal(recalls: [try Self.recallEntry("a"), try Self.recallEntry("b", label: "")])
        #expect(empty == .emptyLabel(.recall(1)))
        let over = highest + 1
        let tooLong = try Self.recallEntry("a", label: String(repeating: "b", count: over))
        let long = try Self.refusal(recalls: [tooLong])
        #expect(long == .labelTooLong(.recall(0), bytes: over))
    }

    @Test func aPadWithTheSameTargetOnBothAxesIsRefusedAndTwoTargetsAreAccepted() throws {
        let same = try Self.xyEntry("a", xTarget: "par.same", yTarget: "par.same")
        #expect(try Self.refusal(xy: [try Self.xyEntry("b"), same]) == .sameTargetOnBothAxes(.xy(1)))
        #expect(try Self.refusal(xy: [try Self.xyEntry("b")]) == nil)
    }

    // MARK: Cross-entry refusals

    @Test func aRepeatedCellIDNamesTheLaterSlotAcrossXYAndRecallCells() throws {
        let first = try Self.xyEntry("a")
        let twin = try Self.altered(try Self.xyEntry("b"), id: "xy.a")
        #expect(try Self.refusal(xy: [first, twin]) == .duplicateCellID(.xy(1)))
        let recall = try Self.alteredRecall(try Self.recallEntry("r"), id: "xy.a")
        #expect(try Self.refusal(xy: [first], recalls: [recall]) == .duplicateCellID(.recall(0)))
        let recallTwin = try Self.alteredRecall(try Self.recallEntry("s"), id: "rc.r")
        let recalls = [try Self.recallEntry("r"), recallTwin]
        #expect(try Self.refusal(recalls: recalls) == .duplicateCellID(.recall(1)))
    }

    @Test func aTargetUsedByTheLayoutOrAnEarlierPadAxisIsRefusedByParameter() throws {
        let first = try Self.xyEntry("a")
        let ownX = try Self.xyEntry("b", xTarget: "par.c1")
        #expect(try Self.refusal(xy: [ownX]) == .duplicateTarget(PerformPanelLayoutTests.id(1)))
        let ownY = try Self.xyEntry("b", yTarget: "par.c2")
        #expect(try Self.refusal(xy: [ownY]) == .duplicateTarget(PerformPanelLayoutTests.id(2)))
        let againstY = try Self.xyEntry("b", xTarget: "par.y.a")
        #expect(try Self.refusal(xy: [first, againstY]) == .duplicateTarget(try ParameterID("par.y.a")))
        let againstX = try Self.xyEntry("b", yTarget: "par.x.a")
        #expect(try Self.refusal(xy: [first, againstX]) == .duplicateTarget(try ParameterID("par.x.a")))
    }

    @Test func whenBothAxesOfAPadRepeatATargetTheXAxisIsReported() throws {
        let first = try Self.xyEntry("a")
        let both = try Self.xyEntry("b", xTarget: "par.x.a", yTarget: "par.y.a")
        #expect(try Self.refusal(xy: [first, both]) == .duplicateTarget(try ParameterID("par.x.a")))
    }

    @Test func aRecallTargetRepeatedWithTheSamePatchAndVariationIsRefusedAndOtherPairsAreAccepted() throws {
        let base = try Self.recallEntry("a", patch: "patch.p", variation: "var.1")
        let same = try Self.recallEntry("b", patch: "patch.p", variation: "var.1")
        #expect(try Self.refusal(recalls: [base, same]) == .duplicateRecallTarget(.recall(1)))
        let bare = try Self.recallEntry("c", patch: "patch.p")
        let bareTwin = try Self.recallEntry("d", patch: "patch.p")
        #expect(try Self.refusal(recalls: [bare, bareTwin]) == .duplicateRecallTarget(.recall(1)))
        let otherVariation = try Self.recallEntry("e", patch: "patch.p", variation: "var.2")
        let otherPatch = try Self.recallEntry("f", patch: "patch.q", variation: "var.1")
        #expect(try Self.refusal(recalls: [base, otherVariation, bare, otherPatch]) == nil)
    }

    @Test func aRepeatedLabelNamesTheLaterSlotAgainstTheLayoutAnXYCellAndARecallCell() throws {
        let againstLayout = try Self.refusal(xy: [try Self.xyEntry("a", label: "Cell 1")])
        #expect(againstLayout == .duplicateLabel(.xy(0)))
        let xyPair = try Self.refusal(xy: [try Self.xyEntry("a", label: "Same"), try Self.xyEntry("b", label: "Same")])
        #expect(xyPair == .duplicateLabel(.xy(1)))
        let recall = try Self.recallEntry("r", label: "Same")
        let mixed = try Self.refusal(xy: [try Self.xyEntry("a", label: "Same")], recalls: [recall])
        #expect(mixed == .duplicateLabel(.recall(0)))
        let recallLayout = try Self.refusal(recalls: [try Self.recallEntry("r", label: "Cell 2")])
        #expect(recallLayout == .duplicateLabel(.recall(0)))
        let pair = [try Self.recallEntry("r"), try Self.recallEntry("s", label: "Cell 2")]
        let laterRecall = try Self.refusal(recalls: pair)
        #expect(laterRecall == .duplicateLabel(.recall(1)))
    }

    @Test func labelsThatDifferOnlyByCanonicalEquivalenceCoexistAndTheSameBytesCollide() throws {
        let precomposed = try Self.xyEntry("a", label: "caf\u{E9}")
        let decomposed = try Self.xyEntry("b", label: "cafe\u{301}")
        #expect(try Self.refusal(xy: [precomposed, decomposed]) == nil)
        let repeated = try Self.xyEntry("c", label: "caf\u{E9}")
        #expect(try Self.refusal(xy: [precomposed, repeated]) == .duplicateLabel(.xy(1)))
    }

    // MARK: Refusal order

    @Test func theCellCapIsCheckedBeforeAnEntryWithAnEmptyLabel() throws {
        let limit = PerformPanelLimits.maximumEntries
        var entries = [try Self.xyEntry("first", label: "")]
        for index in 0..<limit { entries.append(try Self.xyEntry("n\(index)")) }
        let over = limit + 1
        #expect(try Self.refusal(0, xy: entries) == .tooManyCells(count: over))
    }

    @Test func anXYEntryIsCheckedForClassThenLabelThenTargets() throws {
        let allThree = try Self.xyEntry(
            "a", label: "", xTarget: "par.same", yTarget: "par.same", controlClass: .hazardous)
        #expect(try Self.refusal(xy: [allThree]) == .classNotPerformable(.xy(0), .hazardous))
        let labelAndTargets = try Self.xyEntry("a", label: "", xTarget: "par.same", yTarget: "par.same")
        #expect(try Self.refusal(xy: [labelAndTargets]) == .emptyLabel(.xy(0)))
        let tooLong = try Self.xyEntry("a", label: String(repeating: "a", count: 129), xTarget: "par.same",
                                       yTarget: "par.same")
        #expect(try Self.refusal(xy: [tooLong]) == .labelTooLong(.xy(0), bytes: 129))
    }

    @Test func everyXYEntryIsCheckedBeforeAnyRecallEntry() throws {
        let badRecall = try Self.recallEntry("r", label: "")
        let pads = [try Self.xyEntry("a"), try Self.xyEntry("b", label: "")]
        #expect(try Self.refusal(xy: pads, recalls: [badRecall]) == .emptyLabel(.xy(1)))
    }

    @Test func anInvalidRecallLabelIsRefusedBeforeARepeatedCellID() throws {
        let twinXY = [try Self.xyEntry("a"), try Self.xyEntry("a")]
        let badRecall = try Self.recallEntry("r", label: "")
        #expect(try Self.refusal(xy: twinXY, recalls: [badRecall]) == .emptyLabel(.recall(0)))
    }

    @Test func aRepeatedCellIDIsRefusedBeforeARepeatedTargetOnTheSameEntries() throws {
        let first = try Self.xyEntry("a", xTarget: "par.c1")
        let twin = try Self.xyEntry("a", xTarget: "par.c1")
        #expect(try Self.refusal(xy: [first, twin]) == .duplicateCellID(.xy(1)))
    }

    @Test func aRepeatedParameterIsRefusedBeforeARepeatedRecallTarget() throws {
        let clash = try Self.xyEntry("a", xTarget: "par.c1")
        let first = try Self.recallEntry("r", patch: "patch.p")
        let twin = try Self.recallEntry("s", patch: "patch.p")
        let found = try Self.refusal(xy: [clash], recalls: [first, twin])
        #expect(found == .duplicateTarget(PerformPanelLayoutTests.id(1)))
    }

    @Test func aRepeatedRecallTargetIsRefusedBeforeARepeatedLabel() throws {
        let first = try Self.recallEntry("r", label: "Same", patch: "patch.p")
        let twin = try Self.recallEntry("s", label: "Same", patch: "patch.p")
        #expect(try Self.refusal(recalls: [first, twin]) == .duplicateRecallTarget(.recall(1)))
    }

    @Test func inEveryStepTheEarlierOfTwoDefectsIsNamed() throws {
        let classes = [try Self.xyEntry("a"), try Self.xyEntry("b", controlClass: .safety),
                       try Self.xyEntry("c", controlClass: .proposal)]
        #expect(try Self.refusal(xy: classes) == .classNotPerformable(.xy(1), .safety))
        let labels = [
            try Self.recallEntry("r"), try Self.recallEntry("s", label: ""), try Self.recallEntry("t", label: "")
        ]
        #expect(try Self.refusal(recalls: labels) == .emptyLabel(.recall(1)))
        let ids = try Self.pads(["a", "b", "b", "a"])
        #expect(try Self.refusal(xy: ids) == .duplicateCellID(.xy(2)))
        let targets = [try Self.xyEntry("a", xTarget: "par.c1"), try Self.xyEntry("b", xTarget: "par.c2")]
        #expect(try Self.refusal(xy: targets) == .duplicateTarget(PerformPanelLayoutTests.id(1)))
        let recallPairs = [try Self.recallEntry("a", patch: "patch.p"), try Self.recallEntry("b", patch: "patch.p"),
                           try Self.recallEntry("c", patch: "patch.p")]
        #expect(try Self.refusal(recalls: recallPairs) == .duplicateRecallTarget(.recall(1)))
        let sameLabels = [try Self.xyEntry("a", label: "Cell 0"), try Self.xyEntry("b", label: "Cell 1")]
        #expect(try Self.refusal(xy: sameLabels) == .duplicateLabel(.xy(0)))
    }
}
