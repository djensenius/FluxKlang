//
//  PerformPanelSurfaceTests+Limits.swift
//  FluxKlangTests
//
//  The perform panel surface (#102 PNS1): XY states, the pickup announcement, the recall display, the shared cell cap,
//  determinism and the source scan.
//

import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension PerformPanelSurfaceTests {
    static func waitingPad(_ name: String, xTarget: String? = nil, yTarget: String? = nil,
                           position: Int = 5) throws -> XYEntry {
        let base = try xyEntry(name, xTarget: xTarget, yTarget: yTarget)
        return try altered(base, pad: try pad(waiting: true, position: position))
    }

    static func onlyPad(_ built: PerformPanelSurface) throws -> PerformPanelSurfaceXYCell {
        try #require(built.xyCells.count == 1)
        return built.xyCells[0]
    }

    static func onlyRecall(_ built: PerformPanelSurface) throws -> PerformPanelSurfaceRecallCell {
        try #require(built.recallCells.count == 1)
        return built.recallCells[0]
    }

    static func display(_ entry: RecallEntry) throws -> PerformPanelSurfaceRecallDisplay {
        try onlyRecall(try surface(try layout(1), recalls: [entry])).display
    }

    struct GateCase {
        let facts: PerformPanelSurfaceXYFacts
        let lead: PerformCellState
        let result: PerformInputResult
    }

    static func announced(_ built: PerformPanelSurface) -> [String] { built.xyAnnouncements.map(\.rawValue) }

    // MARK: XY states

    @Test func anEngagedPadShowsEngagedAndAcceptsAndAWaitingPadShowsWaitingForPickupAndHoldsInput() throws {
        let engaged = try Self.onlyPad(try Self.surface(try Self.layout(1), xy: [try Self.xyEntry("a")]))
        let engagedStates: [PerformCellState] = [.engaged]
        #expect(engaged.states == engagedStates)
        #expect(engaged.inputResult == .accepted)
        let waiting = try Self.onlyPad(try Self.surface(try Self.layout(1), xy: [try Self.waitingPad("a")]))
        let waitingStates: [PerformCellState] = [.waitingForPickup]
        #expect(waiting.states == waitingStates)
        #expect(waiting.inputResult == .heldForPickup)
    }

    @Test func resyncingNoPermissionAndNoTargetEachLeadTheStatesAndGiveTheirOwnInputResult() throws {
        let base = try Self.xyEntry("a")
        let resyncing = PerformPanelSurfaceXYFacts(resyncing: true, permitted: true, targetExists: true)
        let denied = PerformPanelSurfaceXYFacts(resyncing: false, permitted: false, targetExists: true)
        let missing = PerformPanelSurfaceXYFacts(resyncing: false, permitted: true, targetExists: false)
        let cases = [
            GateCase(facts: resyncing, lead: .resyncing, result: .droppedStaleIntent),
            GateCase(facts: denied, lead: .notPermittedHere, result: .rejectedPermission),
            GateCase(facts: missing, lead: .noTarget, result: .disabled(.noTarget))
        ]
        for gate in cases {
            let entry = try Self.altered(base, facts: gate.facts)
            let cell = try Self.onlyPad(try Self.surface(try Self.layout(1), xy: [entry]))
            let expected: [PerformCellState] = [gate.lead, .engaged]
            #expect(cell.states == expected)
            #expect(cell.inputResult == gate.result)
        }
        let both = try Self.altered(try Self.waitingPad("b"), facts: resyncing)
        let held = try Self.onlyPad(try Self.surface(try Self.layout(1), xy: [both]))
        let heldStates: [PerformCellState] = [.resyncing, .waitingForPickup]
        #expect(held.states == heldStates)
        #expect(held.inputResult == .droppedStaleIntent)
    }

    @Test func aStoredPadEqualsTheEntrysPadWaitingOrEngagedAndTheCellKeepsTheEntryFields() throws {
        let entries = [try Self.xyEntry("a"), try Self.waitingPad("b", position: 7)]
        let built = try Self.surface(try Self.layout(1), xy: entries)
        try #require(built.xyCells.count == 2)
        for (cell, entry) in zip(built.xyCells, entries) {
            #expect(cell.pad == entry.pad)
            #expect(cell.id == entry.id)
            #expect(cell.label == entry.label)
            #expect(cell.xTarget == entry.xTarget)
            #expect(cell.yTarget == entry.yTarget)
        }
        #expect(built.xyCells[1].pad.pickup == .waiting)
    }

    // MARK: Pickup announcement

    @Test func aWaitingPadAnnouncesOnFirstSightInFocusOrderAndAnEngagedPadDoesNot() throws {
        let entries = [
            try Self.waitingPad("a"), try Self.xyEntry("b"), try Self.waitingPad("c"), try Self.waitingPad("d")
        ]
        let built = try Self.surface(try Self.layout(1), xy: entries)
        let expected = ["xy.a", "xy.c", "xy.d"]
        #expect(Self.announced(built) == expected)
        let flags = built.xyCells.map(\.announcesPickup)
        let expectedFlags = [true, false, true, true]
        #expect(flags == expectedFlags)
    }

    @Test func aPadStillWaitingWithTheSameIDAndTargetsIsNotAnnouncedAgainEvenWhenItsPositionMoved() throws {
        let first = try Self.surface(try Self.layout(1), xy: [try Self.waitingPad("a")])
        let same = try Self.surface(try Self.layout(1), xy: [try Self.waitingPad("a")], previous: first)
        #expect(same.xyAnnouncements.isEmpty)
        let moved = try Self.surface(try Self.layout(1), xy: [try Self.waitingPad("a", position: 8)], previous: first)
        #expect(moved.xyAnnouncements.isEmpty)
        #expect(try Self.onlyPad(moved).announcesPickup == false)
    }

    @Test func aPadIsLookedUpByIDAndNotByPlaceSoReorderingTwoWaitingPadsAnnouncesNothing() throws {
        let first = try Self.surface(try Self.layout(1), xy: [try Self.waitingPad("a"), try Self.waitingPad("b")])
        let swapped = try Self.surface(
            try Self.layout(1), xy: [try Self.waitingPad("b"), try Self.waitingPad("a")], previous: first
        )
        #expect(swapped.xyAnnouncements.isEmpty)
    }

    @Test func aPadThatMovesFromEngagedToWaitingAnnouncesOnThatUpdate() throws {
        let first = try Self.surface(try Self.layout(1), xy: [try Self.xyEntry("a")])
        let next = try Self.surface(try Self.layout(1), xy: [try Self.waitingPad("a")], previous: first)
        #expect(Self.announced(next) == ["xy.a"])
    }

    @Test func aRetargetedWaitingPadAnnouncesAgainWhicheverTargetChanged() throws {
        let first = try Self.surface(try Self.layout(1), xy: [try Self.waitingPad("a")])
        let newY = try Self.surface(
            try Self.layout(1), xy: [try Self.waitingPad("a", yTarget: "par.y.other")], previous: first
        )
        #expect(Self.announced(newY) == ["xy.a"])
        let newX = try Self.surface(
            try Self.layout(1), xy: [try Self.waitingPad("a", xTarget: "par.x.other")], previous: first
        )
        #expect(Self.announced(newX) == ["xy.a"])
    }

    @Test func aPreviousPadWithAnotherIDDoesNotSuppressTheAnnouncement() throws {
        let first = try Self.surface(try Self.layout(1), xy: [try Self.waitingPad("z")])
        let next = try Self.surface(try Self.layout(1), xy: [try Self.waitingPad("a")], previous: first)
        #expect(Self.announced(next) == ["xy.a"])
    }

    // MARK: Recall display

    @Test func anIdleLiveRecallIsReadyAndAnIdleHazardousRecallNeedsAConfirm() throws {
        let live = try Self.recallEntry("a")
        #expect(try Self.display(live) == .ready)
        let hazardous = try Self.alteredRecall(live, facts: try Self.recallFacts(controlClass: .hazardous))
        #expect(try Self.display(hazardous) == .needsConfirm)
    }

    @Test func aRecallAwaitingAConfirmOrFiredUnderTheLiveEpochShowsThatPhase() throws {
        let epoch = try Self.epoch()
        let waiting = try Self.recallEntry("a", phase: .awaitingConfirm(epoch))
        #expect(try Self.display(waiting) == .awaitingConfirm)
        let fired = try Self.recallEntry("b", phase: .fired(epoch))
        #expect(try Self.display(fired) == .fired)
    }

    @Test func eachRecallGateShowsItsOwnDisplayAndTheEntryPhaseIsStoredUnchanged() throws {
        let base = try Self.recallEntry("a")
        let resyncing = try Self.alteredRecall(base, facts: try Self.recallFacts(resyncing: true))
        #expect(try Self.display(resyncing) == .dropped(.resyncing))
        let denied = try Self.alteredRecall(base, facts: try Self.recallFacts(permitted: false))
        #expect(try Self.display(denied) == .refused(.notPermitted))
        let missing = try Self.alteredRecall(base, facts: try Self.recallFacts(targetExists: false))
        #expect(try Self.display(missing) == .refused(.noTarget))
        let structural = try Self.alteredRecall(base, facts: try Self.recallFacts(controlClass: .structural))
        #expect(try Self.display(structural) == .refused(.classNotPerformable(.structural)))
        let unready = try Self.alteredRecall(base, facts: try Self.recallFacts(readiness: .preparing))
        #expect(try Self.display(unready) == .dropped(.notReady(.preparing)))
        let stale = try Self.recallEntry("b", phase: .fired(try Self.epoch(2)))
        let cell = try Self.onlyRecall(try Self.surface(try Self.layout(1), recalls: [stale]))
        #expect(cell.display == .dropped(.staleEpoch))
        #expect(cell.phase == stale.phase)
        #expect(cell.target == stale.target)
        #expect(cell.label == stale.label)
    }

    // MARK: Cap, determinism, ids

    @Test func oneHundredTwentyEightCellsAreAcceptedWithZeroSixtyFourAndOneHundredTwentyEightLayoutCells() throws {
        let limit = PerformPanelLimits.maximumEntries
        for layoutCells in [0, limit / 2, limit] {
            for total in [limit - 1, limit, limit + 1] where total >= layoutCells {
                let free = total - layoutCells
                let padCount = free / 2
                let pads = try Self.pads((0..<padCount).map { "n\($0)" })
                let recalls = try Self.recalls((0..<(free - padCount)).map { "r\($0)" })
                let found = try Self.refusal(layoutCells, xy: pads, recalls: recalls)
                if total <= limit {
                    #expect(found == nil)
                    let built = try Self.surface(try Self.layout(layoutCells), xy: pads, recalls: recalls)
                    #expect(built.cellCount == total)
                } else {
                    #expect(found == .tooManyCells(count: total))
                }
            }
        }
    }

    @Test func aRecallCellKeepsTheEntrysWholeTargetWithItsPatchAndItsVariation() throws {
        let entry = try Self.recallEntry("a", patch: "patch.p", variation: "var.1")
        let cell = try Self.onlyRecall(try Self.surface(try Self.layout(1), recalls: [entry]))
        #expect(cell.target.variation != nil)
        #expect(cell.target == entry.target)
    }

    @Test func makingTheSameSurfaceTwiceGivesEqualSurfacesAndEqualAnnouncements() throws {
        let entries = [try Self.waitingPad("a"), try Self.xyEntry("b")]
        let recalls = try Self.recalls(["r"])
        let first = try Self.surface(try Self.layout(2), xy: entries, recalls: recalls)
        let second = try Self.surface(try Self.layout(2), xy: entries, recalls: recalls)
        #expect(first == second)
        #expect(first.xyAnnouncements == second.xyAnnouncements)
    }

    @Test func aCellIDOfOneHundredTwentyEightBytesIsAcceptedAndKept() throws {
        let raw = String(repeating: "i", count: 128)
        let entry = try Self.altered(try Self.xyEntry("a"), id: raw)
        let cell = try Self.onlyPad(try Self.surface(try Self.layout(1), xy: [entry]))
        #expect(cell.id.rawValue.utf8.count == 128)
    }

    // MARK: Source scan

    private static let sourceNames = [
        "PerformPanelSurfaceEntry.swift", "PerformPanelSurfaceCells.swift", "PerformPanelSurfaceRefusal.swift",
        "PerformPanelSurface.swift", "PerformPanelSurface+Checks.swift", "PerformPanelSurface+Cells.swift"
    ]

    /// The six production files, read from the checkout or from the package mirror; empty when absent.
    static func surfaceSources() -> [String] {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let relative = "Shared/Views/Workspace/Perform/Panel/Surface/"
        let roots = [folder.deletingLastPathComponent(), folder.deletingLastPathComponent().deletingLastPathComponent()]
        var directories: [URL] = []
        for root in roots {
            directories.append(root.appendingPathComponent(relative))
            directories.append(root.appendingPathComponent("Sources/FluxKlang/" + relative))
        }
        for directory in directories {
            let texts = sourceNames.compactMap {
                try? String(contentsOf: directory.appendingPathComponent($0), encoding: .utf8)
            }
            if texts.count == sourceNames.count { return texts }
        }
        return []
    }

    @Test(.enabled(if: !PerformPanelSurfaceTests.surfaceSources().isEmpty))
    func theSurfaceSourcesNameNoFloatingPointDateQueueViewHandWrittenOperatorFiringOrPadMovingCallAndAllSixAreRead() {
        let texts = Self.surfaceSources()
        #expect(texts.count == 6)
        let banned = [
            "Dou" + "ble", "Flo" + "at", "Date(", "Clo" + "ck", "Ta" + "sk", "import SwiftUI", "DispatchQueue",
            "default" + ":", "try!", "mutat" + "ing", "static var", "static func ==", "static func <", ".firstIndex",
            ".first(where", ".filter(", ".sorted(", ".removeFirst", "] + ", "+ [", ".insert(at",
            "PerformRecall" + "Intent", "takingOver(", "hostMoved(", ".pointer(", ".entering(", ".adjusting("
        ]
        for text in texts {
            for token in banned { #expect(!text.contains(token)) }
        }
    }
}
