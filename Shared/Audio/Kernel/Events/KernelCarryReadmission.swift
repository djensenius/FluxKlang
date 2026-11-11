import Synchronization

// #364 E5c, slice KCR1: re-admits the carry a `.replacingCycle` replacement inherited (`KernelRetirementCarry`) into
// its own emission. Control plans it in `init` (allocates); render only drains the prepared slots (no allocation, no
// lock, at most `capacity` slots per block). Reference model; not RT-certified.

/// What a replacement's re-admission has done so far. The plan fields are fixed at preparation; the render counts
/// are each read once (acquire) and only grow, so one report may mix two moments of render. Lost: `invalidRamps`,
/// `cut`, `droppedAtRecord`, `refused` and, once the cycle retired, `recarried` (counted again in that retirement's
/// loss). Not lost: `superseded`, `delivered`, `supersededByReplacement`. `pendingCarriedEvents` are neither yet.
/// Reference model; not RT-certified.
struct KernelCarryReadmissionReport: Sendable, Equatable {
    /// The planner refused the carry (only `.frameOverflow` can remain); nothing is re-admitted.
    let planRefusal: KernelCarryRefusal?
    /// Carried events placed in the re-admission slots, in delivery order.
    let planned: Int
    /// Carried ramps the planner refuses (negative duration or non-finite value), removed before planning.
    let invalidRamps: Int
    /// Survivors cut by the replacement's capacity, by kind (`KernelCarryPlan.dropped`).
    let cut: KernelRetirementLoss
    /// Earlier carried events of a key a later carried event replaced (`KernelCarryPlan.superseded`).
    let superseded: Int
    /// Events the retired cycle could not record (`KernelRetirementCarry.droppedForCapacity`; kind unknown).
    let droppedAtRecord: Int
    /// Carried events the replacement emitted.
    let delivered: Int
    /// Carried events discarded because the replacement's own events held later state for the same target: one it
    /// dispatched, or one still pending at its `retire()` (see the ordering rule on `KernelCarryReadmission`).
    let supersededByReplacement: Int
    /// Carried events the replacement could not apply (`RampSlots` refused a ramp).
    let refused: Int
    /// Carried events still pending at the replacement's `retire()` and not superseded there: counted in its loss and
    /// recorded into its carry after the replacement's own pending events, as far as the carry has room.
    let recarried: Int
    /// Planned carried events not yet delivered, refused, superseded or re-carried (render's count, acquire).
    let pendingCarriedEvents: Int
}

/// Carried stateful events a re-admission resolved, by kind (`KernelCarryReadmission.resolved()`).
struct KernelCarryResolution: Sendable, Equatable {
    let controls: Int
    let programs: Int
    let ramps: Int
}

