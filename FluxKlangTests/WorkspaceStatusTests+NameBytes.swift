//
//  WorkspaceStatusTests+NameBytes.swift
//  FluxKlangTests
//
//  The announcer identifies lost names and the announced label by UTF-8 bytes (#99 WSA1): a differential test
//  against a verbatim copy of the old policy, the deliberate change for canonically equivalent names, limits and
//  a source-scan guard.
//

import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

private struct NameBytesOutput: Hashable, Sendable {
    let segment: WorkspaceStatusSegmentID
    let text: String
    let priority: WorkspaceStatusAnnouncementPriority
}

private extension NameBytesOutput {
    init(_ announcement: WorkspaceStatusAnnouncement) {
        self.init(segment: announcement.segment, text: announcement.text, priority: announcement.priority)
    }
}

private protocol NameBytesPolicy {
    var pendingSegments: [WorkspaceStatusSegmentID] { get }
    var lastTick: UInt64? { get }
    func nextDueTick(for id: WorkspaceStatusSegmentID) -> UInt64?
    func lastAnnouncedTick(for id: WorkspaceStatusSegmentID) -> UInt64?
}

extension WorkspaceStatusAnnouncer: NameBytesPolicy {}

private struct NameBytesSnapshot: Equatable, Sendable {
    let outputs: [NameBytesOutput]
    let pending: [WorkspaceStatusSegmentID]
    let dueTicks: [UInt64?]
    let announcedTicks: [UInt64?]
    let lastTick: UInt64?

    init(_ outputs: [NameBytesOutput], _ policy: some NameBytesPolicy) {
        let ids = WorkspaceStatusSegmentID.allCases
        self.outputs = outputs
        pending = policy.pendingSegments
        dueTicks = ids.map { policy.nextDueTick(for: $0) }
        announcedTicks = ids.map { policy.lastAnnouncedTick(for: $0) }
        lastTick = policy.lastTick
    }
}

/// A verbatim copy of `WorkspaceStatusAnnouncer` before the change: lost items keyed by `String` and labels
/// compared with `!=`. Renames only: the type, the announcement tuple (`NameBytesOutput`) and the helpers.
private struct NameBytesLegacyAnnouncer: Hashable, Sendable, NameBytesPolicy {
    static let throttleTicks: UInt64 = 4

    private struct Memory: Hashable, Sendable {
        var known: WorkspaceStatusSegment
        var announced: WorkspaceStatusSegment
        var announcedTick: UInt64?

        init(seededFrom segment: WorkspaceStatusSegment) {
            known = segment
            announced = segment
            announcedTick = nil
        }

        var isPending: Bool { NameBytesLegacyAnnouncer.differs(known, from: announced) }

        mutating func advance(to now: WorkspaceStatusSegment, tick: UInt64) -> WorkspaceStatusAnnouncementPriority? {
            defer { known = now }
            if NameBytesLegacyAnnouncer.isNewError(from: known, to: now) {
                record(now, at: tick)
                return .high
            }
            guard NameBytesLegacyAnnouncer.differs(now, from: announced), isDue(at: tick) else { return nil }
            record(now, at: tick)
            return .polite
        }

        private mutating func record(_ segment: WorkspaceStatusSegment, at tick: UInt64) {
            announced = segment
            announcedTick = tick
        }

        private func isDue(at tick: UInt64) -> Bool {
            guard let last = announcedTick else { return true }
            return tick >= NameBytesLegacyAnnouncer.dueTick(after: last)
        }
    }

    private var memory: [WorkspaceStatusSegmentID: Memory] = [:]
    private(set) var lastTick: UInt64?

    init() {}

    func lastAnnouncedTick(for id: WorkspaceStatusSegmentID) -> UInt64? {
        memory[id]?.announcedTick
    }

    var pendingSegments: [WorkspaceStatusSegmentID] {
        WorkspaceStatusSegmentID.allCases.filter { memory[$0]?.isPending ?? false }
    }

    func nextDueTick(for id: WorkspaceStatusSegmentID) -> UInt64? {
        guard let entry = memory[id], entry.isPending else { return nil }
        return entry.announcedTick.map(Self.dueTick(after:)) ?? lastTick
    }

