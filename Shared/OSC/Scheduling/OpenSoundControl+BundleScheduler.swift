//
//  OpenSoundControl+BundleScheduler.swift
//  FluxKlang
//
//  The bounded, pure control-plane OSC scheduler (#90): atomic admission of
//  allowed batches, deterministic order, cancellation, draining, and
//  re-resolution when the injected wall-to-host mapping changes. Nothing is
//  dispatched or read from a clock here; every "now" and mapping is injected.
//

extension OpenSoundControl {
    /// Scheduler-minted batch identity, never reused by that scheduler.
    struct BatchID: Sendable, Hashable, CustomStringConvertible {
        private(set) var value: UInt64

        fileprivate init(value: UInt64) {
            self.value = value
        }

        var description: String { "batch-\(value)" }
    }

    /// Host ticks `[earliest, latest]` that contain the instant a time tag names,
    /// never narrower than the inputs justify: the checked bounds intersected with
    /// the representable ticks `0...UInt64.max`, outside which no host tick exists.
    /// Only this file constructs one.
    struct HostWindow: Sendable, Hashable {
        private(set) var earliest: HostStamp
        private(set) var latest: HostStamp

        /// `earliest ≤ latest` holds for every `hostBounds` result (its width is at
        /// least one quantum's scale), so only representability is checked.
        fileprivate init(earliest: Int128, latest: Int128, timeTag: TimeTag) throws(SchedulingRefusal) {
            guard latest >= 0, earliest <= Int128(UInt64.max) else { throw .hostTimeOutOfRange(timeTag) }
            self.earliest = HostStamp(ticks: UInt64(max(earliest, 0)))
            self.latest = HostStamp(ticks: UInt64(min(latest, Int128(UInt64.max))))
        }

        /// The admission instant of a batch that dispatches at once.
        fileprivate init(instant: HostStamp) {
            earliest = instant
            latest = instant
        }
    }

    enum ScheduleTiming: Sendable, Hashable {
        /// The window had not closed at the evaluation instant.
        case onTime
        /// The window closed this many host ticks before the evaluation instant:
        /// a lower bound on the lateness, never an estimate.
        case late(by: UInt64) // swiftlint:disable:this identifier_name
    }

    /// A timed bundle's era-resolved instant and checked host window.
    struct ResolvedTime: Sendable, Hashable {
        private(set) var timeTag: TimeTag
        private(set) var wall: WallInstant
        private(set) var window: HostWindow

        fileprivate init(timeTag: TimeTag, wall: WallInstant, window: HostWindow) {
            self.timeTag = timeTag
            self.wall = wall
            self.window = window
        }
    }

    struct ScheduledBatch: Sendable, Hashable {
        fileprivate(set) var id: BatchID
        /// Admission sequence of the packet this batch came from.
        fileprivate(set) var arrival: UInt64
        fileprivate(set) var bundleIndex: Int
        /// The bundle's own tag, the enclosing bundle's tag for an immediate
        /// inner bundle, or `.immediate` for a batch that dispatches at once.
        fileprivate(set) var timeTag: TimeTag
        /// The era-resolved instant; nil for a batch that dispatches at once.
        fileprivate(set) var wall: WallInstant?
        fileprivate(set) var window: HostWindow
        fileprivate(set) var timing: ScheduleTiming
        fileprivate(set) var messages: [Message]

        fileprivate init(id: BatchID, arrival: UInt64, plan: PlannedBatch, now: HostStamp) {
            self.id = id
            self.arrival = arrival
            bundleIndex = plan.bundleIndex
            timeTag = plan.time?.timeTag ?? .immediate
            wall = plan.time?.wall
            window = plan.time?.window ?? HostWindow(instant: now)
            timing = BundleScheduler.timing(of: window, now: now)
            self.messages = plan.messages
        }
    }

    /// A pending batch removed with a typed refusal instead of being dropped silently.
    struct RefusedBatch: Sendable, Hashable {
        fileprivate(set) var batch: ScheduledBatch
        fileprivate(set) var refusal: SchedulingRefusal

        fileprivate init(batch: ScheduledBatch, refusal: SchedulingRefusal) {
            self.batch = batch
            self.refusal = refusal
        }
    }

    struct BatchMove: Sendable, Hashable {
        fileprivate(set) var id: BatchID
        fileprivate(set) var from: HostWindow
        fileprivate(set) var to: HostWindow

        fileprivate init(id: BatchID, from: HostWindow, to: HostWindow) {
            self.id = id
            self.from = from
            self.to = to
        }
    }

    /// Evidence of one mapping change: every surviving batch's old and new window
    /// (in the previous pending order) and every batch the change refused.
    struct ClockShift: Sendable, Hashable {
        fileprivate(set) var previous: WallClockMapping
        fileprivate(set) var current: WallClockMapping
        /// The injected host time the change took effect.
        fileprivate(set) var now: HostStamp
        fileprivate(set) var moves: [BatchMove] = []
        fileprivate(set) var refused: [RefusedBatch] = []

        fileprivate init(previous: WallClockMapping, current: WallClockMapping, now: HostStamp) {
            self.previous = previous
            self.current = current
            self.now = now
        }
    }

