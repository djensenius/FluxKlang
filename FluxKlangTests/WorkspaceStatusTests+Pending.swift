//
//  WorkspaceStatusTests+Pending.swift
//  FluxKlangTests
//
//  The announcer's held changes and hidden-item sentences (#99 W3): which segments wait for their due tick,
//  the saturating due tick, a change of severity alone that says nothing new, the new words that make a
//  hidden new error audible at high priority, lost items compared as a multiset (a second loss of a name
//  that is already lost is a new error) and a capability lost while the engine prepares.
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

// MARK: - Lost items are a multiset

extension WorkspaceStatusTests {
    /// One kind of list of lost items and the word its label uses for a lost item: a missing device, a
    /// disconnected peer. `name` and `other` are two different names; `visible` are as many distinct names as
    /// the label lists before "and N more".
    struct LostList: Sendable {
        let id: WorkspaceStatusSegmentID
        let name: String
        let other: String
        let word: String
        let visible: [String]

        /// The label of the segment when exactly these names are lost, in this order.
        func label(_ names: [String]) -> String {
            "\(id.title): " + names.map { "\($0) \(word)" }.joined(separator: ", ")
        }

        /// The label when the `visible` names and `hidden` more lost items are lost: the cap, then the exact
        /// number of items left out and the exact number of those that are lost.
        func hiddenLabel(_ hidden: Int) -> String {
            label(visible) + ", and \(hidden) more, \(hidden) \(word)"
        }
    }

    static let lostLists = [
        LostList(
            id: .devices, name: "Pad A", other: "Pad B", word: "missing",
            visible: ["Pad 1", "Pad 2", "Pad 3", "Pad 4"]
        ),
        LostList(
            id: .peers, name: "Remote C", other: "Remote D", word: "disconnected",
            visible: ["Peer 1", "Peer 2", "Peer 3"]
        )
    ]

    /// The projection in which exactly these names are lost: missing devices, or disconnected peers.
    static func lostProjection(
        _ names: [String], in id: WorkspaceStatusSegmentID
    ) throws -> WorkspaceStatusProjection {
        let gone = try session(epoch: 1)
        let peers: [WorkspaceStatusPeer] = id == .peers ? names.map { Self.peer($0, .disconnected(gone)) } : []
        let devices: [WorkspaceStatusDevice] = id == .devices ? names.map { Self.device($0, .missing) } : []
        return try projection {
            $0.peers = peers
            $0.devices = devices
        }
    }

    /// The projection of an engine that prepares revision 43 while `base` renders.
    static func preparingProjection(over base: RunningSetState) throws -> WorkspaceStatusProjection {
        let revision = try ContractRevision(43)
        return try projection { $0.lifecycle = .preparing(revision, over: base) }
    }

    @Test func aSecondLossOfTheSameDeviceNameIsAHighAnnouncementInsideTheThrottleWindow() throws {
        let quiet = try Self.projection()
        let one = try Self.lostProjection(["Pad A"], in: .devices)
        let two = try Self.lostProjection(["Pad A", "Pad A"], in: .devices)
        #expect(one.segment(.devices).lostItems == ["Pad A"])
        #expect(two.segment(.devices).lostItems == ["Pad A", "Pad A"])
        var announcer = WorkspaceStatusAnnouncer()
        let first = try announcer.announcements(previous: quiet, current: one, tick: 0)
        #expect(Self.kinds(first) == ["high devices"])
        #expect(first.map(\.text) == ["Devices: Pad A missing"])
        let second = try announcer.announcements(previous: one, current: two, tick: 1)
        #expect(Self.kinds(second) == ["high devices"])
        #expect(second.map(\.text) == ["Devices: Pad A missing, Pad A missing"])
        #expect(announcer.lastAnnouncedTick(for: .devices) == 1)
        #expect(announcer.pendingSegments.isEmpty)
        let replay = try announcer.announcements(previous: two, current: two, tick: 2)
        #expect(replay.isEmpty)
    }

    @Test func aSecondLossOfTheSamePeerNameIsAHighAnnouncementInsideTheThrottleWindow() throws {
        let quiet = try Self.projection()
        let one = try Self.lostProjection(["Remote C"], in: .peers)
        let two = try Self.lostProjection(["Remote C", "Remote C"], in: .peers)
        #expect(one.segment(.peers).lostItems == ["Remote C"])
        #expect(two.segment(.peers).lostItems == ["Remote C", "Remote C"])
        var announcer = WorkspaceStatusAnnouncer()
        let first = try announcer.announcements(previous: quiet, current: one, tick: 0)
        #expect(Self.kinds(first) == ["high peers"])
        #expect(first.map(\.text) == ["Peers: Remote C disconnected"])
        let second = try announcer.announcements(previous: one, current: two, tick: 1)
        #expect(Self.kinds(second) == ["high peers"])
        #expect(second.map(\.text) == ["Peers: Remote C disconnected, Remote C disconnected"])
        #expect(announcer.lastAnnouncedTick(for: .peers) == 1)
        #expect(announcer.pendingSegments.isEmpty)
        let replay = try announcer.announcements(previous: two, current: two, tick: 2)
        #expect(replay.isEmpty)
    }