    mutating func announcements(
        previous: WorkspaceStatusProjection, current: WorkspaceStatusProjection, tick: UInt64
    ) throws(WorkspaceStatusRefusal) -> [NameBytesOutput] {
        if let last = lastTick, tick < last { throw .tickWentBackwards(last: last, found: tick) }
        var updated = memory
        var high: [NameBytesOutput] = []
        var polite: [NameBytesOutput] = []
        for id in WorkspaceStatusSegmentID.allCases {
            let now = current.segment(id)
            var entry = updated[id] ?? Memory(seededFrom: previous.segment(id))
            switch entry.advance(to: now, tick: tick) {
            case .high?: high.append(NameBytesOutput(segment: now.id, text: now.label, priority: .high))
            case .polite?: polite.append(NameBytesOutput(segment: now.id, text: now.label, priority: .polite))
            case nil: break
            }
            updated[id] = entry
        }
        memory = updated
        lastTick = tick
        return high + polite
    }

    fileprivate static func isNewError(from old: WorkspaceStatusSegment, to now: WorkspaceStatusSegment) -> Bool {
        guard now.severity == .error else { return false }
        return old.severity != .error || occursMoreOften(in: now.lostItems, than: old.lostItems)
    }

    private static func occursMoreOften(in items: [String], than others: [String]) -> Bool {
        var remaining: [String: Int] = [:]
        for item in others { remaining[item] = (remaining[item] ?? 0) + 1 }
        for item in items {
            let left = (remaining[item] ?? 0) - 1
            if left < 0 { return true }
            remaining[item] = left
        }
        return false
    }

    fileprivate static func differs(
        _ now: WorkspaceStatusSegment, from announced: WorkspaceStatusSegment
    ) -> Bool {
        now.label != announced.label || !haveSameItems(now.lostItems, announced.lostItems)
    }

    private static func haveSameItems(_ items: [String], _ others: [String]) -> Bool {
        items.count == others.count && !occursMoreOften(in: items, than: others)
    }

    fileprivate static func dueTick(after tick: UInt64) -> UInt64 {
        let (sum, overflow) = tick.addingReportingOverflow(throttleTicks)
        return overflow ? UInt64.max : sum
    }
}

private struct NameBytesRandom: Sendable {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var mixed = state
        mixed = (mixed ^ (mixed &>> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed &>> 27)) &* 0x94D0_49BB_1331_11EB
        return mixed ^ (mixed &>> 31)
    }

    mutating func below(_ bound: Int) -> Int {
        let drawn = next() % UInt64(bound)
        return Int(drawn)
    }
}

private struct NameBytesStep: Sendable {
    let devices: [WorkspaceStatusDevice]
    let peers: [WorkspaceStatusPeer]
    let drafts: Int
    let clockUnavailable: Bool
}

private enum NameBytesGenerator {
    static let asciiPool = ["Pad A", "Pad B", "Pad C", "Remote C", "Remote D", "X"]
    /// Distinct, non-equivalent names with non-ASCII text: the old and the new policy must agree on them too.
    static let unicodePool = [
        "Pad \u{e9}", "Pad \u{e8}", "Pad e", "\u{30D1}\u{30C3}\u{30C9}", "\u{1F3B9} A", "Pad \u{c9}"
    ]
    static let sizes = [0, 1, 2, 3, 5, 8]
    static let presences: [DevicePresence] = [.missing, .missing, .stale, .present]

