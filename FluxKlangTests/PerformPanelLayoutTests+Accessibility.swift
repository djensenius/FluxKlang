//
//  PerformPanelLayoutTests+Accessibility.swift
//  FluxKlangTests
//
//  The focus order, pickup announcements, previous-layout lookup, signal truthfulness and determinism of the perform
//  panel layout (#102 PNL1), plus a gated check of the production sources.
//

import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension PerformPanelLayoutTests {
    static func measuredMeter(_ dbfs: Double) throws -> MeterDisplay {
        var model = try MeterDisplayModel(
            source: MeterSource.tap(channels: 1),
            staleness: MeterStalenessWindow.make(nanoseconds: 500_000_000),
            ballistics: MeterBallistics.make(peakHoldNanoseconds: 1_000_000_000, decayDecibelsPerSecond: 20,
                                             floorDBFS: -60, clipThresholdDBFS: 0)
        )
        let now = MeterInstant(nanoseconds: 0)
        let read: TelemetryRead<MeterTapValue> = .measured(TelemetrySample(
            value: MeterTapValue(peakDBFS: dbfs), stamp: TelemetryStamp(clockGeneration: 1, frame: 0), sequence: 1))
        let classified = try MeterClassifiedRead.classify(read, generation: 1, frame: 0, maximumAgeFrames: 24_000,
                                                          at: now)
        return try model.update([classified], at: now)
    }

    static func cellStops(_ numbers: [Int]) -> [PerformPanelFocusStop] {
        numbers.map { PerformPanelFocusStop.cell(id($0)) }
    }

    /// One byte array per stop, so labels that differ only by canonical equivalence stay distinct.
    static func stopBytes(_ stops: [PerformPanelFocusStop]) -> [[UInt8]] {
        stops.map { (stop: PerformPanelFocusStop) -> [UInt8] in
            switch stop {
            case .safety(let operation): Array("safety:\(operation)".utf8)
            case .groupHeader(let group): Array("header:".utf8) + Array(group.utf8)
            case .cell(let parameter): Array("cell:\(parameter)".utf8)
            }
        }
    }

    @Test func theFocusOrderIsTheSafetyStripThenEachLabelledSectionsHeaderAndCellsWithNoHeaderForUngrouped() throws {
        let layout = try Self.build(try Self.grouped(["Mains", nil, "Vocals", "Mains", nil]))
        var expected: [PerformPanelFocusStop] = [.safety(.panic), .safety(.safeMute), .groupHeader("Mains")]
        expected.append(contentsOf: Self.cellStops([0, 3, 1, 4]))
        expected.append(.groupHeader("Vocals"))
        expected.append(contentsOf: Self.cellStops([2]))
        #expect(layout.focusOrder == expected)
        let found = Self.stopBytes(layout.focusOrder)
        let wanted = Self.stopBytes(expected)
        #expect(found == wanted)
        let cellsOnly = try Self.build(try Self.entries(3))
        var plain: [PerformPanelFocusStop] = [.safety(.panic), .safety(.safeMute)]
        plain.append(contentsOf: Self.cellStops([0, 1, 2]))
        #expect(cellsOnly.focusOrder == plain)
    }

    @Test func everyCellHasExactlyOneFocusStopAndTheOrderIsTheSameAtBothWidths() throws {
        let layout = try Self.build(try Self.grouped(["B", "A", nil, "B", "C", "A"]), width: .regular)
        let compact = try Self.build(try Self.grouped(["B", "A", nil, "B", "C", "A"]), width: .compact)
        var seen = Set<ParameterID>()
        var cellStopCount = 0
        for stop in layout.focusOrder {
            if case .cell(let parameter) = stop {
                cellStopCount += 1
                seen.insert(parameter)
            }
        }
        #expect(cellStopCount == 6)
        #expect(seen.count == 6)
        #expect(layout.focusOrder == compact.focusOrder)
        let regularBytes = Self.stopBytes(layout.focusOrder)
        let compactBytes = Self.stopBytes(compact.focusOrder)
        #expect(regularBytes == compactBytes)
    }

    @Test func pickupAnnouncementsListEveryNewlyWaitingCellInFocusOrderNotInputOrder() throws {
        let groups: [String?] = ["B", "A", "B", "A"]
        var panel: [PerformPanelEntry] = []
        for (number, group) in groups.enumerated() {
            let base = try Self.entry(number, group: group)
            panel.append(number < 3 ? Self.waiting(base) : base)
        }
        let layout = try Self.build(panel)
        let expected: [ParameterID] = Self.ids([0, 2, 1])
        #expect(layout.pickupAnnouncements == expected)
        let plain = try Self.build(try Self.grouped(["B", "A"]))
        #expect(plain.pickupAnnouncements.isEmpty)
    }

    @Test func aCellThatWasAlreadyWaitingIsNotAnnouncedAgainAndItsModelIsOtherwiseReproduced() throws {
        let panel = [Self.waiting(try Self.entry(0)), try Self.entry(1, group: "Mains"),
                     Self.waiting(try Self.entry(2, group: "Mains"))]
        let first = try Self.build(panel)
        let second = try Self.build(panel, previous: first)
        let firstAnnounced: [ParameterID] = Self.ids([0, 2])
        #expect(first.pickupAnnouncements == firstAnnounced)
        #expect(second.pickupAnnouncements.isEmpty)
        let before = Self.cells(first)
        let after = Self.cells(second)
        #expect(before.count == after.count)
        for (old, new) in zip(before, after) {
            #expect(old.model.descriptor == new.model.descriptor)
            #expect(old.model.value == new.model.value)
            #expect(old.model.label == new.model.label)
            #expect(old.model.states == new.model.states)
            #expect(old.model.inputResult == new.model.inputResult)
            #expect(old.model.signal == new.model.signal)
            #expect(!new.model.announcesPickup)
        }
        #expect(second.focusOrder == first.focusOrder)
    }

    @Test func thePreviousLayoutIsLookedUpByParameterNotByPositionWhenTheEntriesWereReordered() throws {
        let before = try Self.build([Self.waiting(try Self.entry(0)), try Self.entry(1)])
        #expect(before.pickupAnnouncements == Self.ids([0]))
        let reordered = [Self.waiting(try Self.entry(1)), Self.waiting(try Self.entry(0))]
        let after = try Self.build(reordered, previous: before)
        let expected: [ParameterID] = Self.ids([1])
        #expect(after.pickupAnnouncements == expected)
        let unrelated = try Self.build([Self.waiting(try Self.entry(7))])
        let fresh = try Self.build([Self.waiting(try Self.entry(0))], previous: unrelated)
        let announced: [ParameterID] = Self.ids([0])
        #expect(fresh.pickupAnnouncements == announced)
    }

    @Test func aStateChangeOnOneCellChangesOnlyThatCellsModelAndTheAnnouncementList() throws {
        let groups: [String?] = ["A", "B", "A", "B", nil]
        var baseline: [PerformPanelEntry] = []
        for (number, group) in groups.enumerated() {
            var base = try Self.entry(number, group: group)
            base.input.labels.binding = "Fader \(number)"
            base.input.facts.pickup = .engaged(hardware: nil)
            baseline.append(base)
        }
        let before = try Self.build(baseline)
        #expect(before.pickupAnnouncements.isEmpty)
        var changed = baseline
        try #require(changed.count == 5)
        changed[3].input.facts.pickup = .waiting(hardware: nil)
        let after = try Self.build(changed, previous: before)
        let oldCells = Self.cells(before)
        let newCells = Self.cells(after)
        #expect(oldCells.count == newCells.count)
        for (old, new) in zip(oldCells, newCells) {
            if new.model.parameterID == Self.id(3) {
                #expect(new.model.states.contains(.waitingForPickup))
                #expect(new.model.announcesPickup)
                #expect(old.model != new.model)
            } else {
                #expect(old.model == new.model)
            }
        }
        let announced: [ParameterID] = Self.ids([3])
        #expect(after.pickupAnnouncements == announced)
        #expect(after.focusOrder == before.focusOrder)
        #expect(after.safety == before.safety)
        #expect(Self.scalarGroups(after) == Self.scalarGroups(before))
    }

    @Test func eachCellsAccessibilityElementCarriesItsLabelAndOnlyAnnouncedCellsAnnounce() throws {
        let before = try Self.build([Self.waiting(try Self.entry(0)), try Self.entry(1)])
        let panel = [Self.waiting(try Self.entry(0)), Self.waiting(try Self.entry(1, group: "Mains")),
                     try Self.entry(2)]
        let layout = try Self.build(panel, previous: before)
        let announced: [ParameterID] = Self.ids([1])
        #expect(layout.pickupAnnouncements == announced)
        for cell in Self.cells(layout) {
            let element = cell.model.accessibility
            #expect(element.label == cell.model.label)
            let listed = layout.pickupAnnouncements.contains(cell.model.parameterID)
            #expect((element.announcement != nil) == listed)
        }
    }

    @Test func faderMotionNeverChangesTheSignalAndTheLayoutNeverReplacesTheEntrysMeter() throws {
        let measured = try Self.measuredMeter(-14.5)
        var low = try Self.entry(0)
        var high = try Self.entry(0)
        low.input.meter = measured
        high.input.meter = measured
        low.input.value = ParameterValue(value: -60, unit: .decibels)
        high.input.value = ParameterValue(value: -8, unit: .decibels)
        let lowCells = Self.cells(try Self.build([low]))
        let highCells = Self.cells(try Self.build([high]))
        let lowCell = try #require(lowCells.first)
        let highCell = try #require(highCells.first)
        let levels: [Double] = [-14.5]
        #expect(lowCell.model.signal == highCell.model.signal)
        #expect(lowCell.model.signal.levelsDBFS == levels)
        #expect(lowCell.model.value != highCell.model.value)
        let silent = try Self.cells(Self.build([try Self.entry(0)]))
        let silentCell = try #require(silent.first)
        let unavailable: PerformSignal = .unavailable(.neverPublished)
        #expect(silentCell.model.signal == unavailable)
    }

    @Test func repeatingTheSameBuildGivesEqualLayoutsAtBothWidths() throws {
        let panel = [Self.waiting(try Self.entry(0, group: "A")), try Self.entry(1), try Self.entry(2, group: "A")]
        for width in [WorkspaceWidthClass.regular, .compact] {
            let first = try Self.build(panel, width: width)
            for _ in 0..<4 {
                let again = try Self.build(panel, width: width)
                #expect(again == first)
            }
            let chained = try Self.build(panel, width: width, previous: first)
            #expect(try Self.build(panel, width: width, previous: first) == chained)
        }
    }

    static func namedEntry(_ id: String, label: String) throws -> PerformPanelEntry {
        let input = try PerformCellInput(
            descriptor: descriptor(id, unit: .decibels), value: shownValue(.decibels),
            labels: PerformCellLabels(cell: label, binding: ""), facts: PerformCellFacts(),
            meter: .unavailable(.neverPublished)
        )
        return PerformPanelEntry(kind: .fader, group: nil, input: input)
    }

    @Test func parametersNamedLikeSafetyOperationsNeverDisplaceTheStripAndTheOrderFollowsTheEntries() throws {
        let panic = try Self.namedEntry("par.panic", label: "Panic level")
        let mute = try Self.namedEntry("par.safeMute", label: "Safe mute level")
        let other = try Self.entry(1)
        let forward = try Self.build([panic, other, mute])
        let backward = try Self.build([mute, other, panic])
        let strip: [CommandOperation] = [.panic, .safeMute]
        #expect(forward.safety == strip)
        #expect(backward.safety == strip)
        let panicStop = PerformPanelFocusStop.cell(try ParameterID("par.panic"))
        let muteStop = PerformPanelFocusStop.cell(try ParameterID("par.safeMute"))
        let otherStop = PerformPanelFocusStop.cell(Self.id(1))
        let forwardExpected: [PerformPanelFocusStop] = [.safety(.panic), .safety(.safeMute), panicStop, otherStop,
                                                        muteStop]
        let backwardExpected: [PerformPanelFocusStop] = [.safety(.panic), .safety(.safeMute), muteStop, otherStop,
                                                         panicStop]
        #expect(forward.focusOrder == forwardExpected)
        #expect(backward.focusOrder == backwardExpected)
    }

    static let panelSourceNames = [
        "PerformPanelEntry.swift", "PerformPanelRefusal.swift", "PerformPanelLayout.swift", "PerformPanelFocus.swift"
    ]

    /// The production files of the panel, read from the checkout or from the package mirror; empty when absent.
    static func panelSources() -> [String] {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let relative = "Shared/Views/Workspace/Perform/Panel/"
        let roots = [folder.deletingLastPathComponent(), folder.deletingLastPathComponent().deletingLastPathComponent()]
        var directories: [URL] = []
        for root in roots {
            directories.append(root.appendingPathComponent(relative))
            directories.append(root.appendingPathComponent("Sources/FluxKlang/" + relative))
        }
        for directory in directories {
            let texts = panelSourceNames.compactMap {
                try? String(contentsOf: directory.appendingPathComponent($0), encoding: .utf8)
            }
            if texts.count == panelSourceNames.count { return texts }
        }
        return []
    }

    @Test(.enabled(if: !PerformPanelLayoutTests.panelSources().isEmpty))
    func theProductionFilesNameNoViewClockTaskQueueOrFoundationAndEveryFileIsRead() {
        let texts = Self.panelSources()
        #expect(texts.count == 4)
        let banned = ["import SwiftUI", "import Foundation", "import Combine", "Date(", "Clock", "Task",
                      "DispatchQueue", "Observation", "random"]
        for text in texts {
            for token in banned { #expect(!text.contains(token)) }
        }
    }
}