/// The re-admission slots of one `KernelCycle`. Reference model; not RT-certified.
///
/// Preparation (`init`, control): ramps the planner refuses are removed, then `KernelCarryRetiming.plan` runs with
/// `replacementFirstFrame` 0 (the replacement's timeline is only known per block) and room for
/// `capacity = min(KernelRetirementCarry.capacity, blockCapacity)` events, so a block never re-admits more events than
/// its block buffer holds. Its emissions, in (frame, lane, sequence, recorded index) order, fill preallocated slots;
/// each slot also keeps its weight: itself plus the carried events of its key it superseded.
///
/// Render (`KernelBlockDecider.decide`): due slots are merged with the block buffer by original frame, a slot before
/// a buffered event of the same frame; each is decided by the deadline policy (an already-due event dispatches at
/// `blockStart`), applied and emitted like a drained one. Silenced cycles and `frames <= 0` re-admit nothing.
///
/// Ordering rule (timeline order): the replacement is transparent, so carried and own events apply in original-frame
/// order, as one cycle would have applied them. An own `control`, `program` or `rampTo` supersedes only pending slots
/// for the same target ((scope, channel, controller), (scope, channel) or parameter: `RampSlots` is shared by all
/// scopes) whose frame is at or before its own; a carried event stamped later is later state and is still delivered.
/// Within `decide` the merge already delivers every such slot first, so `supersede(by:)` is a guard there; it matters
/// at `retire(coveredBy:_:)`, where a pending slot covered by a pending own event (same target, own frame at or after
/// the slot's) is superseded instead of carried again, and the rest are carried after the own events.
///
/// Accounting: a delivered slot, or one superseded by the replacement, resolves its weight; `resolved()` feeds
/// `KernelCycle.unresolvedRetirementLoss`. A refused slot, a re-carried one and everything the plan dropped stay lost.
///
/// Bounds: `init` allocates the slots; render reads and writes only them, a head index, three pending-by-kind counts
/// and atomic counters (releasing adds): no allocation, no lock, no `Array`. Per block, `next`/`consumeNext` visit each
/// slot at most once over the cycle's life (at most `capacity`, 256); `supersede(by:)` returns at once for a
/// non-stateful event or a kind with no pending slot, and otherwise visits only pending slots up to the event's frame
/// (at most `capacity`), so a block of `n` own stateful events costs at most `n × capacity` slot visits (in practice
/// none: the merge has consumed them). `retire(coveredBy:_:)` passes the block buffer once to collect own kinds, then
/// for each pending slot of a kind the block holds scans the frame-ordered buffer from the end back to that slot's
/// frame: at most `capacity × blockCapacity` comparisons (256 × 4,096), once per cycle.
final class KernelCarryReadmission: @unchecked Sendable {
    private struct Slot {
        let event: KernelEvent
        let weight: Int
        var superseded = false
    }

    private enum PlanKey: Hashable {
        case control(UInt32, UInt8, UInt8)
        case program(UInt32, UInt8)
        case ramp(UInt32, UInt32)
    }

    /// Most events this replacement re-admits: `min(KernelRetirementCarry.capacity, blockCapacity)`.
    let capacity: Int
    private let planRefusal: KernelCarryRefusal?
    private let invalidRamps: Int
    private let cut: KernelRetirementLoss
    private let plannerSuperseded: Int
    private let droppedAtRecord: Int
    private let planned: Int
    private let slots: UnsafeMutablePointer<Slot>
    /// The first pending slot; render only.
    private let head: UnsafeMutablePointer<Int>
    /// Pending (not consumed, superseded or re-carried) slots by kind: control, program, ramp; render only.
    private let pendingByKind: UnsafeMutablePointer<Int>
    private let pendingTotal: Atomic<Int>
    private let delivered = Atomic<Int>(0)
    private let supersededByReplacement = Atomic<Int>(0)
    private let refused = Atomic<Int>(0)
    private let recarried = Atomic<Int>(0)
    private let resolvedControls = Atomic<Int>(0)
    private let resolvedPrograms = Atomic<Int>(0)
    private let resolvedRamps = Atomic<Int>(0)

    /// Control only (allocates): plans `carry` for a cycle of `blockCapacity` (`1...KernelCycle.maximumBlockCapacity`).
    init(carry: KernelRetirementCarry, blockCapacity: Int) {
        capacity = min(KernelRetirementCarry.capacity, max(1, blockCapacity))
        var valid = KernelRetirementCarry()
        var invalid = 0
        for event in carry.events {
            if case let .rampTo(_, value, duration) = event.payload, duration < 0 || !value.isFinite {
                invalid += 1
            } else {
                valid.record(event)
            }
        }
        var emissions: [KernelCarryEmission] = []
        var refusal: KernelCarryRefusal?
        var plan: KernelCarryPlan?
        do {
            plan = try KernelCarryRetiming.plan(
                carry: valid, replacementBlockCapacity: capacity, replacementFirstFrame: 0,
                replacementLaneCapacity: KernelCarryLaneCapacity(state: capacity, content: capacity))
            emissions = plan?.emissions ?? []
        } catch {
            refusal = error
        }
        planRefusal = refusal
        invalidRamps = invalid
        cut = plan?.dropped ?? KernelRetirementLoss()
        plannerSuperseded = plan?.superseded ?? 0
        droppedAtRecord = carry.droppedForCapacity
        var weights: [PlanKey: Int] = [:]
        for event in valid.events { if let key = Self.planKey(event) { weights[key, default: 0] += 1 } }
        planned = emissions.count
        slots = .allocate(capacity: max(1, emissions.count))
        for (index, emission) in emissions.enumerated() {
            let weight = Self.planKey(emission.event).flatMap { weights[$0] } ?? 1
            (slots + index).initialize(to: Slot(event: emission.event, weight: weight))
        }
        head = .allocate(capacity: 1)
        head.initialize(to: 0)
        pendingByKind = .allocate(capacity: 3)
        pendingByKind.initialize(repeating: 0, count: 3)
        for index in 0..<planned { if let kind = Self.kind(slots[index].event.payload) { pendingByKind[kind] += 1 } }
        pendingTotal = Atomic(planned)
    }

