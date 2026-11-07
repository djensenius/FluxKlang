//
//  WorkspaceStatusTests+Pending.swift
//  FluxKlangTests
//
//  The announcer's held changes and hidden-item sentences (#99 W3): which segments wait for their due tick,
//  the saturating due tick, a change of severity alone that says nothing new, and the new words that make a
//  hidden new error audible at high priority.
//

import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension WorkspaceStatusTests {
    @Test func pendingSegmentsAreEmptyBeforeAnyChangeAndAfterTheHeldChangeIsSpoken() throws {
        let quiet = try Self.projection()
        let one = try Self.drafts(1)
        let two = try Self.drafts(2)
        var announcer = WorkspaceStatusAnnouncer()
        #expect(announcer.pendingSegments.isEmpty)
        for id in WorkspaceStatusSegmentID.allCases {
            #expect(announcer.nextDueTick(for: id) == nil, "segment \(id)")
        }
        let unchanged = try announcer.announcements(previous: quiet, current: quiet, tick: 0)
        #expect(unchanged.isEmpty)
        #expect(announcer.pendingSegments.isEmpty)
        let first = try announcer.announcements(previous: quiet, current: one, tick: 1)
        #expect(Self.kinds(first) == ["polite draft"])
        #expect(announcer.pendingSegments.isEmpty)
        #expect(announcer.nextDueTick(for: .draft) == nil)
        let held = try announcer.announcements(previous: one, current: two, tick: 2)
        #expect(held.isEmpty)
        #expect(announcer.pendingSegments == [.draft])
        #expect(announcer.nextDueTick(for: .draft) == 5)
        #expect(announcer.nextDueTick(for: .engine) == nil)
        let spoken = try announcer.announcements(previous: two, current: two, tick: 5)
        #expect(Self.kinds(spoken) == ["polite draft"])
        #expect(spoken.map(\.text) == ["Draft: 2 awaiting review"])
        #expect(announcer.pendingSegments.isEmpty)
        #expect(announcer.nextDueTick(for: .draft) == nil)
    }

    @Test func aHeldChangeIsSpokenByACallExactlyAtItsNextDueTickAndNotOneBefore() throws {
        let quiet = try Self.projection()
        let one = try Self.drafts(1)
        let two = try Self.drafts(2)
        for announcedAt in [UInt64(0), 7, 1_000] {
            var announcer = WorkspaceStatusAnnouncer()
            _ = try announcer.announcements(previous: quiet, current: one, tick: announcedAt)
            let held = try announcer.announcements(previous: one, current: two, tick: announcedAt + 1)
            #expect(held.isEmpty, "announced at \(announcedAt)")
            let due = try #require(announcer.nextDueTick(for: .draft))
            #expect(due == announcedAt + 4, "announced at \(announcedAt)")
            var early = announcer
            let tooSoon = try early.announcements(previous: two, current: two, tick: due - 1)
            #expect(tooSoon.isEmpty, "one tick before \(due)")
            #expect(early.pendingSegments == [.draft])
            #expect(early.nextDueTick(for: .draft) == due)
            let spoken = try announcer.announcements(previous: two, current: two, tick: due)
            #expect(Self.kinds(spoken) == ["polite draft"], "at \(due)")
            #expect(announcer.pendingSegments.isEmpty)
            #expect(announcer.lastAnnouncedTick(for: .draft) == due)
        }
    }

    @Test func theNextDueTickSaturatesAtTheLargestTick() throws {
        let quiet = try Self.projection()
        let one = try Self.drafts(1)
        let two = try Self.drafts(2)
        let largest = UInt64.max
        // `largest - 4` is the last tick whose due tick is exact; from `largest - 3` the sum would wrap past zero.
        for announcedAt in [largest - 4, largest - 3, largest - 2, largest - 1] {
            var announcer = WorkspaceStatusAnnouncer()
            _ = try announcer.announcements(previous: quiet, current: one, tick: announcedAt)
            let held = try announcer.announcements(previous: one, current: two, tick: announcedAt)
            #expect(held.isEmpty, "announced at \(announcedAt)")
            #expect(announcer.pendingSegments == [.draft], "announced at \(announcedAt)")
            #expect(announcer.nextDueTick(for: .draft) == largest, "announced at \(announcedAt)")
            let almost = try announcer.announcements(previous: two, current: two, tick: largest - 1)
            #expect(almost.isEmpty, "one tick before the largest, announced at \(announcedAt)")
            let spoken = try announcer.announcements(previous: two, current: two, tick: largest)
            #expect(Self.kinds(spoken) == ["polite draft"], "announced at \(announcedAt)")
            #expect(announcer.pendingSegments.isEmpty)
            #expect(announcer.lastTick == largest)
            #expect(announcer.lastAnnouncedTick(for: .draft) == largest)
        }
    }

    @Test func aSeverityOnlyChangeWithTheSameWordsIsNotSpokenAgain() throws {
        let quiet = try Self.projection()
        let session = try Self.session(epoch: 2)
        let connected = try Self.projection { $0.peers = [Self.peer("Remote C", .connected(session))] }
        let synced = try Self.projection {
            $0.peers = [Self.peer("Remote C", .synced(session, awaitingResume: false))]
        }
        let words = "Peers: Remote C connected (epoch 2)"
        #expect(connected.segment(.peers).label == words)
        #expect(synced.segment(.peers).label == words)
        #expect(connected.segment(.peers).severity == .attention)
        #expect(synced.segment(.peers).severity == .normal)
        var announcer = WorkspaceStatusAnnouncer()
        let first = try announcer.announcements(previous: quiet, current: connected, tick: 0)
        #expect(Self.kinds(first) == ["polite peers"])
        #expect(first.map(\.text) == [words])
        let settled = try announcer.announcements(previous: connected, current: synced, tick: 4)
        #expect(settled.isEmpty)
        #expect(announcer.pendingSegments.isEmpty)
        #expect(announcer.nextDueTick(for: .peers) == nil)
        #expect(announcer.lastAnnouncedTick(for: .peers) == 0)
        let back = try announcer.announcements(previous: synced, current: connected, tick: 100)
        #expect(back.isEmpty)
        #expect(announcer.lastAnnouncedTick(for: .peers) == 0)
        var other = WorkspaceStatusAnnouncer()
        let seeded = try other.announcements(previous: quiet, current: synced, tick: 0)
        #expect(Self.kinds(seeded) == ["polite peers"])
        let raised = try other.announcements(previous: synced, current: connected, tick: 4)
        #expect(raised.isEmpty)
        #expect(other.pendingSegments.isEmpty)
        #expect(other.lastAnnouncedTick(for: .peers) == 0)
    }

    @Test func aHiddenDisconnectedPeerIsAnnouncedAtHighPriorityWithTheNewText() throws {
        let synced = try Self.syncedPeers(4)
        let head = Array(synced.prefix(3))
        let gone = try Self.session(epoch: 4)
        let before = try Self.projection { $0.peers = synced }
        let after = try Self.projection { $0.peers = head + [Self.peer("P4", .disconnected(gone))] }
        let both = [Self.peer("P4", .disconnected(gone)), Self.peer("P5", .disconnected(gone))]
        let more = try Self.projection { $0.peers = head + both }
        let visible = "P1 connected (epoch 1), P2 connected (epoch 2), P3 connected (epoch 3)"
        let oldText = "Peers: \(visible), and 1 more"
        let newText = "Peers: \(visible), and 1 more, 1 disconnected"
        #expect(before.segment(.peers).label == oldText)
        #expect(after.segment(.peers).label == newText)
        #expect(newText != oldText)
        var announcer = WorkspaceStatusAnnouncer()
        let first = try announcer.announcements(previous: before, current: after, tick: 0)
        #expect(Self.kinds(first) == ["high peers"])
        #expect(first.map(\.text) == [newText])
        let second = try announcer.announcements(previous: after, current: more, tick: 1)
        #expect(Self.kinds(second) == ["high peers"])
        #expect(second.map(\.text) == ["Peers: \(visible), and 2 more, 2 disconnected"])
        #expect(announcer.lastAnnouncedTick(for: .peers) == 1)
    }

    @Test func aHiddenMissingDeviceIsAnnouncedAtHighPriorityWithTheNewText() throws {
        let missing = Self.names("D", 4).map { Self.device($0, .missing) }
        let before = try Self.projection { $0.devices = missing + [Self.device("D5", .stale)] }
        let after = try Self.projection { $0.devices = missing + [Self.device("D5", .missing)] }
        let oldText = "Devices: D1 missing, D2 missing, D3 missing, D4 missing, and 1 more"
        let newText = oldText + ", 1 missing"
        #expect(before.segment(.devices).label == oldText)
        #expect(after.segment(.devices).label == newText)
        #expect(newText != oldText)
        var announcer = WorkspaceStatusAnnouncer()
        let result = try announcer.announcements(previous: before, current: after, tick: 0)
        #expect(Self.kinds(result) == ["high devices"])
        #expect(result.map(\.text) == [newText])
        #expect(announcer.lastAnnouncedTick(for: .devices) == 0)
    }

    @Test func pendingSegmentsAreListedInSegmentOrderEachWithItsOwnDueTick() throws {
        let quiet = try Self.projection()
        let draftOne = try Self.drafts(1)
        let unavailable = try Self.projection {
            $0.draftCount = 1
            $0.clock = WorkspaceStatusClock(nominalHertz: 48_000, measuredHertz: nil)
        }
        let changed = try Self.projection {
            $0.draftCount = 2
            $0.clock = WorkspaceStatusClock(nominalHertz: 48_000, measuredHertz: 47_999)
        }
        var announcer = WorkspaceStatusAnnouncer()
        let first = try announcer.announcements(previous: quiet, current: draftOne, tick: 0)
        #expect(Self.kinds(first) == ["polite draft"])
        let second = try announcer.announcements(previous: draftOne, current: unavailable, tick: 2)
        #expect(Self.kinds(second) == ["polite clock"])
        let held = try announcer.announcements(previous: unavailable, current: changed, tick: 3)
        #expect(held.isEmpty)
        #expect(announcer.pendingSegments == [.clock, .draft])
        #expect(announcer.nextDueTick(for: .clock) == 6)
        #expect(announcer.nextDueTick(for: .draft) == 4)
        let draftDue = try announcer.announcements(previous: changed, current: changed, tick: 4)
        #expect(Self.kinds(draftDue) == ["polite draft"])
        #expect(draftDue.map(\.text) == ["Draft: 2 awaiting review"])
        #expect(announcer.pendingSegments == [.clock])
        let waiting = try announcer.announcements(previous: changed, current: changed, tick: 5)
        #expect(waiting.isEmpty)
        let clockDue = try announcer.announcements(previous: changed, current: changed, tick: 6)
        #expect(Self.kinds(clockDue) == ["polite clock"])
        #expect(clockDue.map(\.text) == ["Clock: 48 kHz nominal, actual 47.999 kHz"])
        #expect(announcer.pendingSegments.isEmpty)
    }
}