    static func step(
        _ random: inout NameBytesRandom, pool: [String], session: PeerSyncSession
    ) -> NameBytesStep {
        let phases: [PeerReconnectState.Phase] = [
            .disconnected(session), .disconnected(session), .connected(session),
            .synced(session, awaitingResume: false), .resyncing(session)
        ]
        let deviceCount = sizes[random.below(sizes.count)]
        let peerCount = sizes[random.below(sizes.count)]
        var devices: [WorkspaceStatusDevice] = []
        for _ in 0..<deviceCount {
            let name = pool[random.below(pool.count)]
            devices.append(WorkspaceStatusDevice(name: name, presence: presences[random.below(presences.count)]))
        }
        var peers: [WorkspaceStatusPeer] = []
        for _ in 0..<peerCount {
            let name = pool[random.below(pool.count)]
            peers.append(WorkspaceStatusPeer(
                name: name, phase: phases[random.below(phases.count)], discardedStaleCommands: 0
            ))
        }
        let drafts = random.below(4)
        let unavailable = random.below(3) == 0
        return NameBytesStep(devices: devices, peers: peers, drafts: drafts, clockUnavailable: unavailable)
    }
}

extension WorkspaceStatusTests {
    private static func bytesProjection(_ step: NameBytesStep) throws -> WorkspaceStatusProjection {
        try projection {
            $0.devices = step.devices
            $0.peers = step.peers
            $0.draftCount = step.drafts
            $0.clock = WorkspaceStatusClock(nominalHertz: 48_000, measuredHertz: step.clockUnavailable ? nil : 48_000)
        }
    }

    private static func bytesTick(_ tick: UInt64, plus distance: UInt64) -> UInt64 {
        let (sum, overflow) = tick.addingReportingOverflow(distance)
        return overflow ? UInt64.max : sum
    }

    /// One random run through both policies; returns the number of steps compared. The first run of a seed
    /// starts six ticks below `UInt64.max`, so the saturating due tick is crossed.
    private static func bytesRun(seed: UInt64, index: Int, pool: [String], session: PeerSyncSession) throws -> Int {
        var random = NameBytesRandom(state: seed * 1_000 + UInt64(index))
        let stepCount = 3 + random.below(10)
        var tick: UInt64 = index == 0 ? UInt64.max - 6 : 0
        var previous = try projection()
        var announcer = WorkspaceStatusAnnouncer()
        var legacy = NameBytesLegacyAnnouncer()
        for stepIndex in 0..<stepCount {
            let current = try bytesProjection(NameBytesGenerator.step(&random, pool: pool, session: session))
            tick = bytesTick(tick, plus: UInt64(random.below(6)))
            let fresh = try announcer.announcements(previous: previous, current: current, tick: tick)
            let old = try legacy.announcements(previous: previous, current: current, tick: tick)
            let newSnapshot = NameBytesSnapshot(fresh.map(NameBytesOutput.init), announcer)
            let oldSnapshot = NameBytesSnapshot(old, legacy)
            #expect(newSnapshot == oldSnapshot, "seed \(seed) run \(index) step \(stepIndex)")
            previous = current
        }
        return stepCount
    }

    private static func bytesDifferential(seeds: ClosedRange<UInt64>, pool: [String]) throws -> Int {
        let peerSession = try session(epoch: 1)
        var compared = 0
        for seed in seeds {
            for index in 0..<40 {
                compared += try bytesRun(seed: seed, index: index, pool: pool, session: peerSession)
            }
        }
        return compared
    }

    @Test func theNewPolicyEqualsTheOldOnAsciiNamesOverFixedSeeds() throws {
        let compared = try Self.bytesDifferential(seeds: 1...8, pool: NameBytesGenerator.asciiPool)
        #expect(compared >= 960)
    }

    @Test func theNewPolicyEqualsTheOldOnDistinctNonAsciiNamesOverFixedSeeds() throws {
        let compared = try Self.bytesDifferential(seeds: 101...104, pool: NameBytesGenerator.unicodePool)
        #expect(compared >= 480)
    }
}

extension WorkspaceStatusTests {
    /// Canonically equivalent: Character-equal, but different bytes.
    private static let bytesComposed = "Pad \u{e9}"
    private static let bytesDecomposed = "Pad e\u{301}"
    private static let bytesOther = "Pad X"

    private static func bytesOf(_ text: String) -> [UInt8] { Array(text.utf8) }

    private static func bytesOfTexts(_ announcements: [WorkspaceStatusAnnouncement]) -> [[UInt8]] {
        announcements.map { Array($0.text.utf8) }
    }

