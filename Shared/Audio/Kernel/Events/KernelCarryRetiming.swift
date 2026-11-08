// #364 E5c kernel cycle component: re-times a retiring cycle's carried stateful events into a replacement cycle.
// Pure; control side (it allocates). Reference model; not RT-certified.

/// How many carried events each lane of the replacement may take. Only `state` (`control`, `program`) and `content`
/// (`rampTo`) lanes are ever carried, so `release` and `transport` have no room. A negative count is no room (0).
struct KernelCarryLaneCapacity: Sendable, Equatable {
    let state: Int
    let content: Int

    init(state: Int, content: Int) {
        self.state = max(0, state)
        self.content = max(0, content)
    }

    /// Room for `lane`.
    func room(for lane: EventLane) -> Int {
        switch lane {
        case .release, .transport: 0
        case .state: state
        case .content: content
        }
    }
}

/// One carried event as the replacement should receive it. Reference model; not RT-certified.
struct KernelCarryEmission: Sendable, Equatable {
    /// The event with its frame re-timed: `max(originalFrame, replacementFirstFrame)`.
    let event: KernelEvent
    /// The frame the retired cycle recorded.
    let originalFrame: Int64
    /// For a `rampTo`, `event.frame + durationFrames` (the carried ramp restarts with its full duration).
    let completionFrame: Int64?
}

/// The result of planning a carry. `dropped` counts, by kind, what the replacement's lane or block capacity could not
/// take (loss); `superseded` counts earlier writers of a key a later one replaced (not loss); `droppedAtRecord` is
/// the carry's `droppedForCapacity` (events that never fit the carry; their kind is not recorded).
/// Reference model; not RT-certified.
struct KernelCarryPlan: Sendable, Equatable {
    /// In delivery order: (frame, lane rank, original sequence, recorded index).
    let emissions: [KernelCarryEmission]
    let dropped: KernelRetirementLoss
    let superseded: Int
    let droppedAtRecord: Int
}

/// Plans how a `KernelRetirementCarry` enters a replacement cycle. Pure: no clock, no threads, no state; the carry is
/// taken by value.
/// O(n) passes over the n <= `KernelRetirementCarry.capacity` carried events plus one O(n log n) sort.
///
/// Rules:
/// - Supersede: per key the last recorded event wins (not the highest sequence). A key is the event's scope plus
///   (channel, controller) for a control, (channel) for a program or (parameter) for a rampTo, so events of
///   different scopes never supersede each other. Superseded events are counted in `superseded`, not as loss.
/// - Invalid ramps: every recorded rampTo is checked, superseded ones too; the lowest invalid parameter is refused.
///   A completion overflow (`frameOverflow`) is checked on surviving ramps only; no other frame arithmetic is done.
/// - Re-timing: each survivor moves to `max(frame, replacementFirstFrame)`; a carried rampTo restarts with its full
///   duration, so its completion frame is the re-timed frame plus the duration.
/// - Order: (re-timed frame, lane rank release < transport < state < content, original sequence, recorded index).
/// - Drops: the lane cut runs first, then the block cut; the earliest events in delivery order are kept and every
///   dropped one is counted by kind in `dropped` (loss).
/// Reference model; not RT-certified.
enum KernelCarryRetiming {
    private enum Key: Hashable {
        case control(scope: UInt32, channel: UInt8, controller: UInt8)
        case program(scope: UInt32, channel: UInt8)
        case ramp(scope: UInt32, parameter: UInt32)
    }