    /// Control-side teardown only.
    deinit {
        slots.deinitialize(count: planned)
        slots.deallocate()
        head.deallocate()
        pendingByKind.deallocate()
    }

    /// Any thread: the preparation outcome and render's counts so far (see `KernelCarryReadmissionReport`).
    var report: KernelCarryReadmissionReport {
        KernelCarryReadmissionReport(
            planRefusal: planRefusal, planned: planned, invalidRamps: invalidRamps, cut: cut,
            superseded: plannerSuperseded, droppedAtRecord: droppedAtRecord,
            delivered: delivered.load(ordering: .acquiring),
            supersededByReplacement: supersededByReplacement.load(ordering: .acquiring),
            refused: refused.load(ordering: .acquiring), recarried: recarried.load(ordering: .acquiring),
            pendingCarriedEvents: pendingTotal.load(ordering: .acquiring))
    }

    /// Any thread: carried `control`, `program` and `rampTo` events resolved so far (delivered or superseded by the
    /// replacement, with the carried events each one superseded).
    func resolved() -> KernelCarryResolution {
        KernelCarryResolution(controls: resolvedControls.load(ordering: .acquiring),
                              programs: resolvedPrograms.load(ordering: .acquiring),
                              ramps: resolvedRamps.load(ordering: .acquiring))
    }

    /// Render only: the next pending slot's event, skipping (and so dropping) slots already superseded; `nil` when
    /// none is pending.
    var next: KernelEvent? {
        while head.pointee < planned {
            if !slots[head.pointee].superseded { return slots[head.pointee].event }
            head.pointee &+= 1
        }
        return nil
    }

    /// Render only: removes the event `next` returned; `delivered` resolves it, otherwise it was refused (lost).
    /// Skips superseded slots first (through `next`), so a direct call never counts a slot twice.
    func consumeNext(delivered wasDelivered: Bool) {
        guard next != nil else { return }
        let slot = slots[head.pointee]
        head.pointee &+= 1
        leavePending(slot)
        if wasDelivered {
            delivered.add(1, ordering: .releasing)
            resolve(slot)
        } else {
            refused.add(1, ordering: .releasing)
        }
    }

    /// Render only, after the replacement's own lanes dispatched `event`: discards every pending slot for the same
    /// target at or before `event.frame` (see the type's ordering rule and Bounds).
    func supersede(by event: KernelEvent) {
        guard let kind = Self.kind(event.payload), pendingByKind[kind] > 0 else { return }
        var index = head.pointee
        while index < planned, slots[index].event.frame <= event.frame {
            if !slots[index].superseded, Self.sameTarget(slots[index].event, event) { discard(index) }
            index &+= 1
        }
    }

