// #64 E5b producer admission: one fan-in producer's E2 admission state (`lastAdmittedFrame`), advanced only by a
// successful push and reset on a timeline discontinuity, and the per-lane counts of its refusals. Reference model;
// not RT-certified.

/// One producer's admission state for a render `FanInHandoff<KernelEvent>`. Producer-owned: one value per producer
/// lane, never shared, mutated only by that producer. Every call is bounded and non-throwing.
///
/// - `push` first applies `DeadlinePolicy.admit` (`.beyondLookahead`, then `.nonMonotonic` against
///   `lastAdmittedFrame`) and returns a refusal without pushing; otherwise it returns the push's status. Only an
///   `.ok` push advances `lastAdmittedFrame`, so a refused or full push leaves it unchanged.
/// - `resetForDiscontinuity` forgets `lastAdmittedFrame` on a relocation or restart, so the producer may stamp
///   earlier frames again. Render orders by original frame, so such events are decided late (or dropped, for a
///   `noteOn` beyond tolerance), never re-queued.
/// - A refused event, a `noteOff` included, is returned to the producer, never dropped silently: the producer still
///   owns it and re-stamps it at or after `lastAdmittedFrame` (and within the lookahead) or resets first. An
///   admission refusal never raises a fault; it is counted on the token's lane in `refusals`
///   (`KernelCycle.admissionRefusals`), which render publishes as telemetry totals.
///
/// Reference model; not RT-certified.
struct ProducerAdmission: Sendable {
    let deadline: DeadlinePolicy
    /// Where admission refusals are counted.
    let refusals: KernelAdmissionRefusals
    /// The frame of this producer's last `.ok` push since the last discontinuity; `nil` before any or after a reset.
    private(set) var lastAdmittedFrame: Int64?

    init(deadline: DeadlinePolicy, refusals: KernelAdmissionRefusals) {
        self.deadline = deadline
        self.refusals = refusals
    }

    /// Producer only. Admits `event` at `now`, then pushes it on `token`'s lane of `events`.
    mutating func push(_ event: KernelEvent, now: Int64, into events: FanInHandoff<KernelEvent>,
                       token: ProducerToken) -> KernelStatus {
        let admitted = deadline.admit(eventFrame: event.frame, now: now, lastAdmittedFrame: lastAdmittedFrame)
        guard admitted == .ok else {
            refusals.record(admitted, token: token)
            return admitted
        }
        let status = events.tryPush(event, class: event.eventClass, frame: event.frame, token: token)
        if status == .ok { lastAdmittedFrame = event.frame }
        return status
    }

    /// Producer only. A timeline discontinuity: the next push is checked against the lookahead only.
    mutating func resetForDiscontinuity() {
        lastAdmittedFrame = nil
    }
}

/// Saturating per-lane counts of admission refusals (`.nonMonotonic`, `.beyondLookahead`) for one render fan-in,
/// in `FanInRefusalCounter`s allocated in `init`. Producers count through `ProducerAdmission`; render reads the
/// totals into `KernelCycleTelemetry`; anyone may read a lane. A refusal on a token of another handoff, or a lane
/// out of range, is counted in `unattributed`. Each counter keeps `FanInRefusalCounter`'s caller contract (a stale
/// token may count on a lane its old producer released). Reference model; not RT-certified.
final class KernelAdmissionRefusals: @unchecked Sendable {
    enum Kind: Int, Sendable {
        case nonMonotonic = 0, beyondLookahead = 1
    }

    /// Counters per lane, one per `Kind`.
    private static let kindCount = 2

    let laneCount: Int
    /// The identity of the fan-in whose tokens are counted per lane.
    let handoff: UInt64
    /// `laneCount * 2` counters: lane `l`'s kind `k` at `l * 2 + k`.
    private let counters: UnsafeMutablePointer<FanInRefusalCounter>
    private let foreign = FanInRefusalCounter()

    init(laneCount: Int, handoff: UInt64) {
        self.laneCount = laneCount
        self.handoff = handoff
        let slots = laneCount &* Self.kindCount
        counters = .allocate(capacity: slots)
        for slot in 0..<slots { (counters + slot).initialize(to: FanInRefusalCounter()) }
    }

    deinit {
        counters.deinitialize(count: laneCount &* Self.kindCount)
        counters.deallocate()
    }

    /// Producer only. Counts an admission refusal on `token`'s lane; any other status counts nothing.
    func record(_ status: KernelStatus, token: ProducerToken) {
        let kind: Kind
        switch status {
        case .refused(.nonMonotonic): kind = .nonMonotonic
        case .refused(.beyondLookahead): kind = .beyondLookahead
        default: return
        }
        let lane = Int(token.lane)
        guard token.handoff == handoff, lane < laneCount else { return foreign.bump() }
        counters[Self.slot(lane, kind)].bump()
    }

    /// `lane`'s count of `kind`, or `nil` when `lane` is out of range.
    func count(lane: Int, _ kind: Kind) -> UInt64? {
        guard lane >= 0, lane < laneCount else { return nil }
        return counters[Self.slot(lane, kind)].count
    }

    /// Refusals on tokens of another handoff or out-of-range lanes, any kind.
    var unattributed: UInt64 { foreign.count }

    /// Every lane's count of `kind`, saturating at `UInt64.max`. O(`laneCount`).
    func total(_ kind: Kind) -> UInt64 {
        var sum: UInt64 = 0
        for lane in 0..<laneCount {
            let (next, overflow) = sum.addingReportingOverflow(counters[Self.slot(lane, kind)].count)
            sum = overflow ? .max : next
        }
        return sum
    }

    private static func slot(_ lane: Int, _ kind: Kind) -> Int { lane &* Self.kindCount &+ kind.rawValue }
}
