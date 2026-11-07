//
//  WorkspaceStatusTests+EngineClock.swift
//  FluxKlangTests
//
//  The Engine and Clock segments of the status strip (#99 W3): every lifecycle case and its words, the
//  degraded summary bound, a preparing engine over a degraded set, the clock's nominal and actual rates, and
//  the kilohertz and summary formatters.
//

import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension WorkspaceStatusTests {
    static func capabilities(_ count: Int) throws -> [CapabilityID] {
        try names("cap.", count).map { try CapabilityID($0) }
    }

    @Test func engineStoppedRunningAndRecoveringUseTheSpecWords() throws {
        let stopped = try Self.segment(.engine) { $0.lifecycle = .stopped }
        Self.expectSegment(stopped, text: "Engine stopped", label: "Engine: Engine stopped", severity: .normal)
        let running = try Self.segment(.engine) { $0.lifecycle = .running }
        Self.expectSegment(
            running, text: "Running (Host A)", label: "Engine: Running (Host A)", severity: .normal
        )
        let recovering = try Self.segment(.engine) { $0.lifecycle = .recovering }
        Self.expectSegment(
            recovering, text: "Recovering engine...", label: "Engine: Recovering engine...", severity: .error,
            lostItems: ["Engine"]
        )
    }

    @Test func preparingShowsTheRevisionAndStaysNormalOverAnAbsentOrRunningSet() throws {
        let revision = try ContractRevision(43)
        let bases: [RunningSetState] = [.absent, .running]
        for base in bases {
            let preparing = try Self.segment(.engine) { $0.lifecycle = .preparing(revision, over: base) }
            Self.expectSegment(
                preparing, text: "Preparing rev 43...", label: "Engine: Preparing rev 43...", severity: .normal
            )
        }
        let first = try Self.segment(.engine) { $0.lifecycle = .preparing(.initial, over: .absent) }
        #expect(first.text == "Preparing rev 0...")
        let last = try ContractRevision(ContractRevision.maximumValue)
        let newest = try Self.segment(.engine) { $0.lifecycle = .preparing(last, over: .running) }
        #expect(newest.text == "Preparing rev 9007199254740991...")
    }

    @Test func preparingOverADegradedEngineKeepsTheStripTextAndCarriesTheLostSet() throws {
        let revision = try ContractRevision(43)
        let lost = [CapabilityID(validated: "audio.out"), CapabilityID(validated: "midi.in")]
        let preparing = try Self.segment(.engine) { $0.lifecycle = .preparing(revision, over: .degraded(lost)) }
        Self.expectSegment(
            preparing, text: "Preparing rev 43...",
            label: "Engine: Preparing rev 43... Running: audio.out, midi.in Lost/Muted", severity: .error,
            lostItems: ["audio.out", "midi.in"]
        )
        #expect(preparing.glyphName == "exclamationmark.octagon")
        let degraded = try Self.segment(.engine) { $0.lifecycle = .degraded(lost) }
        #expect(preparing.severity == degraded.severity)
        #expect(preparing.lostItems == degraded.lostItems)
    }

    @Test func preparingOverADegradedEngineWithNoNamedCapabilitiesIsStillAnError() throws {
        let revision = try ContractRevision(43)
        let preparing = try Self.segment(.engine) { $0.lifecycle = .preparing(revision, over: .degraded([])) }
        Self.expectSegment(
            preparing, text: "Preparing rev 43...", label: "Engine: Preparing rev 43... Running: Lost/Muted",
            severity: .error
        )
    }

    @Test func preparingOverManyLostCapabilitiesListsFourThenAndNMore() throws {
        let revision = try ContractRevision(43)
        let lead = "Engine: Preparing rev 43... Running: "
        let fourLost = try Self.capabilities(4)
        let four = try Self.segment(.engine) { $0.lifecycle = .preparing(revision, over: .degraded(fourLost)) }
        #expect(four.text == "Preparing rev 43...")
        #expect(four.label == lead + "cap.1, cap.2, cap.3, cap.4 Lost/Muted")
        #expect(four.lostItems == ["cap.1", "cap.2", "cap.3", "cap.4"])
        let fiveLost = try Self.capabilities(5)
        let five = try Self.segment(.engine) { $0.lifecycle = .preparing(revision, over: .degraded(fiveLost)) }
        #expect(five.text == "Preparing rev 43...")
        #expect(five.label == lead + "cap.1, cap.2, cap.3, cap.4, and 1 more Lost/Muted")
        #expect(five.lostItems == ["cap.1", "cap.2", "cap.3", "cap.4", "cap.5"])
        let sevenLost = try Self.capabilities(7)
        let seven = try Self.segment(.engine) { $0.lifecycle = .preparing(revision, over: .degraded(sevenLost)) }
        #expect(seven.label == lead + "cap.1, cap.2, cap.3, cap.4, and 3 more Lost/Muted")
        #expect(seven.lostItems.count == 7)
    }

    @Test func heldByOtherNamesTheProjectAtAttention() throws {
        let held = try Self.segment(.engine) { $0.lifecycle = .heldByOther(ProjectID(validated: "prj.other")) }
        Self.expectSegment(
            held, text: "Engine in use by prj.other", label: "Engine: Engine in use by prj.other",
            severity: .attention
        )
    }

    @Test func degradedListsTheLostCapabilitiesAsAnError() throws {
        let lost = [CapabilityID(validated: "audio.out"), CapabilityID(validated: "midi.in")]
        let degraded = try Self.segment(.engine) { $0.lifecycle = .degraded(lost) }
        Self.expectSegment(
            degraded, text: "Running: audio.out, midi.in Lost/Muted",
            label: "Engine: Running: audio.out, midi.in Lost/Muted", severity: .error,
            lostItems: ["audio.out", "midi.in"]
        )
        #expect(degraded.glyphName == "exclamationmark.octagon")
    }

    @Test func degradedSummaryCapsAtFourCapabilitiesWithAnExactRemainder() throws {
        let fourLost = try Self.capabilities(4)
        let four = try Self.segment(.engine) { $0.lifecycle = .degraded(fourLost) }
        #expect(four.text == "Running: cap.1, cap.2, cap.3, cap.4 Lost/Muted")
        #expect(four.lostItems == ["cap.1", "cap.2", "cap.3", "cap.4"])
        let fiveLost = try Self.capabilities(5)
        let five = try Self.segment(.engine) { $0.lifecycle = .degraded(fiveLost) }
        #expect(five.text == "Running: cap.1, cap.2, cap.3, cap.4, and 1 more Lost/Muted")
        #expect(five.lostItems == ["cap.1", "cap.2", "cap.3", "cap.4", "cap.5"])
        let sevenLost = try Self.capabilities(7)
        let seven = try Self.segment(.engine) { $0.lifecycle = .degraded(sevenLost) }
        #expect(seven.text == "Running: cap.1, cap.2, cap.3, cap.4, and 3 more Lost/Muted")
        #expect(seven.label == "Engine: Running: cap.1, cap.2, cap.3, cap.4, and 3 more Lost/Muted")
        #expect(seven.lostItems.count == 7)
    }

    @Test func degradedWithoutCapabilitiesStillSaysLostMuted() throws {
        let degraded = try Self.segment(.engine) { $0.lifecycle = .degraded([]) }
        Self.expectSegment(
            degraded, text: "Running: Lost/Muted", label: "Engine: Running: Lost/Muted", severity: .error
        )
    }

    @Test func everyLifecycleCaseHasItsSeverityAndGlyph() throws {
        let revision = try ContractRevision(7)
        let cases: [EngineLifecycle] = [
            .stopped, .preparing(revision, over: .absent), .running,
            .degraded([CapabilityID(validated: "cap.a")]), .recovering,
            .heldByOther(ProjectID(validated: "prj.other"))
        ]
        let expected: [WorkspaceStatusSeverity] = [.normal, .normal, .normal, .error, .error, .attention]
        var segments: [WorkspaceStatusSegment] = []
        for lifecycle in cases {
            segments.append(try Self.segment(.engine) { $0.lifecycle = lifecycle })
        }
        #expect(segments.map(\.severity) == expected)
        #expect(segments.map(\.glyphName) == expected.map(\.glyphName))
        #expect(segments.map(\.lostItems) == [[], [], [], ["cap.a"], ["Engine"], []])
        #expect(segments.map(\.opensDetailList) == Array(repeating: true, count: 6))
    }

    @Test func runningTextShowsTheHostNameVerbatim() throws {
        let spaced = try Self.segment(.engine) { $0.hostName = "  Rig  \u{e9}  " }
        #expect(spaced.text == "Running (  Rig  \u{e9}  )")
        #expect(spaced.label == "Engine: Running (  Rig  \u{e9}  )")
        let stopped = try Self.segment(.engine) {
            $0.hostName = "Other"
            $0.lifecycle = .stopped
        }
        #expect(stopped.text == "Engine stopped")
    }

    static func clockSegment(nominal: Int, measured: Int?) throws -> WorkspaceStatusSegment {
        try segment(.clock) { $0.clock = WorkspaceStatusClock(nominalHertz: nominal, measuredHertz: measured) }
    }

    @Test func clockShowsNominalAndActualSeparately() throws {
        let close = try Self.clockSegment(nominal: 48_000, measured: 47_999)
        Self.expectSegment(
            close, text: "48 kHz nominal, actual 47.999 kHz", label: "Clock: 48 kHz nominal, actual 47.999 kHz",
            severity: .normal
        )
        let same = try Self.clockSegment(nominal: 44_100, measured: 44_100)
        #expect(same.text == "44.1 kHz nominal, actual 44.1 kHz")
        let apart = try Self.clockSegment(nominal: 96_000, measured: 48_000)
        #expect(apart.text == "96 kHz nominal, actual 48 kHz")
    }

    @Test func clockWithoutAMeasurementIsAttentionAndSaysUnavailable() throws {
        let unavailable = try Self.clockSegment(nominal: 48_000, measured: nil)
        Self.expectSegment(
            unavailable, text: "48 kHz nominal, actual Unavailable",
            label: "Clock: 48 kHz nominal, actual Unavailable", severity: .attention
        )
        #expect(unavailable.glyphName == "exclamationmark.triangle")
    }

    @Test func clockActualDifferingFromNominalIsNeverAnError() throws {
        let rows: [(measured: Int, text: String)] = [
            (1, "48 kHz nominal, actual 0.001 kHz"), (47_999, "48 kHz nominal, actual 47.999 kHz"),
            (48_001, "48 kHz nominal, actual 48.001 kHz"), (96_000, "48 kHz nominal, actual 96 kHz"),
            (768_000, "48 kHz nominal, actual 768 kHz")
        ]
        for row in rows {
            let clock = try Self.clockSegment(nominal: 48_000, measured: row.measured)
            #expect(clock.severity == .normal, "measured \(row.measured)")
            #expect(clock.lostItems.isEmpty, "measured \(row.measured)")
            #expect(clock.text == row.text, "measured \(row.measured)")
        }
    }

    @Test func kilohertzFormatsRatesWithUpToThreeDecimals() {
        let table: [(hertz: Int, text: String)] = [
            (48_000, "48 kHz"), (44_100, "44.1 kHz"), (47_999, "47.999 kHz"), (1, "0.001 kHz"),
            (10, "0.01 kHz"), (100, "0.1 kHz"), (999, "0.999 kHz"), (1_000, "1 kHz"), (1_001, "1.001 kHz"),
            (1_010, "1.01 kHz"), (1_100, "1.1 kHz"), (22_050, "22.05 kHz"), (96_000, "96 kHz"),
            (768_000, "768 kHz"), (767_999, "767.999 kHz")
        ]
        for row in table {
            #expect(WorkspaceStatusFormat.kilohertz(row.hertz) == row.text, "\(row.hertz) Hz")
        }
    }

    @Test func kilohertzIsTotalForZeroNegativeAndTheExtremes() {
        #expect(WorkspaceStatusFormat.kilohertz(0) == "0 kHz")
        #expect(WorkspaceStatusFormat.kilohertz(-1_500) == "-1.5 kHz")
        #expect(WorkspaceStatusFormat.kilohertz(-1) == "-0.001 kHz")
        #expect(WorkspaceStatusFormat.kilohertz(-48_000) == "-48 kHz")
        #expect(WorkspaceStatusFormat.kilohertz(Int.max) == "9223372036854775.807 kHz")
        #expect(WorkspaceStatusFormat.kilohertz(Int.min) == "-9223372036854775.808 kHz")
    }

    @Test func summaryJoinsThenCountsTheHiddenItemsExactly() {
        #expect(WorkspaceStatusFormat.summary([], limit: 4).isEmpty)
        #expect(WorkspaceStatusFormat.summary(["a"], limit: 4) == "a")
        #expect(WorkspaceStatusFormat.summary(["a", "b", "c", "d"], limit: 4) == "a, b, c, d")
        #expect(WorkspaceStatusFormat.summary(["a", "b", "c", "d", "e"], limit: 4) == "a, b, c, d, and 1 more")
        #expect(WorkspaceStatusFormat.summary(["a", "b", "c"], limit: 3) == "a, b, c")
        #expect(WorkspaceStatusFormat.summary(["a", "b", "c", "d"], limit: 3) == "a, b, c, and 1 more")
        #expect(WorkspaceStatusFormat.summary(Self.names("n", 100), limit: 3) == "n1, n2, n3, and 97 more")
    }

    @Test func staleCommandsAreSingularForOneAndPluralOtherwise() {
        #expect(WorkspaceStatusFormat.staleCommands(1) == "1 stale command discarded")
        #expect(WorkspaceStatusFormat.staleCommands(2) == "2 stale commands discarded")
        #expect(WorkspaceStatusFormat.staleCommands(0) == "0 stale commands discarded")
        #expect(WorkspaceStatusFormat.staleCommands(1_000_000) == "1000000 stale commands discarded")
    }
}