    @Test func theEquivalentFixtureNamesAreCharacterEqualButByteDifferent() throws {
        #expect(Self.bytesComposed == Self.bytesDecomposed)
        #expect(Self.bytesOf(Self.bytesComposed) != Self.bytesOf(Self.bytesDecomposed))
        #expect(Self.bytesComposed.utf8.count == 6)
        #expect(Self.bytesDecomposed.utf8.count == 7)
        let lost = try Self.lostProjection([Self.bytesDecomposed], in: .devices)
        #expect(Self.bytesOf(lost.segment(.devices).label) == Self.bytesOf("Devices: Pad e\u{301} missing"))
    }

    @Test func equivalentLostDeviceAndPeerNamesAreTwoLostItems() throws {
        let quiet = try Self.projection()
        for list in Self.lostLists {
            let composed = try Self.lostProjection([Self.bytesComposed], in: list.id)
            let decomposed = try Self.lostProjection([Self.bytesDecomposed], in: list.id)
            var announcer = WorkspaceStatusAnnouncer()
            let first = try announcer.announcements(previous: quiet, current: composed, tick: 0)
            #expect(Self.kinds(first) == ["high \(list.id.rawValue)"], "\(list.id)")
            #expect(Self.bytesOfTexts(first) == [Self.bytesOf(list.label([Self.bytesComposed]))], "\(list.id)")
            let second = try announcer.announcements(previous: composed, current: decomposed, tick: 1)
            #expect(Self.kinds(second) == ["high \(list.id.rawValue)"], "\(list.id)")
            #expect(Self.bytesOfTexts(second) == [Self.bytesOf(list.label([Self.bytesDecomposed]))], "\(list.id)")
            #expect(announcer.lastAnnouncedTick(for: list.id) == 1, "\(list.id)")
            #expect(announcer.pendingSegments.isEmpty, "\(list.id)")
        }
    }

    @Test func aSwapThatKeepsEveryNameCountButNotTheBytesIsAHighAnnouncement() throws {
        let quiet = try Self.projection()
        let swaps: [(before: [String], after: [String])] = [
            ([Self.bytesComposed, Self.bytesOther], [Self.bytesDecomposed, Self.bytesOther]),
            ([Self.bytesComposed, Self.bytesComposed], [Self.bytesComposed, Self.bytesDecomposed])
        ]
        for list in Self.lostLists {
            for (before, after) in swaps {
                let start = try Self.lostProjection(before, in: list.id)
                let end = try Self.lostProjection(after, in: list.id)
                var announcer = WorkspaceStatusAnnouncer()
                let first = try announcer.announcements(previous: quiet, current: start, tick: 0)
                #expect(Self.kinds(first) == ["high \(list.id.rawValue)"], "\(list.id)")
                let second = try announcer.announcements(previous: start, current: end, tick: 1)
                #expect(Self.kinds(second) == ["high \(list.id.rawValue)"], "\(list.id) \(after)")
                #expect(Self.bytesOfTexts(second) == [Self.bytesOf(list.label(after))], "\(list.id) \(after)")
            }
        }
    }

    @Test func aHiddenLossReplacedByAnEquivalentNameIsAHighAnnouncement() throws {
        let quiet = try Self.projection()
        for list in Self.lostLists {
            let start = try Self.lostProjection(list.visible + [Self.bytesComposed], in: list.id)
            let end = try Self.lostProjection(list.visible + [Self.bytesDecomposed], in: list.id)
            let words = list.hiddenLabel(1)
            #expect(start.segment(list.id).label == words, "\(list.id)")
            #expect(end.segment(list.id).label == words, "\(list.id)")
            var announcer = WorkspaceStatusAnnouncer()
            let first = try announcer.announcements(previous: quiet, current: start, tick: 0)
            #expect(Self.kinds(first) == ["high \(list.id.rawValue)"], "\(list.id)")
            let second = try announcer.announcements(previous: start, current: end, tick: 1)
            #expect(Self.kinds(second) == ["high \(list.id.rawValue)"], "\(list.id)")
            #expect(announcer.pendingSegments.isEmpty, "\(list.id)")
        }
    }