    struct DueBatches: Sendable, Hashable {
        /// Batches to hand on, in dispatch order, each all-or-nothing.
        fileprivate(set) var dispatch: [ScheduledBatch] = []
        /// Batches whose window closed more than the late horizon ago.
        fileprivate(set) var refused: [RefusedBatch] = []

        fileprivate init() {}
    }

    /// Pending batches are ordered by earliest host tick; within a tick an
    /// immediate batch precedes a timed one, timed batches follow their wall
    /// instants, and remaining ties fall to packet arrival, then bundle pre-order
    /// index. (arrival, bundle index) is unique, so the order is total.
    ///
    /// Horizons are applied at admission and again on every `due` and every
    /// mapping change, against that call's `now`. An immediate batch's window is
    /// its admission tick, so a driver must call `due` well inside the late
    /// horizon or such batches come back refused as `.tooLate`.
    struct BundleScheduler: Sendable, Hashable {
        private(set) var timebase: HostTimebase
        private(set) var mapping: WallClockMapping
        private(set) var policy: SchedulingPolicy
        private(set) var allowList: AllowList
        private(set) var pending: [ScheduledBatch]
        private(set) var pendingMessageCount: Int
        /// The latest injected host time; earlier ones are refused.
        private(set) var latestNow: HostStamp?
        private(set) var lastClockShift: ClockShift?
        private var nextArrival: UInt64
        private var nextBatch: UInt64

        init(
            timebase: HostTimebase, mapping: WallClockMapping, policy: SchedulingPolicy, allowList: AllowList
        ) throws(SchedulingRefusal) {
            guard timebase.numer > 0, timebase.denom > 0 else {
                throw .invalidTimebase(numer: timebase.numer, denom: timebase.denom)
            }
            self.timebase = timebase
            self.mapping = mapping
            self.policy = policy
            self.allowList = allowList
            pending = []
            pendingMessageCount = 0
            latestNow = nil
            lastClockShift = nil
            nextArrival = 0
            nextBatch = 0
        }

        /// Admits the whole packet or refuses it unchanged. Returns the new batches
        /// in pre-order; a packet without messages admits nothing but its arrival.
        /// The planner refuses at the first batch or message past the room the
        /// pending capacities leave, before storing it.
        mutating func admit(_ packet: Packet, now: HostStamp) throws(SchedulingRefusal) -> [ScheduledBatch] {
            try requireMonotonic(now)
            let current = self
            let budget = PlanningBudget(
                batches: policy.maximumPendingBatches - pending.count, batchLimit: policy.maximumPendingBatches,
                messages: policy.maximumPendingMessages - pendingMessageCount,
                messageLimit: policy.maximumPendingMessages
            )
            let plans = try BundlePlanner.plan(
                packet, allowList: allowList, maximumBundleDepth: policy.maximumBundleDepth, budget: budget
            ) { timeTag throws(SchedulingRefusal) in
                try current.resolve(timeTag, mapping: current.mapping, now: now)
            }
            let messageCount = plans.reduce(0) { $0 + $1.messages.count }
            let (arrivalAfter, arrivalOverflow) = nextArrival.addingReportingOverflow(1)
            let (batchAfter, batchOverflow) = nextBatch.addingReportingOverflow(UInt64(plans.count))
            guard !arrivalOverflow, !batchOverflow else { throw .arithmeticOverflow }
            let admitted = plans.enumerated().map { offset, plan in
                let id = BatchID(value: nextBatch + UInt64(offset))
                return ScheduledBatch(id: id, arrival: nextArrival, plan: plan, now: now)
            }
            pending = Self.ordered(pending + admitted)
            pendingMessageCount += messageCount
            nextArrival = arrivalAfter
            nextBatch = batchAfter
            latestNow = now
            return admitted
        }

        /// Removes a pending batch; anything not pending is refused.
        mutating func cancel(_ id: BatchID) throws(SchedulingRefusal) -> ScheduledBatch {
            guard let index = pending.firstIndex(where: { $0.id == id }) else { throw .batchNotPending(id) }
            let batch = pending.remove(at: index)
            pendingMessageCount -= batch.messages.count
            return batch
        }

        /// Removes and returns every batch whose window has opened (`earliest ≤ now`),
        /// with timing as of `now`; those past the late horizon come back refused.
        mutating func due(now: HostStamp) throws(SchedulingRefusal) -> DueBatches {
            try requireMonotonic(now)
            var result = DueBatches()
            var kept: [ScheduledBatch] = []
            for batch in pending {
                guard batch.window.earliest.ticks <= now.ticks else {
                    kept.append(batch)
                    continue
                }
                do throws(SchedulingRefusal) {
                    try checkHorizons(of: batch.window, timeTag: batch.timeTag, now: now)
                    var ready = batch
                    ready.timing = Self.timing(of: batch.window, now: now)
                    result.dispatch.append(ready)
                } catch {
                    result.refused.append(RefusedBatch(batch: batch, refusal: error))
                }
            }
            commit(kept, now: now)
            return result
        }