    @Test func oneOfTwoLostItemsWithTheSameNameRecoveringIsNotANewError() throws {
        let quiet = try Self.projection()
        for list in Self.lostLists {
            let both = try Self.lostProjection([list.name, list.name], in: list.id)
            let single = try Self.lostProjection([list.name], in: list.id)
            var announcer = WorkspaceStatusAnnouncer()
            let first = try announcer.announcements(previous: quiet, current: both, tick: 0)
            #expect(Self.kinds(first) == ["high \(list.id.rawValue)"], "\(list.id)")
            let leaving = try announcer.announcements(previous: both, current: single, tick: 1)
            #expect(leaving.isEmpty, "\(list.id)")
            #expect(announcer.pendingSegments == [list.id], "\(list.id)")
            #expect(announcer.nextDueTick(for: list.id) == 4, "\(list.id)")
            let delivered = try announcer.announcements(previous: single, current: single, tick: 4)
            #expect(Self.kinds(delivered) == ["polite \(list.id.rawValue)"], "\(list.id)")
            #expect(delivered.map(\.text) == [list.label([list.name])], "\(list.id)")
            #expect(announcer.pendingSegments.isEmpty, "\(list.id)")
        }
    }

    @Test func theSameTwoLostItemsWithTheSameNameAreNotANewErrorAgain() throws {
        let quiet = try Self.projection()
        for list in Self.lostLists {
            let both = try Self.lostProjection([list.name, list.name], in: list.id)
            var announcer = WorkspaceStatusAnnouncer()
            let first = try announcer.announcements(previous: quiet, current: both, tick: 0)
            #expect(Self.kinds(first) == ["high \(list.id.rawValue)"], "\(list.id)")
            #expect(first.map(\.text) == [list.label([list.name, list.name])], "\(list.id)")
            for tick in [UInt64(1), 4, 100] {
                let again = try announcer.announcements(previous: both, current: both, tick: tick)
                #expect(again.isEmpty, "\(list.id) at tick \(tick)")
            }
            #expect(announcer.pendingSegments.isEmpty, "\(list.id)")
            #expect(announcer.lastAnnouncedTick(for: list.id) == 0, "\(list.id)")
        }
    }

    @Test func aReshuffleOfTheLostItemsWithEqualCountsIsNotANewError() throws {
        let quiet = try Self.projection()
        for list in Self.lostLists {
            let before = [list.name, list.other, list.name]
            let after = [list.other, list.name, list.name]
            let start = try Self.lostProjection(before, in: list.id)
            let shuffled = try Self.lostProjection(after, in: list.id)
            var announcer = WorkspaceStatusAnnouncer()
            let first = try announcer.announcements(previous: quiet, current: start, tick: 0)
            #expect(Self.kinds(first) == ["high \(list.id.rawValue)"], "\(list.id)")
            #expect(first.map(\.text) == [list.label(before)], "\(list.id)")
            let reshuffle = try announcer.announcements(previous: start, current: shuffled, tick: 1)
            #expect(reshuffle.isEmpty, "\(list.id)")
            #expect(announcer.pendingSegments == [list.id], "\(list.id)")
            let delivered = try announcer.announcements(previous: shuffled, current: shuffled, tick: 4)
            #expect(Self.kinds(delivered) == ["polite \(list.id.rawValue)"], "\(list.id)")
            #expect(delivered.map(\.text) == [list.label(after)], "\(list.id)")
        }
    }

    @Test func aSecondHiddenLossOfTheSameNameIsCountedAndAnnouncedAtHighPriority() throws {
        let quiet = try Self.projection()
        for list in Self.lostLists {
            let one = try Self.lostProjection(list.visible + [list.name], in: list.id)
            let two = try Self.lostProjection(list.visible + [list.name, list.name], in: list.id)
            #expect(one.segment(list.id).label == list.hiddenLabel(1), "\(list.id)")
            #expect(two.segment(list.id).label == list.hiddenLabel(2), "\(list.id)")
            var announcer = WorkspaceStatusAnnouncer()
            let first = try announcer.announcements(previous: quiet, current: one, tick: 0)
            #expect(Self.kinds(first) == ["high \(list.id.rawValue)"], "\(list.id)")
            let second = try announcer.announcements(previous: one, current: two, tick: 1)
            #expect(Self.kinds(second) == ["high \(list.id.rawValue)"], "\(list.id)")
            #expect(second.map(\.text) == [list.hiddenLabel(2)], "\(list.id)")
            #expect(announcer.pendingSegments.isEmpty, "\(list.id)")
        }
    }
}

// MARK: - A capability lost while the engine prepares

