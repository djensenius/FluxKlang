//
//  WorkspaceStatusTests+ShowReadiness.swift
//  FluxKlangTests
//
//  The show readiness line of the status projection (#99, slice SRS1): an optional field built from three
//  counts, worded in fixed pieces, validated last, and never a segment, a focus stop or an announcement.
//

import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension WorkspaceStatusTests {
    static let readinessMaximum = WorkspaceStatusInputs.maximumCount

    static func readiness(_ entries: Int, _ blocked: Int, _ setBlockers: Int) -> WorkspaceStatusShowReadiness {
        WorkspaceStatusShowReadiness(entryCount: entries, blockedEntryCount: blocked, setBlockerCount: setBlockers)
    }

    /// The inputs of a quiet scenario after `edit`, carrying `counts`.
    static func readinessInputs(
        _ counts: WorkspaceStatusShowReadiness?, edit: (inout Scenario) -> Void = { _ in }
    ) -> WorkspaceStatusInputs {
        var scenario = Scenario()
        edit(&scenario)
        var inputs = scenario.inputs
        inputs.showReadiness = counts
        return inputs
    }

    static func readinessLine(
        _ entries: Int, _ blocked: Int, _ setBlockers: Int
    ) throws -> WorkspaceStatusShowReadinessLine {
        let projection = try WorkspaceStatusProjection.make(readinessInputs(readiness(entries, blocked, setBlockers)))
        return try #require(projection.showReadiness)
    }

    static func expectReadinessRefusal(
        _ expected: WorkspaceStatusRefusal, _ inputs: WorkspaceStatusInputs,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(throws: expected, sourceLocation: sourceLocation) { try WorkspaceStatusProjection.make(inputs) }
    }

    static func expectReadinessText(
        _ entries: Int, _ blocked: Int, _ setBlockers: Int, _ text: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let line = try readinessLine(entries, blocked, setBlockers)
        #expect(line.text == text, sourceLocation: sourceLocation)
    }

    @Test func absentReadinessLeavesProjectionNil() throws {
        let quiet = try Self.projection()
        let missing: WorkspaceStatusShowReadiness? = nil
        let explicit = try WorkspaceStatusProjection.make(Self.readinessInputs(missing))
        #expect(quiet.showReadiness == nil)
        #expect(explicit.showReadiness == nil)
        #expect(Scenario().inputs.showReadiness == nil)
        let present = try WorkspaceStatusProjection.make(Self.readinessInputs(Self.readiness(0, 0, 0)))
        #expect(present.showReadiness != nil)
    }

    @Test func readinessLeavesSixSegmentsAndSevenFocusStopsWhetherPresentOrAbsent() throws {
        let absent = try Self.projection()
        let blocked = try WorkspaceStatusProjection.make(Self.readinessInputs(Self.readiness(5, 2, 1)))
        let ready = try WorkspaceStatusProjection.make(Self.readinessInputs(Self.readiness(5, 0, 0)))
        #expect(absent.segments.count == 6)
        #expect(blocked.segments == absent.segments)
        #expect(ready.segments == absent.segments)
        #expect(blocked.diagnostics == absent.diagnostics)
        #expect(WorkspaceStatusSegmentID.allCases.count == 6)
        for strip in [absent, blocked, ready] {
            let stops = WorkspaceStatusFocusOrder.stops(for: strip)
            #expect(stops.map(\.target) == Self.focusTargets)
        }
    }

    @Test func readinessDoesNotChangeAnnouncements() throws {
        let absent = try Self.projection()
        let blocked = try WorkspaceStatusProjection.make(Self.readinessInputs(Self.readiness(5, 5, 2)))
        var announcer = WorkspaceStatusAnnouncer()
        let appears = try announcer.announcements(previous: absent, current: blocked, tick: 10)
        #expect(appears.isEmpty)
        let ready = try WorkspaceStatusProjection.make(Self.readinessInputs(Self.readiness(5, 0, 0)))
        let changes = try announcer.announcements(previous: blocked, current: ready, tick: 20)
        #expect(changes.isEmpty)
        #expect(announcer.lastAnnouncedTick(for: .safety) == nil)
        #expect(announcer.lastAnnouncedTick(for: .draft) == nil)
    }

    @Test func readyCountsSayShowReadyWithEntryCount() throws {
        try Self.expectReadinessText(5, 0, 0, "Show ready (5 entries)")
        try Self.expectReadinessText(1, 0, 0, "Show ready (1 entry)")
        try Self.expectReadinessText(2, 0, 0, "Show ready (2 entries)")
        let line = try Self.readinessLine(5, 0, 0)
        #expect(line.severity == .normal)
        #expect(line.glyphName == "checkmark.circle")
    }

    @Test func blockedEntriesAndSetBlockersSayExactWords() throws {
        try Self.expectReadinessText(0, 0, 0, "Show not ready: no entries")
        try Self.expectReadinessText(0, 0, 1, "Show not ready: no entries, 1 setlist blocker")
        try Self.expectReadinessText(5, 2, 0, "Show not ready: 2 of 5 entries blocked")
        try Self.expectReadinessText(1, 1, 0, "Show not ready: 1 of 1 entry blocked")
        try Self.expectReadinessText(5, 2, 2, "Show not ready: 2 of 5 entries blocked, 2 setlist blockers")
        try Self.expectReadinessText(5, 5, 1, "Show not ready: 5 of 5 entries blocked, 1 setlist blocker")
        try Self.expectReadinessText(5, 0, 3, "Show not ready: 3 setlist blockers")
        try Self.expectReadinessText(5, 1, 0, "Show not ready: 1 of 5 entries blocked")
        try Self.expectReadinessText(0, 0, 2, "Show not ready: no entries, 2 setlist blockers")
    }

    @Test func emptySetlistReadsNoEntries() throws {
        let line = try Self.readinessLine(0, 0, 0)
        #expect(line.text == "Show not ready: no entries")
        #expect(line.severity == .attention)
        let withLinks = try Self.readinessLine(0, 0, 4)
        #expect(withLinks.text == "Show not ready: no entries, 4 setlist blockers")
    }

    @Test func readinessSeverityFollowsReadyAndBlockedCounts() throws {
        let ready = try Self.readinessLine(3, 0, 0)
        let blocked = try Self.readinessLine(3, 1, 0)
        let setBlocked = try Self.readinessLine(3, 0, 1)
        let empty = try Self.readinessLine(0, 0, 0)
        let largest = try Self.readinessLine(Self.readinessMaximum, Self.readinessMaximum, Self.readinessMaximum)
        #expect(ready.severity == .normal)
        #expect(blocked.severity == .attention)
        #expect(setBlocked.severity == .attention)
        #expect(empty.severity == .attention)
        #expect(largest.severity == .attention)
        #expect(blocked.glyphName == "exclamationmark.triangle")
    }

    @Test func readinessLabelIsTitledSentence() throws {
        let ready = try Self.readinessLine(5, 0, 0)
        #expect(ready.label == "Show readiness: Show ready (5 entries)")
        let blocked = try Self.readinessLine(5, 2, 0)
        #expect(blocked.label == "Show readiness: Show not ready: 2 of 5 entries blocked")
    }

    @Test func countsAccept0And1000000AndRefuseMinusOneAndBeyond() throws {
        let top = Self.readinessMaximum
        try Self.expectReadinessText(top, 0, 0, "Show ready (1000000 entries)")
        try Self.expectReadinessText(top, top, 0, "Show not ready: 1000000 of 1000000 entries blocked")
        try Self.expectReadinessText(5, 0, top, "Show not ready: 1000000 setlist blockers")
        try Self.expectReadinessText(1, 0, 0, "Show ready (1 entry)")
        for value in [-1, top + 1, Int.min, Int.max] {
            let entries = Self.readinessInputs(Self.readiness(value, 0, 0))
            Self.expectReadinessRefusal(.countOutOfRange(.showReadinessEntries, value: value), entries)
            let blocked = Self.readinessInputs(Self.readiness(5, value, 0))
            Self.expectReadinessRefusal(.countOutOfRange(.showReadinessBlockedEntries, value: value), blocked)
            let setBlockers = Self.readinessInputs(Self.readiness(5, 0, value))
            Self.expectReadinessRefusal(.countOutOfRange(.showReadinessSetBlockers, value: value), setBlockers)
        }
    }

    @Test func blockedBeyondEntriesIsRefused() throws {
        let over = Self.readinessInputs(Self.readiness(5, 6, 0))
        Self.expectReadinessRefusal(.blockedEntriesExceedEntries(blocked: 6, entries: 5), over)
        let none = Self.readinessInputs(Self.readiness(0, 1, 0))
        Self.expectReadinessRefusal(.blockedEntriesExceedEntries(blocked: 1, entries: 0), none)
        let far = Self.readinessInputs(Self.readiness(3, Self.readinessMaximum, 0))
        Self.expectReadinessRefusal(.blockedEntriesExceedEntries(blocked: Self.readinessMaximum, entries: 3), far)
        try Self.expectReadinessText(5, 5, 0, "Show not ready: 5 of 5 entries blocked")
        try Self.expectReadinessText(0, 0, 0, "Show not ready: no entries")
    }

    @Test func readinessRefusalsFollowTheDocumentedOrder() throws {
        let top = Self.readinessMaximum
        let entriesAndBlocked = Self.readinessInputs(Self.readiness(-1, -2, 0))
        Self.expectReadinessRefusal(.countOutOfRange(.showReadinessEntries, value: -1), entriesAndBlocked)
        let blockedAndSet = Self.readinessInputs(Self.readiness(5, -2, -3))
        Self.expectReadinessRefusal(.countOutOfRange(.showReadinessBlockedEntries, value: -2), blockedAndSet)
        let setAndExceed = Self.readinessInputs(Self.readiness(5, 6, -1))
        Self.expectReadinessRefusal(.countOutOfRange(.showReadinessSetBlockers, value: -1), setAndExceed)
        let entriesAndSet = Self.readinessInputs(Self.readiness(top + 1, 0, -4))
        Self.expectReadinessRefusal(.countOutOfRange(.showReadinessEntries, value: top + 1), entriesAndSet)
        let blockedAndExceed = Self.readinessInputs(Self.readiness(5, top + 1, 0))
        Self.expectReadinessRefusal(.countOutOfRange(.showReadinessBlockedEntries, value: top + 1), blockedAndExceed)
        let setAndExceedHigh = Self.readinessInputs(Self.readiness(5, 6, top + 1))
        Self.expectReadinessRefusal(.countOutOfRange(.showReadinessSetBlockers, value: top + 1), setAndExceedHigh)
    }

    @Test func existingRefusalComesBeforeReadinessRefusal() throws {
        let badReadiness = Self.readiness(-1, -2, -3)
        let draft = Self.readinessInputs(badReadiness) { $0.draftCount = -7 }
        Self.expectReadinessRefusal(.countOutOfRange(.draftCount, value: -7), draft)
        let diagnostics = Self.readinessInputs(badReadiness) {
            $0.diagnostics = WorkspaceStatusDiagnosticCounts(errors: 0, warnings: 0, infos: -9)
        }
        Self.expectReadinessRefusal(.countOutOfRange(.diagnosticCount(.info), value: -9), diagnostics)
        let host = Self.readinessInputs(badReadiness) { $0.hostName = "" }
        Self.expectReadinessRefusal(.emptyName(.hostName), host)
        let onlyReadiness = Self.readinessInputs(badReadiness)
        Self.expectReadinessRefusal(.countOutOfRange(.showReadinessEntries, value: -1), onlyReadiness)
    }

    @Test func verdictAdapterCountsBlockedEntriesAndSetBlockers() throws {
        typealias Fix = ShowReadinessTests.Fixture
        let mixed = try Fix.library(
            songs: [Fix.song(Fix.songA, chart: Fix.goneAsset), Fix.song(Fix.songB)],
            entries: [Fix.entry(Fix.entryOne, Fix.songA), Fix.entry(Fix.entryTwo, Fix.songB)]
        )
        let mixedVerdict = try ShowReadinessEvaluator.evaluate(Fix.facts(mixed))
        #expect(mixedVerdict.entries.map(\.isReady) == [false, true])
        #expect(mixedVerdict.setBlockers.isEmpty)
        let mixedCounts = WorkspaceStatusShowReadiness(verdict: mixedVerdict)
        #expect(mixedCounts == Self.readiness(2, 1, 0))

        let emptyLibrary = try Fix.library(songs: [], entries: [])
        let emptyVerdict = try ShowReadinessEvaluator.evaluate(Fix.facts(emptyLibrary))
        #expect(WorkspaceStatusShowReadiness(verdict: emptyVerdict) == Self.readiness(0, 0, 1))

        let broken = try Fix.song(Fix.songOutside, parts: [
            Fix.part(Fix.partOne, patch: Fix.unknownPatch), Fix.part(Fix.partTwo, patch: Fix.unknownPatch)
        ])
        let linked = try Fix.library(
            songs: [broken, Fix.song(Fix.songA)], entries: [Fix.entry(Fix.entryOne, Fix.songA)]
        )
        let linkedVerdict = try ShowReadinessEvaluator.evaluate(Fix.facts(linked))
        #expect(linkedVerdict.setBlockers == [.unresolvedLinks(count: 2)])
        #expect(WorkspaceStatusShowReadiness(verdict: linkedVerdict) == Self.readiness(1, 0, 1))

        let both = try Fix.library(songs: [broken], entries: [])
        let bothVerdict = try ShowReadinessEvaluator.evaluate(Fix.facts(both))
        #expect(bothVerdict.setBlockers == [.emptySetlist, .unresolvedLinks(count: 2)])
        #expect(WorkspaceStatusShowReadiness(verdict: bothVerdict) == Self.readiness(0, 0, 2))
    }
}