    /// Plans `carry` for a replacement of `replacementBlockCapacity` events whose first frame is
    /// `replacementFirstFrame`, refusing in the order documented on `KernelCarryRefusal`. An empty carry plans to an
    /// empty plan for any valid capacity and any non-negative first frame. The only `frameOverflow` is a surviving
    /// ramp whose completion overflows `Int64`; the replacement block's frame span is not known here (it is passed to
    /// `KernelCycle.run` per block), so no block end is checked.
    static func plan(
        carry: KernelRetirementCarry,
        replacementBlockCapacity: Int,
        replacementFirstFrame: Int64,
        replacementLaneCapacity: KernelCarryLaneCapacity
    ) throws(KernelCarryRefusal) -> KernelCarryPlan {
        guard (1...KernelCycle.maximumBlockCapacity).contains(replacementBlockCapacity) else {
            throw .blockCapacityOutOfRange(replacementBlockCapacity)
        }
        guard replacementFirstFrame >= 0 else { throw .negativeFrame(replacementFirstFrame) }
        if let parameter = lowestInvalidRamp(in: carry) { throw .invalidRamp(parameter: parameter) }
        let (survivors, superseded) = survivors(of: carry)
        let ordered = try retimed(survivors, firstFrame: replacementFirstFrame)
        var dropped = KernelRetirementLoss()
        var kept: [KernelCarryEmission] = []
        var used = [Int](repeating: 0, count: 4)
        for emission in ordered {
            let lane = emission.event.lane
            if used[Int(lane.rawValue)] < replacementLaneCapacity.room(for: lane),
               kept.count < replacementBlockCapacity {
                used[Int(lane.rawValue)] += 1
                kept.append(emission)
            } else {
                dropped.drop(emission.event.payload)
            }
        }
        return KernelCarryPlan(
            emissions: kept, dropped: dropped, superseded: superseded, droppedAtRecord: carry.droppedForCapacity
        )
    }

    /// The lowest parameter among every recorded ramp (superseded ones too) with a negative duration or a value that
    /// is not finite.
    private static func lowestInvalidRamp(in carry: KernelRetirementCarry) -> UInt32? {
        var lowest: UInt32?
        for event in carry.events {
            guard case let .rampTo(parameter, value, duration) = event.payload,
                  duration < 0 || !value.isFinite else { continue }
            lowest = min(lowest ?? parameter, parameter)
        }
        return lowest
    }

    private static func key(of event: KernelEvent) -> Key? {
        let scope = event.scope
        return switch event.payload {
        case let .control(channel, controller, _): .control(scope: scope, channel: channel, controller: controller)
        case let .program(channel, _, _): .program(scope: scope, channel: channel)
        case let .rampTo(parameter, _, _): .ramp(scope: scope, parameter: parameter)
        case .noteOn, .noteOff, .clockPulse: nil
        }
    }

    /// The last recorded event of each key, in recorded order, and how many earlier ones they replaced.
    private static func survivors(of carry: KernelRetirementCarry) -> ([(index: Int, event: KernelEvent)], Int) {
        var seen = Set<Key>()
        var reversed: [(index: Int, event: KernelEvent)] = []
        var superseded = 0
        for index in stride(from: carry.count - 1, through: 0, by: -1) {
            guard let event = carry.event(at: index), let key = key(of: event) else { continue }
            if seen.insert(key).inserted { reversed.append((index, event)) } else { superseded += 1 }
        }
        return (reversed.reversed(), superseded)
    }

    /// Re-times to `firstFrame`, checks every ramp completion for overflow and sorts into delivery order.
    private static func retimed(
        _ survivors: [(index: Int, event: KernelEvent)],
        firstFrame: Int64
    ) throws(KernelCarryRefusal) -> [KernelCarryEmission] {
        var items: [(index: Int, emission: KernelCarryEmission)] = []
        for (index, event) in survivors {
            let frame = max(event.frame, firstFrame)
            var completion: Int64?
            if case let .rampTo(_, _, duration) = event.payload {
                let sum = frame.addingReportingOverflow(duration)
                guard !sum.overflow else { throw .frameOverflow }
                completion = sum.partialValue
            }
            let moved = KernelEvent(frame: frame, scope: event.scope, sequence: event.sequence, payload: event.payload)
            let emission = KernelCarryEmission(event: moved, originalFrame: event.frame, completionFrame: completion)
            items.append((index, emission))
        }
        items.sort { precedes($0.emission.event, $0.index, $1.emission.event, $1.index) }
        return items.map(\.emission)
    }

    /// Strict (frame, lane rank, sequence, recorded index) order, a total order over one carry.
    private static func precedes(_ lhs: KernelEvent, _ leftIndex: Int, _ rhs: KernelEvent, _ rightIndex: Int) -> Bool {
        if lhs.frame != rhs.frame { return lhs.frame < rhs.frame }
        if lhs.lane != rhs.lane { return lhs.lane < rhs.lane }
        if lhs.sequence != rhs.sequence { return lhs.sequence < rhs.sequence }
        return leftIndex < rightIndex
    }
}
