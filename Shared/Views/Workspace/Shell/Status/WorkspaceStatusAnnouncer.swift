//
//  WorkspaceStatusAnnouncer.swift
//  FluxKlang
//
//  The announcer policy of the status strip (#99 W3): what VoiceOver is told,
//  once, and when. A new error is announced at once with high priority; routine
//  changes are polite and throttled per segment; an unchanged state is never
//  announced again. The announcer's memory is part of its value and the tick is
//  injected, so the policy is deterministic and testable without a clock.
//

/// How urgently an announcement is spoken.
enum WorkspaceStatusAnnouncementPriority: Hashable, Sendable {
    /// A new error such as Lost/Muted: announced once, at once.
    case high
    /// A routine change: announced politely, at most once per segment per throttle window.
    case polite
}

/// One thing to announce: the segment it belongs to, the full-sentence text and the priority.
struct WorkspaceStatusAnnouncement: Hashable, Sendable {
    let segment: WorkspaceStatusSegmentID
    /// The segment's accessibility label.
    let text: String
    let priority: WorkspaceStatusAnnouncementPriority

    fileprivate init(_ segment: WorkspaceStatusSegment, priority: WorkspaceStatusAnnouncementPriority) {
        self.segment = segment.id
        text = segment.label
        self.priority = priority
    }
}

/// Decides which segment changes to announce. Per segment it remembers the last state it saw, the last state
/// it announced and the tick of that announcement; a refused call leaves all of it unchanged.
///
/// The announcer has no timer. A routine change inside the throttle window is HELD, and it is spoken only by a
/// LATER call of `announcements(previous:current:tick:)` made at or after `nextDueTick(for:)`; a caller that
/// calls only when the projection changes therefore never says "error cleared". Poll `pendingSegments` from
/// the caller's own scheduler and, at the due tick, call again with the latest projection as both `previous`
/// and `current`.
struct WorkspaceStatusAnnouncer: Hashable, Sendable {
    /// A routine change is announced at most once per segment in this many ticks: at a distance of 3 it is
    /// held, at 4 it is announced.
    static let throttleTicks: UInt64 = 4

    private struct Memory: Hashable, Sendable {
        /// The last state seen, announced or not.
        var known: WorkspaceStatusSegment
        /// The last state announced.
        var announced: WorkspaceStatusSegment
        var announcedTick: UInt64?

        init(seededFrom segment: WorkspaceStatusSegment) {
            known = segment
            announced = segment
            announcedTick = nil
        }

        /// True while the last state seen says something the last announced state did not: a held change.
        var isPending: Bool { WorkspaceStatusAnnouncer.differs(known, from: announced) }

        /// Decides what to announce for `now`, records the decision and moves `known` to `now`.
        mutating func advance(to now: WorkspaceStatusSegment, tick: UInt64) -> WorkspaceStatusAnnouncementPriority? {
            defer { known = now }
            if WorkspaceStatusAnnouncer.isNewError(from: known, to: now) {
                record(now, at: tick)
                return .high
            }
            guard WorkspaceStatusAnnouncer.differs(now, from: announced), isDue(at: tick) else { return nil }
            record(now, at: tick)
            return .polite
        }

        private mutating func record(_ segment: WorkspaceStatusSegment, at tick: UInt64) {
            announced = segment
            announcedTick = tick
        }

        /// True if nothing was announced yet or `tick` has reached the due tick of the last announcement. The
        /// due tick saturates at `UInt64.max`, so nothing is subtracted or overflows, and a call AT
        /// `UInt64.max` is always due.
        private func isDue(at tick: UInt64) -> Bool {
            guard let last = announcedTick else { return true }
            return tick >= WorkspaceStatusAnnouncer.dueTick(after: last)
        }
    }

    private var memory: [WorkspaceStatusSegmentID: Memory] = [:]
    /// The newest tick accepted, or nil before the first call. A call at `UInt64.max` is accepted; after it no
    /// smaller tick can be passed (ticks come from a session counter), and there is no separate refusal for it.
    private(set) var lastTick: UInt64?

    init() {}