    @Test func aReshuffleOfByteEqualNamesBehindTheCapIsStillNotAChange() throws {
        let quiet = try Self.projection()
        for list in Self.lostLists {
            let start = try Self.lostProjection(list.visible + [Self.bytesComposed, Self.bytesOther], in: list.id)
            let end = try Self.lostProjection(list.visible + [Self.bytesOther, Self.bytesComposed], in: list.id)
            var announcer = WorkspaceStatusAnnouncer()
            let first = try announcer.announcements(previous: quiet, current: start, tick: 0)
            #expect(Self.kinds(first) == ["high \(list.id.rawValue)"], "\(list.id)")
            let second = try announcer.announcements(previous: start, current: end, tick: 1)
            #expect(second.isEmpty, "\(list.id)")
            #expect(announcer.pendingSegments.isEmpty, "\(list.id)")
            #expect(announcer.nextDueTick(for: list.id) == nil, "\(list.id)")
        }
    }

    @Test func aChangeAfterAnAnnouncementAtTheLargestTicksIsHeldUntilTheTickCannotGrow() throws {
        let quiet = try Self.projection()
        let lost = try Self.lostProjection(["Pad A"], in: .devices)
        let stale = try Self.projection { $0.devices = [Self.device("Pad A", .stale)] }
        var announcer = WorkspaceStatusAnnouncer()
        let first = try announcer.announcements(previous: quiet, current: lost, tick: UInt64.max - 1)
        #expect(Self.kinds(first) == ["high devices"])
        let held = try announcer.announcements(previous: lost, current: stale, tick: UInt64.max - 1)
        #expect(held.isEmpty)
        #expect(announcer.nextDueTick(for: .devices) == UInt64.max)
        #expect(announcer.pendingSegments == [.devices])
        let due = try announcer.announcements(previous: stale, current: stale, tick: UInt64.max)
        #expect(Self.kinds(due) == ["polite devices"])
    }

    @Test func lostItemsAreStillCaseSensitive() throws {
        let quiet = try Self.projection()
        let upper = try Self.lostProjection(["Pad A"], in: .devices)
        let lower = try Self.lostProjection(["pad a"], in: .devices)
        var announcer = WorkspaceStatusAnnouncer()
        let first = try announcer.announcements(previous: quiet, current: upper, tick: 0)
        #expect(Self.kinds(first) == ["high devices"])
        let second = try announcer.announcements(previous: upper, current: lower, tick: 1)
        #expect(Self.kinds(second) == ["high devices"])
        let third = try announcer.announcements(previous: lower, current: upper, tick: 2)
        #expect(Self.kinds(third) == ["high devices"])
    }

    @Test func aLabelThatExtendsTheAnnouncedOneIsHeldAndThenSpokenOnce() throws {
        let quiet = try Self.projection()
        let one = try Self.projection { $0.devices = [Self.device("Pad A", .stale)] }
        let two = try Self.projection { $0.devices = [Self.device("Pad A", .stale), Self.device("Pad B", .stale)] }
        let oldLabel = one.segment(.devices).label
        let newLabel = two.segment(.devices).label
        #expect(newLabel.utf8.starts(with: oldLabel.utf8))
        var announcer = WorkspaceStatusAnnouncer()
        _ = try announcer.announcements(previous: quiet, current: one, tick: 0)
        let early = try announcer.announcements(previous: one, current: two, tick: 1)
        #expect(early.isEmpty)
        #expect(announcer.pendingSegments == [.devices])
        let due = try announcer.announcements(previous: two, current: two, tick: 4)
        #expect(Self.kinds(due) == ["polite devices"])
        #expect(Self.bytesOfTexts(due) == [Self.bytesOf(newLabel)])
    }

