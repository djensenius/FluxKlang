/// The sources currently being touched. While a source is held nothing is sent to it: the planner answers `.hold` and
/// keeps owing the correction, so the newest host position goes out once, at release.
///
/// Bounded: at most `capacity` LIVE holds. A hold started at tick `T` with timeout `H` is live while `now <= T + H`
/// (saturating at `UInt64.max`) and expired from `T + H + 1`, a deliberately inclusive reading of "older than the
/// timeout". A full table refuses a NEW source and never evicts a live hold; expired holds are dropped only when a
/// successful touch changes the table. Like `ControlFeedbackEcho` it has no clock of its own: the planner passes every
/// tick and refuses regressions before it gets here.
struct ControlTouchHold: Hashable, Sendable {
    private let storedCapacity: Int
    private let storedTimeoutTicks: UInt64
    /// The last live tick of each touched source (expired entries stay until the next table change).
    private(set) var deadlines: [ControlSourceID: UInt64] = [:]

    var capacity: Int { storedCapacity }
    var timeoutTicks: UInt64 { storedTimeoutTicks }

    init(policy: ControlFeedbackPolicy) {
        storedCapacity = policy.holdCapacity
        storedTimeoutTicks = policy.holdTimeoutTicks
    }

    /// Whether `source` has a live hold at `now`.
    func isHeld(_ source: ControlSourceID, at now: UInt64) -> Bool {
        deadlines[source].map { now <= $0 } ?? false
    }

    /// How many holds are live at `now`.
    func liveCount(at now: UInt64) -> Int {
        deadlines.values.filter { now <= $0 }.count
    }

    /// Starts a hold. Returns `false` and changes nothing, not even the deadline, while the source is already held.
    /// A new source needs a free slot among the live holds, else `holdTableFull` is thrown and nothing changes.
    @discardableResult
    mutating func touch(_ source: ControlSourceID, now: UInt64) throws(ControlFeedbackRefusal) -> Bool {
        guard !isHeld(source, at: now) else { return false }
        guard liveCount(at: now) < capacity else { throw .holdTableFull(capacity: capacity) }
        deadlines = deadlines.filter { now <= $0.value }
        deadlines[source] = ControlFeedbackEcho.deadline(from: now, window: timeoutTicks)
        return true
    }

    /// Ends a hold and reports whether it was still live. An expired or absent hold reports `false`; an expired one is
    /// dropped on the way.
    @discardableResult
    mutating func release(_ source: ControlSourceID, at now: UInt64) -> Bool {
        guard let deadline = deadlines.removeValue(forKey: source) else { return false }
        return now <= deadline
    }
}
