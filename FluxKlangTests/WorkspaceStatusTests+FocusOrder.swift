//
//  WorkspaceStatusTests+FocusOrder.swift
//  FluxKlangTests
//
//  The keyboard focus order of the status strip (#99 W3): five detail segments, then Safe Mute, then PANIC
//  as the last two stops, the same in wide, compact and unreachable layouts.
//

import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension WorkspaceStatusTests {
    /// The seven stops in focus order.
    static let focusTargets: [WorkspaceStatusFocusTarget] = [
        .segment(.engine), .segment(.devices), .segment(.clock), .segment(.peers), .segment(.draft),
        .safeMute, .panic
    ]

    /// The focus stops of a quiet strip whose shell is `shell`.
    static func quietStops(shell: WorkspaceStatusShell) throws -> [WorkspaceStatusFocusStop] {
        let strip = try Self.projection { $0.shell = shell }
        return WorkspaceStatusFocusOrder.stops(for: strip)
    }

    @Test func wideLayoutHasSevenStopsInTheFixedOrder() throws {
        let presentation = try Self.presentation(compact: false)
        let stops = try Self.quietStops(shell: WorkspaceStatusShell(presentation: presentation))
        #expect(stops.map(\.target) == Self.focusTargets)
        #expect(stops.map(\.label) == [
            "Engine: Running (Host A)", "Devices: No devices", "Clock: 48 kHz nominal, actual 48 kHz",
            "Peers: No peers", "Draft: None awaiting review", "Safe Mute", "PANIC"
        ])
        #expect(stops.map(\.isUnreachable) == Array(repeating: false, count: 7))
    }

    @Test func compactLayoutKeepsTheSameStopsInTheSameOrder() throws {
        let widePresentation = try Self.presentation(compact: false)
        let compactPresentation = try Self.presentation(compact: true)
        #expect(compactPresentation.layout != widePresentation.layout)
        let wide = try Self.quietStops(shell: WorkspaceStatusShell(presentation: widePresentation))
        let compact = try Self.quietStops(shell: WorkspaceStatusShell(presentation: compactPresentation))
        #expect(compact.map(\.target) == Self.focusTargets)
        #expect(compact.map(\.label) == [
            "Engine: Running (Host A)", "Devices: No devices", "Clock: 48 kHz nominal, actual 48 kHz",
            "Peers: No peers", "Draft: None awaiting review", "Safe Mute", "PANIC"
        ])
        #expect(compact.map(\.isUnreachable) == Array(repeating: false, count: 7))
        #expect(compact == wide)
    }

    @Test func unreachableSafetyControlsStayAsFlaggedLastTwoStops() throws {
        let reachable = try Self.quietStops(shell: WorkspaceStatusShell(safetyControlsReachable: true))
        let unreachable = try Self.quietStops(shell: WorkspaceStatusShell(safetyControlsReachable: false))
        #expect(unreachable.map(\.target) == Self.focusTargets)
        #expect(unreachable.count == 7)
        #expect(unreachable.suffix(2).map(\.label) == ["Safe Mute (unreachable)", "PANIC (unreachable)"])
        #expect(unreachable.map(\.isUnreachable) == [false, false, false, false, false, true, true])
        #expect(Array(unreachable.prefix(5)) == Array(reachable.prefix(5)))
    }

    @Test func safeMuteAndPanicAreAlwaysTheLastTwoStopsWhateverTheStripSays() throws {
        let session = try Self.session(epoch: 3)
        let busy = try Self.projection {
            $0.lifecycle = .recovering
            $0.devices = [Self.device("Pad A", .missing)]
            $0.clock = WorkspaceStatusClock(nominalHertz: 48_000, measuredHertz: nil)
            $0.peers = [Self.peer("Remote C", .disconnected(session), stale: 2)]
            $0.draftCount = 9
            $0.shell = WorkspaceStatusShell(safetyControlsReachable: false)
        }
        let quiet = try Self.projection()
        for projection in [quiet, busy] {
            let stops = WorkspaceStatusFocusOrder.stops(for: projection)
            #expect(stops.count == 7)
            #expect(stops.suffix(2).map(\.target) == [.safeMute, .panic])
            #expect(stops.prefix(5).allSatisfy { !$0.isUnreachable })
        }
    }

    @Test func noStopOpensSafetyAndEveryDetailSegmentHasExactlyOne() throws {
        let projection = try Self.projection()
        let stops = WorkspaceStatusFocusOrder.stops(for: projection)
        let targets = stops.map(\.target)
        #expect(!targets.contains(.segment(.safety)))
        let detail = projection.segments.filter(\.opensDetailList).map { WorkspaceStatusFocusTarget.segment($0.id) }
        #expect(Array(targets.prefix(5)) == detail)
        #expect(Set(targets).count == 7)
    }

    @Test func stopLabelsFollowTheProjectionSegmentLabels() throws {
        let busy = try Self.projection {
            $0.devices = [Self.device("Interface B", .missing), Self.device("Controller A", .stale)]
            $0.clock = WorkspaceStatusClock(nominalHertz: 48_000, measuredHertz: nil)
            $0.draftCount = 1
        }
        let stops = WorkspaceStatusFocusOrder.stops(for: busy)
        #expect(stops.prefix(5).map(\.label) == busy.segments.prefix(5).map(\.label))
        #expect(stops[1].label == "Devices: Interface B missing, Controller A stale")
        #expect(stops[2].label == "Clock: 48 kHz nominal, actual Unavailable")
        #expect(stops[4].label == "Draft: 1 awaiting review")
        let quietStrip = try Self.projection()
        let quiet = WorkspaceStatusFocusOrder.stops(for: quietStrip)
        #expect(quiet.map(\.label) != stops.map(\.label))
    }

    @Test func focusOrderIsDeterministicAndHasNoLayoutInput() throws {
        let projection = try Self.projection { $0.draftCount = 4 }
        let first = WorkspaceStatusFocusOrder.stops(for: projection)
        let second = WorkspaceStatusFocusOrder.stops(for: projection)
        #expect(first == second)
        #expect(first.hashValue == second.hashValue)
        let same = try Self.projection { $0.draftCount = 4 }
        #expect(WorkspaceStatusFocusOrder.stops(for: same) == first)
        let other = try Self.projection { $0.draftCount = 5 }
        #expect(WorkspaceStatusFocusOrder.stops(for: other) != first)
        #expect(WorkspaceStatusFocusOrder.stops(for: other).map(\.target) == first.map(\.target))
    }
}
