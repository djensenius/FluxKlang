//
//  WorkspaceStatusTests+Announcer.swift
//  FluxKlangTests
//
//  The announcer policy of the status strip (#99 W3): a new error is announced once and at once, routine
//  changes are polite and throttled per segment, and the announcer is deterministic and refuses a
//  backwards tick without changing.
//

import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension WorkspaceStatusTests {
    /// The projection in which these devices are missing.
    static func missingDevices(_ names: [String]) throws -> WorkspaceStatusProjection {
        try projection { $0.devices = names.map { Self.device($0, .missing) } }
    }

    /// The projection in which this many drafts await review.
    static func drafts(_ count: Int) throws -> WorkspaceStatusProjection {
        try projection { $0.draftCount = count }
    }

    /// "high devices", "polite draft": the priority and the segment of each announcement, in order.
    static func kinds(_ announcements: [WorkspaceStatusAnnouncement]) -> [String] {
        announcements.map { ($0.priority == .high ? "high " : "polite ") + $0.segment.rawValue }
    }

    /// The outputs of one fixed three-call sequence, and the announcer it leaves behind.
    static func replay() throws -> (outputs: [[String]], announcer: WorkspaceStatusAnnouncer) {
        let quiet = try projection()
        let lost = try missingDevices(["A"])
        let draft = try drafts(2)
        var announcer = WorkspaceStatusAnnouncer()
        let first = try announcer.announcements(previous: quiet, current: lost, tick: 0)
        let second = try announcer.announcements(previous: lost, current: draft, tick: 1)
        let third = try announcer.announcements(previous: draft, current: quiet, tick: 9)
        return ([kinds(first), kinds(second), kinds(third)], announcer)
    }

    @Test func aNewErrorIsAnnouncedOnceAtHighPriorityAndNeverAgain() throws {
        let quiet = try Self.projection()
        let lost = try Self.missingDevices(["Interface B"])
        var announcer = WorkspaceStatusAnnouncer()
        let first = try announcer.announcements(previous: quiet, current: lost, tick: 10)
        #expect(Self.kinds(first) == ["high devices"])
        #expect(first.map(\.segment) == [.devices])
        #expect(first.map(\.text) == ["Devices: Interface B missing"])
        #expect(announcer.lastAnnouncedTick(for: .devices) == 10)
        #expect(announcer.lastTick == 10)
        let replay = try announcer.announcements(previous: lost, current: lost, tick: 11)
        #expect(replay.isEmpty)
        let later = try announcer.announcements(previous: lost, current: lost, tick: 500)
        #expect(later.isEmpty)
        #expect(announcer.lastAnnouncedTick(for: .devices) == 10)
        #expect(announcer.lastTick == 500)
    }

    @Test func unchangedProjectionsAnnounceNothingAndNeverSetAnAnnouncementTick() throws {
        let quiet = try Self.projection()
        var announcer = WorkspaceStatusAnnouncer()
        #expect(announcer.lastTick == nil)
        for tick in [UInt64(7), 8, 9, 100] {
            let result = try announcer.announcements(previous: quiet, current: quiet, tick: tick)
            #expect(result.isEmpty, "tick \(tick)")
            #expect(announcer.lastTick == tick)
        }
        for id in WorkspaceStatusSegmentID.allCases {
            #expect(announcer.lastAnnouncedTick(for: id) == nil, "segment \(id)")
        }
        #expect(WorkspaceStatusAnnouncer().lastAnnouncedTick(for: .devices) == nil)
    }

    @Test func aRoutineChangeIsHeldForFourTicksAndThenAnnounced() throws {
        let quiet = try Self.projection()
        let one = try Self.drafts(1)
        let two = try Self.drafts(2)
        let rows: [(tick: UInt64, kinds: [String])] = [
            (0, []), (1, []), (2, []), (3, []), (4, ["polite draft"]), (5, ["polite draft"]),
            (1_000, ["polite draft"])
        ]
        for row in rows {
            var announcer = WorkspaceStatusAnnouncer()
            let first = try announcer.announcements(previous: quiet, current: one, tick: 0)
            #expect(Self.kinds(first) == ["polite draft"])
            #expect(first.map(\.text) == ["Draft: 1 awaiting review"])
            let second = try announcer.announcements(previous: one, current: two, tick: row.tick)
            #expect(Self.kinds(second) == row.kinds, "second change at tick \(row.tick)")
            if !row.kinds.isEmpty {
                #expect(second.map(\.text) == ["Draft: 2 awaiting review"])
                #expect(announcer.lastAnnouncedTick(for: .draft) == row.tick)
            } else {
                #expect(announcer.lastAnnouncedTick(for: .draft) == 0)
            }
        }
    }

    @Test func aHeldChangeIsDeliveredLaterWithTheLatestState() throws {
        let quiet = try Self.projection()
        let one = try Self.drafts(1)
        let two = try Self.drafts(2)
        let three = try Self.drafts(3)
        var announcer = WorkspaceStatusAnnouncer()
        let first = try announcer.announcements(previous: quiet, current: one, tick: 0)
        #expect(first.map(\.text) == ["Draft: 1 awaiting review"])
        let heldTwo = try announcer.announcements(previous: one, current: two, tick: 1)
        #expect(heldTwo.isEmpty)
        let heldThree = try announcer.announcements(previous: two, current: three, tick: 2)
        #expect(heldThree.isEmpty)
        let delivered = try announcer.announcements(previous: three, current: three, tick: 4)
        #expect(Self.kinds(delivered) == ["polite draft"])
        #expect(delivered.map(\.text) == ["Draft: 3 awaiting review"])
        #expect(announcer.lastAnnouncedTick(for: .draft) == 4)
        let again = try announcer.announcements(previous: three, current: three, tick: 5)
        #expect(again.isEmpty)
    }

    @Test func aHeldChangeThatRevertsIsNeverAnnounced() throws {
        let quiet = try Self.projection()
        let one = try Self.drafts(1)
        let two = try Self.drafts(2)
        var announcer = WorkspaceStatusAnnouncer()
        let first = try announcer.announcements(previous: quiet, current: one, tick: 0)
        #expect(Self.kinds(first) == ["polite draft"])
        let held = try announcer.announcements(previous: one, current: two, tick: 1)
        #expect(held.isEmpty)
        let reverted = try announcer.announcements(previous: two, current: one, tick: 5)
        #expect(reverted.isEmpty)
        #expect(announcer.lastAnnouncedTick(for: .draft) == 0)
    }

    @Test func aNewErrorBypassesTheThrottle() throws {
        let quiet = try Self.projection()
        let stale = try Self.projection { $0.devices = [Self.device("Pad A", .stale)] }
        let missing = try Self.projection { $0.devices = [Self.device("Pad A", .missing)] }
        var announcer = WorkspaceStatusAnnouncer()
        let first = try announcer.announcements(previous: quiet, current: stale, tick: 0)
        #expect(Self.kinds(first) == ["polite devices"])
        #expect(first.map(\.text) == ["Devices: Pad A stale"])
        let escalated = try announcer.announcements(previous: stale, current: missing, tick: 1)
        #expect(Self.kinds(escalated) == ["high devices"])
        #expect(escalated.map(\.text) == ["Devices: Pad A missing"])
        #expect(announcer.lastAnnouncedTick(for: .devices) == 1)
    }

    @Test func anErrorThatClearsAndReturnsIsAnnouncedAgain() throws {
        let quiet = try Self.projection()
        let missing = try Self.missingDevices(["Pad A"])
        var spaced = WorkspaceStatusAnnouncer()
        let first = try spaced.announcements(previous: quiet, current: missing, tick: 0)
        #expect(Self.kinds(first) == ["high devices"])
        let cleared = try spaced.announcements(previous: missing, current: quiet, tick: 4)
        #expect(Self.kinds(cleared) == ["polite devices"])
        #expect(cleared.map(\.text) == ["Devices: No devices"])
        let returned = try spaced.announcements(previous: quiet, current: missing, tick: 5)
        #expect(Self.kinds(returned) == ["high devices"])
        var held = WorkspaceStatusAnnouncer()
        _ = try held.announcements(previous: quiet, current: missing, tick: 0)
        let heldClear = try held.announcements(previous: missing, current: quiet, tick: 1)
        #expect(heldClear.isEmpty)
        let heldReturn = try held.announcements(previous: quiet, current: missing, tick: 2)
        #expect(Self.kinds(heldReturn) == ["high devices"])
        #expect(held.lastAnnouncedTick(for: .devices) == 2)
    }

    @Test func aSecondLostItemIsANewErrorAndALostItemLeavingIsRoutine() throws {
        let quiet = try Self.projection()
        let oneLost = try Self.missingDevices(["A"])
        let twoLost = try Self.missingDevices(["A", "B"])
        var announcer = WorkspaceStatusAnnouncer()
        let first = try announcer.announcements(previous: quiet, current: oneLost, tick: 0)
        #expect(first.map(\.text) == ["Devices: A missing"])
        let second = try announcer.announcements(previous: oneLost, current: twoLost, tick: 1)
        #expect(Self.kinds(second) == ["high devices"])
        #expect(second.map(\.text) == ["Devices: A missing, B missing"])
        let leaving = try announcer.announcements(previous: twoLost, current: oneLost, tick: 2)
        #expect(leaving.isEmpty)
        let delivered = try announcer.announcements(previous: oneLost, current: oneLost, tick: 5)
        #expect(Self.kinds(delivered) == ["polite devices"])
        #expect(delivered.map(\.text) == ["Devices: A missing"])
        let swapped = try Self.missingDevices(["B"])
        let swap = try announcer.announcements(previous: oneLost, current: swapped, tick: 6)
        #expect(Self.kinds(swap) == ["high devices"])
        #expect(swap.map(\.text) == ["Devices: B missing"])
    }

    @Test func aDegradedEngineWithNoNamedCapabilitiesIsStillANewError() throws {
        let quiet = try Self.projection()
        let held = try Self.projection { $0.lifecycle = .heldByOther(ProjectID(validated: "prj.other")) }
        let degraded = try Self.projection { $0.lifecycle = .degraded([]) }
        for before in [quiet, held] {
            var announcer = WorkspaceStatusAnnouncer()
            let result = try announcer.announcements(previous: before, current: degraded, tick: 0)
            #expect(Self.kinds(result) == ["high engine"])
            #expect(result.map(\.text) == ["Engine: Running: Lost/Muted"])
        }
    }

    @Test func aHighAnnouncementStartsTheThrottleWindowOfItsSegment() throws {
        let quiet = try Self.projection()
        let missing = try Self.missingDevices(["A"])
        let worse = try Self.projection { $0.devices = [Self.device("A", .missing), Self.device("B", .stale)] }
        var announcer = WorkspaceStatusAnnouncer()
        let first = try announcer.announcements(previous: quiet, current: missing, tick: 0)
        #expect(Self.kinds(first) == ["high devices"])
        let held = try announcer.announcements(previous: missing, current: worse, tick: 2)
        #expect(held.isEmpty)
        let due = try announcer.announcements(previous: worse, current: worse, tick: 4)
        #expect(Self.kinds(due) == ["polite devices"])
        #expect(due.map(\.text) == ["Devices: A missing, B stale"])
    }

    @Test func highAnnouncementsComeBeforePoliteOnesEachInSegmentOrder() throws {
        let quiet = try Self.projection()
        let current = try Self.projection {
            $0.lifecycle = .recovering
            $0.devices = [Self.device("Pad A", .missing)]
            $0.clock = WorkspaceStatusClock(nominalHertz: 48_000, measuredHertz: nil)
            $0.draftCount = 2
            $0.shell = WorkspaceStatusShell(safetyControlsReachable: false)
        }
        var announcer = WorkspaceStatusAnnouncer()
        let result = try announcer.announcements(previous: quiet, current: current, tick: 3)
        #expect(Self.kinds(result) == ["high engine", "high devices", "high safety", "polite clock", "polite draft"])
        #expect(result.map(\.text) == [
            "Engine: Recovering engine...", "Devices: Pad A missing",
            "Safety: Safe Mute and PANIC are unreachable",
            "Clock: 48 kHz nominal, actual Unavailable", "Draft: 2 awaiting review"
        ])
        #expect(result.map(\.segment) == [.engine, .devices, .safety, .clock, .draft])
    }

    @Test func everySegmentAnnouncesItsOwnChangeWithTheRightPriority() throws {
        let quiet = try Self.projection()
        let session = try Self.session(epoch: 2)
        let stopped = try Self.projection { $0.lifecycle = .stopped }
        let stale = try Self.projection { $0.devices = [Self.device("Pad A", .stale)] }
        let unavailable = try Self.projection {
            $0.clock = WorkspaceStatusClock(nominalHertz: 48_000, measuredHertz: nil)
        }
        let connected = try Self.projection { $0.peers = [Self.peer("Remote C", .connected(session))] }
        let oneDraft = try Self.drafts(1)
        let unreachable = try Self.projection {
            $0.shell = WorkspaceStatusShell(safetyControlsReachable: false)
        }
        let changes: [(id: WorkspaceStatusSegmentID, current: WorkspaceStatusProjection)] = [
            (.engine, stopped), (.devices, stale), (.clock, unavailable), (.peers, connected),
            (.draft, oneDraft), (.safety, unreachable)
        ]
        #expect(changes.map(\.id) == WorkspaceStatusSegmentID.allCases)
        for change in changes {
            var announcer = WorkspaceStatusAnnouncer()
            let result = try announcer.announcements(previous: quiet, current: change.current, tick: 0)
            let expected = change.id == .safety ? "high safety" : "polite \(change.id.rawValue)"
            #expect(Self.kinds(result) == [expected], "segment \(change.id)")
            #expect(result.map(\.text) == [change.current.segment(change.id).label], "segment \(change.id)")
        }
    }

    @Test func recoveringEngineAndUnreachableSafetyAreHighAndTheirRecoveryIsPolite() throws {
        let quiet = try Self.projection()
        let recovering = try Self.projection { $0.lifecycle = .recovering }
        var announcer = WorkspaceStatusAnnouncer()
        let down = try announcer.announcements(previous: quiet, current: recovering, tick: 0)
        #expect(Self.kinds(down) == ["high engine"])
        #expect(down.map(\.text) == ["Engine: Recovering engine..."])
        let recovered = try announcer.announcements(previous: recovering, current: quiet, tick: 4)
        #expect(Self.kinds(recovered) == ["polite engine"])
        #expect(recovered.map(\.text) == ["Engine: Running (Host A)"])
        let unreachable = try Self.projection { $0.shell = WorkspaceStatusShell(safetyControlsReachable: false) }
        let cut = try announcer.announcements(previous: quiet, current: unreachable, tick: 5)
        #expect(Self.kinds(cut) == ["high safety"])
        #expect(cut.map(\.text) == ["Safety: Safe Mute and PANIC are unreachable"])
    }

    @Test func aDisconnectedPeerIsAHighAnnouncement() throws {
        let session = try Self.session(epoch: 4)
        let connected = try Self.projection {
            $0.peers = [Self.peer("Remote C", .synced(session, awaitingResume: false))]
        }
        let gone = try Self.projection { $0.peers = [Self.peer("Remote C", .disconnected(session))] }
        var announcer = WorkspaceStatusAnnouncer()
        let result = try announcer.announcements(previous: connected, current: gone, tick: 0)
        #expect(Self.kinds(result) == ["high peers"])
        #expect(result.map(\.text) == ["Peers: Remote C disconnected"])
    }

    @Test func aBackwardsTickIsRefusedAndTheAnnouncerIsUnchanged() throws {
        let quiet = try Self.projection()
        let one = try Self.drafts(1)
        let two = try Self.drafts(2)
        var announcer = WorkspaceStatusAnnouncer()
        _ = try announcer.announcements(previous: quiet, current: one, tick: 5)
        let before = announcer
        var refused = announcer
        #expect(throws: WorkspaceStatusRefusal.tickWentBackwards(last: 5, found: 4)) {
            try refused.announcements(previous: one, current: two, tick: 4)
        }
        #expect(refused == before)
        #expect(refused.lastTick == 5)
        #expect(refused.lastAnnouncedTick(for: .draft) == 5)
        #expect(throws: WorkspaceStatusRefusal.tickWentBackwards(last: 5, found: 0)) {
            try refused.announcements(previous: one, current: two, tick: 0)
        }
        #expect(refused == before)
        let sameTick = try announcer.announcements(previous: one, current: two, tick: 5)
        #expect(sameTick.isEmpty)
        #expect(announcer.lastTick == 5)
    }

    @Test func theLargestTickIsAcceptedAndOneBelowItIsThenRefused() throws {
        let quiet = try Self.projection()
        let one = try Self.drafts(1)
        let two = try Self.drafts(2)
        var announcer = WorkspaceStatusAnnouncer()
        let first = try announcer.announcements(previous: quiet, current: one, tick: 0)
        #expect(Self.kinds(first) == ["polite draft"])
        let last = try announcer.announcements(previous: one, current: two, tick: UInt64.max)
        #expect(Self.kinds(last) == ["polite draft"])
        #expect(announcer.lastTick == UInt64.max)
        let before = announcer
        #expect(throws: WorkspaceStatusRefusal.tickWentBackwards(last: UInt64.max, found: UInt64.max - 1)) {
            try announcer.announcements(previous: two, current: one, tick: UInt64.max - 1)
        }
        #expect(announcer == before)
    }

    @Test func aSegmentSeenForTheFirstTimeStartsFromPrevious() throws {
        let quiet = try Self.projection()
        let lost = try Self.missingDevices(["Interface B"])
        var alreadyLost = WorkspaceStatusAnnouncer()
        let same = try alreadyLost.announcements(previous: lost, current: lost, tick: 0)
        #expect(same.isEmpty)
        var recovered = WorkspaceStatusAnnouncer()
        let cleared = try recovered.announcements(previous: lost, current: quiet, tick: 0)
        #expect(Self.kinds(cleared) == ["polite devices"])
        #expect(cleared.map(\.text) == ["Devices: No devices"])
        var fresh = WorkspaceStatusAnnouncer()
        let appeared = try fresh.announcements(previous: quiet, current: lost, tick: 0)
        #expect(Self.kinds(appeared) == ["high devices"])
    }

    @Test func afterTheFirstCallTheAnnouncersMemoryWinsOverPrevious() throws {
        let quiet = try Self.projection()
        let lost = try Self.missingDevices(["Interface B"])
        var announcer = WorkspaceStatusAnnouncer()
        let first = try announcer.announcements(previous: quiet, current: lost, tick: 0)
        #expect(Self.kinds(first) == ["high devices"])
        let staleHint = try announcer.announcements(previous: quiet, current: lost, tick: 1)
        #expect(staleHint.isEmpty)
        let later = try announcer.announcements(previous: quiet, current: lost, tick: 100)
        #expect(later.isEmpty)
    }

    @Test func theThrottleIsPerSegment() throws {
        let quiet = try Self.projection()
        let draft = try Self.drafts(1)
        let both = try Self.projection {
            $0.draftCount = 1
            $0.clock = WorkspaceStatusClock(nominalHertz: 48_000, measuredHertz: nil)
        }
        var announcer = WorkspaceStatusAnnouncer()
        let first = try announcer.announcements(previous: quiet, current: draft, tick: 0)
        #expect(Self.kinds(first) == ["polite draft"])
        let second = try announcer.announcements(previous: draft, current: both, tick: 1)
        #expect(Self.kinds(second) == ["polite clock"])
        #expect(announcer.lastAnnouncedTick(for: .draft) == 0)
        #expect(announcer.lastAnnouncedTick(for: .clock) == 1)
        #expect(announcer.lastAnnouncedTick(for: .engine) == nil)
    }

    @Test func identicalCallSequencesGiveEqualAnnouncersAndOutputs() throws {
        let first = try Self.replay()
        let second = try Self.replay()
        #expect(first.outputs == [["high devices"], ["polite draft"], ["polite devices", "polite draft"]])
        #expect(first.outputs == second.outputs)
        #expect(first.announcer == second.announcer)
        #expect(first.announcer.hashValue == second.announcer.hashValue)
        #expect(first.announcer != WorkspaceStatusAnnouncer())
        #expect(first.announcer.lastTick == 9)
        #expect(first.announcer.lastAnnouncedTick(for: .devices) == 9)
        #expect(first.announcer.lastAnnouncedTick(for: .draft) == 9)
        #expect(WorkspaceStatusAnnouncer() == WorkspaceStatusAnnouncer())
    }
}