    /// Render only, from `KernelCycle.retire()` after it recorded `block`'s own pending events: supersedes every
    /// pending slot a pending own event covers (same target, own frame at or after the slot's), then passes each
    /// other pending slot's event to `body` in delivery order, and empties the slots (see the type's Bounds).
    /// A covered slot is resolved on this hop even if the covering own event is then dropped at record or is an
    /// invalid ramp; the next hop flags that through its own loss (`droppedAtRecord`, `invalidRamps`).
    func retire(coveredBy block: KernelBlockBuffer, _ body: (KernelEvent) -> Void) {
        let ownKinds = pendingTotal.load(ordering: .relaxed) > 0 ? Self.statefulKinds(in: block) : 0
        while let event = next {
            let index = head.pointee
            if let kind = Self.kind(event.payload), ownKinds & (1 << kind) != 0, Self.covered(event, by: block) {
                discard(index)
                continue
            }
            head.pointee &+= 1
            leavePending(slots[index])
            recarried.add(1, ordering: .releasing)
            body(event)
        }
    }

    /// Marks pending slot `index` superseded by the replacement's own state and resolves it.
    private func discard(_ index: Int) {
        slots[index].superseded = true
        leavePending(slots[index])
        supersededByReplacement.add(1, ordering: .releasing)
        resolve(slots[index])
    }

    private func leavePending(_ slot: Slot) {
        if let kind = Self.kind(slot.event.payload) { pendingByKind[kind] &-= 1 }
        pendingTotal.subtract(1, ordering: .releasing)
    }

    /// A bit per stateful kind (see `kind(_:)`) of which `block` holds an event. A `while` loop: in an unoptimized
    /// build the `for`-over-range form measured one heap allocation here.
    private static func statefulKinds(in block: KernelBlockBuffer) -> Int {
        var kinds = 0
        var index = 0
        while index < block.count {
            if let kind = kind(block[index].event.payload) { kinds |= 1 << kind }
            index &+= 1
        }
        return kinds
    }

    /// A pending own event in `block` for `carried`'s target at or after its frame. `block` is in original-frame
    /// order, so the scan runs from the end and stops at the first own event before `carried`.
    private static func covered(_ carried: KernelEvent, by block: KernelBlockBuffer) -> Bool {
        var index = block.count
        while index > 0 {
            index &-= 1
            let own = block[index].event
            if own.frame < carried.frame { return false }
            if sameTarget(carried, own) { return true }
        }
        return false
    }

    private func resolve(_ slot: Slot) {
        switch slot.event.payload {
        case .control: resolvedControls.add(slot.weight, ordering: .releasing)
        case .program: resolvedPrograms.add(slot.weight, ordering: .releasing)
        case .rampTo: resolvedRamps.add(slot.weight, ordering: .releasing)
        case .noteOn, .noteOff, .clockPulse: break
        }
    }

    /// The pending-count index of a stateful payload (control 0, program 1, ramp 2); `nil` otherwise.
    private static func kind(_ payload: KernelEventPayload) -> Int? {
        switch payload {
        case .control: 0
        case .program: 1
        case .rampTo: 2
        case .noteOn, .noteOff, .clockPulse: nil
        }
    }

    /// The re-admission target: (scope, channel, controller), (scope, channel) or the ramp parameter of any scope.
    private static func sameTarget(_ carried: KernelEvent, _ own: KernelEvent) -> Bool {
        switch (carried.payload, own.payload) {
        case let (.control(channel, controller, _), .control(ownChannel, ownController, _)):
            carried.scope == own.scope && channel == ownChannel && controller == ownController
        case let (.program(channel, _, _), .program(ownChannel, _, _)):
            carried.scope == own.scope && channel == ownChannel
        case let (.rampTo(parameter, _, _), .rampTo(ownParameter, _, _)):
            parameter == ownParameter
        default:
            false
        }
    }

    /// `KernelCarryRetiming`'s supersede key.
    private static func planKey(_ event: KernelEvent) -> PlanKey? {
        switch event.payload {
        case let .control(channel, controller, _): .control(event.scope, channel, controller)
        case let .program(channel, _, _): .program(event.scope, channel)
        case let .rampTo(parameter, _, _): .ramp(event.scope, parameter)
        case .noteOn, .noteOff, .clockPulse: nil
        }
    }
}