    @Test func anEquivalentStaleDeviceRenameIsOnePoliteAnnouncementThatTheThrottleHolds() throws {
        let quiet = try Self.projection()
        let composed = try Self.projection { $0.devices = [Self.device(Self.bytesComposed, .stale)] }
        let decomposed = try Self.projection { $0.devices = [Self.device(Self.bytesDecomposed, .stale)] }
        var announcer = WorkspaceStatusAnnouncer()
        let first = try announcer.announcements(previous: quiet, current: composed, tick: 0)
        #expect(Self.kinds(first) == ["polite devices"])
        #expect(Self.bytesOfTexts(first) == [Self.bytesOf("Devices: Pad \u{e9} stale")])
        var held = announcer
        let early = try held.announcements(previous: composed, current: decomposed, tick: 1)
        #expect(early.isEmpty)
        #expect(held.pendingSegments == [.devices])
        #expect(held.nextDueTick(for: .devices) == 4)
        let due = try held.announcements(previous: decomposed, current: decomposed, tick: 4)
        #expect(Self.kinds(due) == ["polite devices"])
        #expect(Self.bytesOfTexts(due) == [Self.bytesOf("Devices: Pad e\u{301} stale")])
        let late = try announcer.announcements(previous: composed, current: decomposed, tick: 10)
        #expect(Self.kinds(late) == ["polite devices"])
        #expect(Self.bytesOfTexts(late) == [Self.bytesOf("Devices: Pad e\u{301} stale")])
        #expect(announcer.pendingSegments.isEmpty)
    }
}

extension WorkspaceStatusTests {
    @Test func maximumLengthEquivalentLostNamesAreTwoItems() throws {
        let stem = String(repeating: "a", count: 125)
        let composed = stem + "\u{e9}"
        let decomposed = stem + "e\u{301}"
        let quiet = try Self.projection()
        for list in Self.lostLists {
            let start = try Self.lostProjection([composed], in: list.id)
            let end = try Self.lostProjection([decomposed], in: list.id)
            var announcer = WorkspaceStatusAnnouncer()
            let first = try announcer.announcements(previous: quiet, current: start, tick: 0)
            #expect(Self.kinds(first) == ["high \(list.id.rawValue)"], "\(list.id)")
            let second = try announcer.announcements(previous: start, current: end, tick: 1)
            #expect(Self.kinds(second) == ["high \(list.id.rawValue)"], "\(list.id)")
        }
    }

    @Test func aNameOneByteOverTheLimitIsStillRefusedBeforeTheAnnouncerSeesIt() {
        let tooLong = String(repeating: "a", count: 126) + "e\u{301}"
        #expect(tooLong.utf8.count == 129)
        #expect(throws: WorkspaceStatusRefusal.self) { try Self.lostProjection([tooLong], in: .devices) }
        #expect(throws: WorkspaceStatusRefusal.self) { try Self.lostProjection([tooLong], in: .peers) }
    }
}

extension WorkspaceStatusTests {
    private static func bytesSourceURL(from path: String = #filePath) -> URL? {
        let here = URL(fileURLWithPath: path).deletingLastPathComponent()
        let relative = "Shared/Views/Workspace/Shell/Status/WorkspaceStatusAnnouncer.swift"
        let candidates = ["../" + relative, "../../Sources/FluxKlang/" + relative]
        return candidates
            .map { here.appendingPathComponent($0).standardizedFileURL }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private static let bytesSourceIsReadable = bytesSourceURL() != nil

    /// A coarse guard over the code lines (a comment may mention the old text): the announcer must not key lost
    /// items by `String` or compare labels with `!=`, and must say how it keys and compares by bytes.
    @Test(.enabled(if: Self.bytesSourceIsReadable, "the announcer source is not next to the tests"))
    func theAnnouncerSourceKeysAndComparesByBytes() throws {
        let url = try #require(Self.bytesSourceURL(), "the announcer source is not next to the tests")
        let text = try String(contentsOf: url, encoding: .utf8)
        let code = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("//") }
        let stringKeyed = code.filter { $0.contains("[String: Int]") }
        let characterLabel = code.filter { $0.contains("label != ") }
        let byteKeys = code.filter { $0.contains("Array(item.utf8)") }
        let byteLabels = code.filter { $0.contains("utf8.elementsEqual") }
        #expect(stringKeyed.isEmpty)
        #expect(characterLabel.isEmpty)
        #expect(!byteKeys.isEmpty)
        #expect(!byteLabels.isEmpty)
    }
}