    /// The tick at which `id` was last announced, or nil if it never was.
    func lastAnnouncedTick(for id: WorkspaceStatusSegmentID) -> UInt64? {
        memory[id]?.announcedTick
    }

    /// The segments with a held change, in segment order: the last state seen differs (label or lost items)
    /// from the last state announced. Empty before the first call, and again once the held change is spoken
    /// or reverts.
    var pendingSegments: [WorkspaceStatusSegmentID] {
        WorkspaceStatusSegmentID.allCases.filter { memory[$0]?.isPending ?? false }
    }

    /// The tick at which a call speaks the held change of `id`, or nil when nothing is pending for it: the
    /// tick of its last announcement plus `throttleTicks`, saturating at `UInt64.max`. A call at an earlier
    /// tick keeps holding it. A held change always follows an announcement, so the fallback to the newest
    /// accepted tick (a segment that was never announced is due at once) is total but cannot be reached
    /// through this API.
    func nextDueTick(for id: WorkspaceStatusSegmentID) -> UInt64? {
        guard let entry = memory[id], entry.isPending else { return nil }
        return entry.announcedTick.map(Self.dueTick(after:)) ?? lastTick
    }

    /// What to announce now that the strip went from `previous` to `current` at `tick`.
    ///
    /// A segment seen for the first time starts from its state in `previous`; afterwards the announcer's own
    /// memory decides and `previous` is not consulted. Every `.high` announcement comes first, then every
    /// `.polite` one, each in segment order. A tick smaller than the newest accepted tick is refused before
    /// anything changes; an equal tick is allowed, and so is `UInt64.max`, after which no smaller tick can be
    /// passed (ticks come from a session counter).
    ///
    /// A routine change inside the throttle window is held, and there is no timer: it is spoken only by a
    /// LATER call made at or after `nextDueTick(for:)`. A caller that calls only when the projection changes
    /// never says "error cleared"; it should poll `pendingSegments` and call again at the due tick with the
    /// latest projection as both `previous` and `current`.
    mutating func announcements(
        previous: WorkspaceStatusProjection, current: WorkspaceStatusProjection, tick: UInt64
    ) throws(WorkspaceStatusRefusal) -> [WorkspaceStatusAnnouncement] {
        if let last = lastTick, tick < last { throw .tickWentBackwards(last: last, found: tick) }
        var updated = memory
        var high: [WorkspaceStatusAnnouncement] = []
        var polite: [WorkspaceStatusAnnouncement] = []
        for id in WorkspaceStatusSegmentID.allCases {
            let now = current.segment(id)
            var entry = updated[id] ?? Memory(seededFrom: previous.segment(id))
            switch entry.advance(to: now, tick: tick) {
            case .high?: high.append(WorkspaceStatusAnnouncement(now, priority: .high))
            case .polite?: polite.append(WorkspaceStatusAnnouncement(now, priority: .polite))
            case nil: break
            }
            updated[id] = entry
        }
        memory = updated
        lastTick = tick
        return high + polite
    }

    /// A segment is a new error when it is in error now and either was not in error before or lists a lost
    /// item that it did not list before.
    fileprivate static func isNewError(from old: WorkspaceStatusSegment, to now: WorkspaceStatusSegment) -> Bool {
        guard now.severity == .error else { return false }
        return old.severity != .error || now.lostItems.contains { !old.lostItems.contains($0) }
    }

    /// Whether `now` says something `announced` did not: other words or other lost items. A different severity
    /// with the same words and lost items (`.connected` to `.synced`) is not a new thing to say.
    fileprivate static func differs(
        _ now: WorkspaceStatusSegment, from announced: WorkspaceStatusSegment
    ) -> Bool {
        now.label != announced.label || now.lostItems != announced.lostItems
    }

    /// The tick at which a change is due after an announcement at `tick`: `tick + throttleTicks`, saturating
    /// at `UInt64.max` so it never wraps. The throttle and `nextDueTick(for:)` both use it.
    fileprivate static func dueTick(after tick: UInt64) -> UInt64 {
        let (sum, overflow) = tick.addingReportingOverflow(throttleTicks)
        return overflow ? UInt64.max : sum
    }
}