extension WorkspaceStatusTests {
    @Test func aCapabilityLostWhilePreparingIsAnnouncedAtHighPriority() throws {
        let quiet = try Self.projection()
        let audio = CapabilityID(validated: "audio.out")
        let calm = try Self.preparingProjection(over: .running)
        let lost = try Self.preparingProjection(over: .degraded([audio]))
        #expect(calm.segment(.engine).severity == .normal)
        #expect(lost.segment(.engine).severity == .error)
        var announcer = WorkspaceStatusAnnouncer()
        let first = try announcer.announcements(previous: quiet, current: calm, tick: 0)
        #expect(Self.kinds(first) == ["polite engine"])
        #expect(first.map(\.text) == ["Engine: Preparing rev 43..."])
        let second = try announcer.announcements(previous: calm, current: lost, tick: 1)
        #expect(Self.kinds(second) == ["high engine"])
        #expect(second.map(\.text) == ["Engine: Preparing rev 43... Running: audio.out Lost/Muted"])
        #expect(announcer.lastAnnouncedTick(for: .engine) == 1)
        var fresh = WorkspaceStatusAnnouncer()
        let direct = try fresh.announcements(previous: quiet, current: lost, tick: 0)
        #expect(Self.kinds(direct) == ["high engine"])
        #expect(direct.map(\.text) == ["Engine: Preparing rev 43... Running: audio.out Lost/Muted"])
    }

    @Test func preparingOverTheSameDegradedSetIsNeitherAClearingNorANewError() throws {
        let quiet = try Self.projection()
        let audio = CapabilityID(validated: "audio.out")
        let degraded = try Self.projection { $0.lifecycle = .degraded([audio]) }
        let preparing = try Self.preparingProjection(over: .degraded([audio]))
        #expect(degraded.segment(.engine).severity == .error)
        #expect(preparing.segment(.engine).severity == .error)
        #expect(preparing.segment(.engine).lostItems == ["audio.out"])
        var announcer = WorkspaceStatusAnnouncer()
        let first = try announcer.announcements(previous: quiet, current: degraded, tick: 0)
        #expect(Self.kinds(first) == ["high engine"])
        #expect(first.map(\.text) == ["Engine: Running: audio.out Lost/Muted"])
        let started = try announcer.announcements(previous: degraded, current: preparing, tick: 1)
        #expect(started.isEmpty)
        #expect(announcer.pendingSegments == [.engine])
        #expect(announcer.nextDueTick(for: .engine) == 4)
        let spoken = try announcer.announcements(previous: preparing, current: preparing, tick: 4)
        #expect(Self.kinds(spoken) == ["polite engine"])
        #expect(spoken.map(\.text) == ["Engine: Preparing rev 43... Running: audio.out Lost/Muted"])
        #expect(announcer.pendingSegments.isEmpty)
        let later = try announcer.announcements(previous: preparing, current: preparing, tick: 9)
        #expect(later.isEmpty)
    }

    @Test func aCapabilityLostWhileAlreadyPreparingOverADegradedEngineIsAnnouncedAtHighPriority() throws {
        let quiet = try Self.projection()
        let audio = CapabilityID(validated: "audio.out")
        let midi = CapabilityID(validated: "midi.in")
        let one = try Self.preparingProjection(over: .degraded([audio]))
        let two = try Self.preparingProjection(over: .degraded([audio, midi]))
        var announcer = WorkspaceStatusAnnouncer()
        let first = try announcer.announcements(previous: quiet, current: one, tick: 0)
        #expect(Self.kinds(first) == ["high engine"])
        let second = try announcer.announcements(previous: one, current: two, tick: 1)
        #expect(Self.kinds(second) == ["high engine"])
        #expect(second.map(\.text) == ["Engine: Preparing rev 43... Running: audio.out, midi.in Lost/Muted"])
        #expect(two.segment(.engine).lostItems == ["audio.out", "midi.in"])
        #expect(announcer.lastAnnouncedTick(for: .engine) == 1)
        let recovered = try announcer.announcements(previous: two, current: one, tick: 2)
        #expect(recovered.isEmpty)
        #expect(announcer.pendingSegments == [.engine])
    }

    @Test func preparingOverAnAbsentOrRunningSetAfterADegradedEngineIsARealClearing() throws {
        let quiet = try Self.projection()
        let degraded = try Self.projection { $0.lifecycle = .degraded([CapabilityID(validated: "audio.out")]) }
        let bases: [RunningSetState] = [.absent, .running]
        for base in bases {
            let preparing = try Self.preparingProjection(over: base)
            var announcer = WorkspaceStatusAnnouncer()
            let first = try announcer.announcements(previous: quiet, current: degraded, tick: 0)
            #expect(Self.kinds(first) == ["high engine"], "\(base)")
            let started = try announcer.announcements(previous: degraded, current: preparing, tick: 1)
            #expect(started.isEmpty, "\(base)")
            #expect(announcer.pendingSegments == [.engine], "\(base)")
            let cleared = try announcer.announcements(previous: preparing, current: preparing, tick: 4)
            #expect(Self.kinds(cleared) == ["polite engine"], "\(base)")
            #expect(cleared.map(\.text) == ["Engine: Preparing rev 43..."], "\(base)")
        }
    }
}