        /// Adopts `next` and places every timed batch's admitted wall instant on it
        /// (its era and instant never change). Batches now out of bounds come back
        /// refused; the rest re-sort by the usual order, which a monotonic mapping
        /// cannot invert among timed batches.
        mutating func updateMapping(_ next: WallClockMapping, now: HostStamp) throws(SchedulingRefusal) -> ClockShift {
            try requireMonotonic(now)
            var shift = ClockShift(previous: mapping, current: next, now: now)
            var survivors: [ScheduledBatch] = []
            for batch in pending {
                do throws(SchedulingRefusal) {
                    let moved = try reresolve(batch, mapping: next, now: now)
                    survivors.append(moved)
                    shift.moves.append(BatchMove(id: batch.id, from: batch.window, to: moved.window))
                } catch {
                    shift.refused.append(RefusedBatch(batch: batch, refusal: error))
                }
            }
            mapping = next
            lastClockShift = shift
            commit(Self.ordered(survivors), now: now)
            return shift
        }

        static func timing(of window: HostWindow, now: HostStamp) -> ScheduleTiming {
            window.latest.ticks < now.ticks ? .late(by: now.ticks - window.latest.ticks) : .onTime
        }

        private static func ordered(_ batches: [ScheduledBatch]) -> [ScheduledBatch] {
            batches.sorted { lhs, rhs in
                if lhs.window.earliest.ticks != rhs.window.earliest.ticks {
                    return lhs.window.earliest.ticks < rhs.window.earliest.ticks
                }
                switch (lhs.wall, rhs.wall) {
                case (nil, .some): return true
                case (.some, nil): return false
                case let (.some(left), .some(right)) where left != right: return left < right
                default: break
                }
                if lhs.arrival != rhs.arrival { return lhs.arrival < rhs.arrival }
                return lhs.bundleIndex < rhs.bundleIndex
            }
        }

        private mutating func commit(_ batches: [ScheduledBatch], now: HostStamp) {
            pending = batches
            pendingMessageCount = batches.reduce(0) { $0 + $1.messages.count }
            latestNow = now
        }

        private func requireMonotonic(_ now: HostStamp) throws(SchedulingRefusal) {
            if let latestNow, now.ticks < latestNow.ticks { throw .nowRegressed(previous: latestNow, now: now) }
        }

        private func resolve(
            _ timeTag: TimeTag, mapping: WallClockMapping, now: HostStamp
        ) throws(SchedulingRefusal) -> ResolvedTime {
            let wall = try mapping.wall.resolve(timeTag)
            let window = try place(wall, timeTag: timeTag, mapping: mapping, now: now)
            return ResolvedTime(timeTag: timeTag, wall: wall, window: window)
        }

        private func place(
            _ wall: WallInstant, timeTag: TimeTag, mapping: WallClockMapping, now: HostStamp
        ) throws(SchedulingRefusal) -> HostWindow {
            let bounds = try mapping.hostBounds(of: wall, timebase: timebase)
            try checkHorizons(earliest: bounds.earliest, latest: bounds.latest, timeTag: timeTag, now: now)
            return try HostWindow(earliest: bounds.earliest, latest: bounds.latest, timeTag: timeTag)
        }

        private func reresolve(
            _ batch: ScheduledBatch, mapping: WallClockMapping, now: HostStamp
        ) throws(SchedulingRefusal) -> ScheduledBatch {
            var moved = batch
            if let wall = batch.wall {
                moved.window = try place(wall, timeTag: batch.timeTag, mapping: mapping, now: now)
            } else {
                try checkHorizons(of: batch.window, timeTag: batch.timeTag, now: now)
            }
            moved.timing = Self.timing(of: moved.window, now: now)
            return moved
        }

        private func checkHorizons(of window: HostWindow, timeTag: TimeTag, now: HostStamp) throws(SchedulingRefusal) {
            try checkHorizons(
                earliest: Int128(window.earliest.ticks), latest: Int128(window.latest.ticks), timeTag: timeTag, now: now
            )
        }

        /// Exact: ticks · numer / denom nanoseconds, so `Δticks · numer > horizon · denom`
        /// is the comparison, with no rounding of either side.
        private func checkHorizons(
            earliest: Int128, latest: Int128, timeTag: TimeTag, now: HostStamp
        ) throws(SchedulingRefusal) {
            let current = Int128(now.ticks)
            let numer = Int128(timebase.numer)
            let denom = Int128(timebase.denom)
            if latest < current {
                let lateness = try CheckedInt128.multiply(CheckedInt128.subtract(current, latest), numer)
                let horizon = try CheckedInt128.multiply(Int128(policy.lateHorizonNanoseconds), denom)
                guard lateness <= horizon else { throw .tooLate(timeTag) }
            }
            if earliest > current {
                let lead = try CheckedInt128.multiply(CheckedInt128.subtract(earliest, current), numer)
                let horizon = try CheckedInt128.multiply(Int128(policy.maximumFutureNanoseconds), denom)
                guard lead <= horizon else { throw .tooFarInFuture(timeTag) }
            }
        }
    }
}
