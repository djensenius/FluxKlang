extension EncoderProfile {
    /// How many distinct positions the control can show: the grid its feedback is compared on, so two positions are
    /// equal when they land on the same step. An absolute control has `resolution` raw values (read back as
    /// `raw / (resolution - 1)`). A relative encoder reports no position, so its declared width stands in for what its
    /// ring can express.
    var feedbackGrid: Int {
        switch self {
        case .absolute(let resolution): resolution
        case .binaryOffset(let width), .twosComplement(let width), .signMagnitude(let width): width.valueCount
        }
    }
}

/// What ONE controller was just sent and just caused, kept as two small rings so an equal value arriving inside the
/// window is recognised as an echo instead of a new intent. Positions are stored as steps on the control's grid and
/// compared as integers, never as `Double`s: an encoder that reads a position back must round it exactly like
/// `step(of:grid:)` on `EncoderProfile.feedbackGrid` steps, or its echo will not match the message it answers.
///
/// Bounded: each ring holds at most `depth` entries; recording drops expired entries first, then the oldest if the ring
/// is still full. A planner keeps one ledger per tracked binding, so its total is at most `bindingCapacity * 2 * depth`
/// = `bindingCapacity * 16` entries (65,536 at the 4096 maximum). An entry made at tick `T` with window `W` is live
/// while `now <= T + W` (saturating at `UInt64.max`) and expired from `T + W + 1`. The planner records `sent` entries
/// only while fewer than `emitBudget` (at most `depth`) are live, so a live `sent` entry is never evicted; `caused`
/// entries are advisory and the oldest may be replaced. The ledger has no clock of its own: the planner passes every
/// tick.
struct ControlFeedbackEcho: Hashable, Sendable {
    static let depth = 8

    /// A remembered position (a step on the control's grid) and the last tick it still counts for.
    struct Entry: Hashable, Sendable {
        let step: Int
        let deadline: UInt64
    }

    private var sentEntries: [Entry] = []
    private var causedEntries: [Entry] = []

    /// Positions the controller was sent, oldest first.
    var sent: [Entry] { sentEntries }
    /// Positions the controller moved to itself, oldest first.
    var caused: [Entry] { causedEntries }

    /// The grid step a position lands on: `round(position * (grid - 1))`, ties away from zero. `nil` for a position
    /// that is not finite or not in 0...1 and for a grid below 2, so no position is ever guessed.
    static func step(of position: Double, grid: Int) -> Int? {
        guard position.isFinite, (0...1).contains(position), grid >= 2 else { return nil }
        return Int(exactly: (position * Double(grid - 1)).rounded())
    }

    /// The last tick an entry made at `now` still counts for: `now + window`, saturating at `UInt64.max`.
    static func deadline(from now: UInt64, window: UInt64) -> UInt64 {
        let (sum, overflow) = now.addingReportingOverflow(window)
        return overflow ? UInt64.max : sum
    }

    /// The first tick after `tick`, saturating at `UInt64.max`.
    static func following(_ tick: UInt64) -> UInt64 {
        deadline(from: tick, window: 1)
    }

    /// Remembers that the controller was sent `step`.
    mutating func recordSent(step: Int, now: UInt64, window: UInt64) {
        Self.append(Entry(step: step, deadline: Self.deadline(from: now, window: window)), to: &sentEntries, now: now)
    }

    /// Remembers that the controller itself moved to `step`.
    mutating func recordCaused(step: Int, now: UInt64, window: UInt64) {
        Self.append(Entry(step: step, deadline: Self.deadline(from: now, window: window)), to: &causedEntries, now: now)
    }

    /// Whether the controller was sent `step` and the entry is still live: an inbound equal value is its echo.
    func isSent(step: Int, at now: UInt64) -> Bool {
        sentEntries.contains { $0.step == step && now <= $0.deadline }
    }

    /// The latest deadline among live entries where the controller itself moved to `step`, or `nil`: a host value equal
    /// to it is the controller's own move coming back.
    func causedDeadline(of step: Int, at now: UInt64) -> UInt64? {
        causedEntries.filter { $0.step == step && now <= $0.deadline }.map(\.deadline).max()
    }

    /// `nil` while fewer than `budget` sent entries are live (a send may go out now); otherwise the first tick at which
    /// the live count falls below `budget`. A budget below 1 is treated as 1 (the policy never allows it).
    func sendableAt(budget: Int, now: UInt64) -> UInt64? {
        let live = sentEntries.filter { now <= $0.deadline }.map(\.deadline).sorted()
        let slots = max(budget, 1)
        guard live.count >= slots else { return nil }
        return Self.following(live[live.count - slots])
    }

    /// Drops expired entries, then the oldest one if the ring is still full, and appends `entry`.
    private static func append(_ entry: Entry, to ring: inout [Entry], now: UInt64) {
        ring.removeAll { $0.deadline < now }
        if ring.count == depth { ring.removeFirst() }
        ring.append(entry)
    }
}
