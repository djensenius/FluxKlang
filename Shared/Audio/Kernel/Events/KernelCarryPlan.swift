/// The canonical carry plan used immediately by `KernelCarryReadmission.init` (#837).
///
/// Construction and indexed result consumption allocate nothing and take no lock. This does NOT make the
/// readmission/cycle constructor allocation-free: it still allocates its object and render-owned slots on control.
/// The result has no public mutation or replanning operation. Planning keys are scope-qualified, unlike render's
/// cross-scope ramp matching. See docs/kernel-carry-plan.md for storage, copy exposure and bounded work.
struct KernelCarryPlan: Sendable, BitwiseCopyable {
    struct Entry: Sendable, BitwiseCopyable {
        let event: KernelEvent
        let weight: Int
    }

    private static let filler = Entry(event: KernelEvent(frame: 0, scope: 0, sequence: 0, payload: .clockPulse),
                                      weight: 0)
    private var storage: InlineArray<256, Entry>
    private(set) var count = 0
    private(set) var invalidRamps = 0
    private(set) var superseded = 0
    private(set) var cut = KernelRetirementLoss()
    private(set) var refusal: KernelCarryRefusal?
    let droppedAtRecord: Int

    /// Only the bounded carry is visited. `capacity` is clamped exactly as the readmission constructor's capacity.
    init(carry: borrowing KernelRetirementCarry, capacity: Int) {
        storage = InlineArray(repeating: Self.filler)
        droppedAtRecord = carry.droppedForCapacity
        let limit = min(KernelRetirementCarry.capacity, max(1, capacity))
        // Visit re-carried entries first, then own entries, each in recorded order. Stable insertion by frame
        // therefore implements (original frame, re-carried before own, recorded index), without storing indices.
        let recarried = carry.count - carry.ownCount
        var index = 0
        while index < carry.count {
            let recorded = index < recarried ? carry.ownCount + index : index - recarried
            if let event = carry.event(at: recorded) {
                if case let .rampTo(_, value, _) = event.payload,
                   !KernelEventPayload.isAdmissibleRampTarget(value) {
                    invalidRamps += 1
                } else {
                    insert(event)
                }
            }
            index += 1
        }
        guard coalesceAndCheckOverflow() else {
            count = 0
            superseded = 0
            refusal = .frameOverflow
            return
        }
        compact(capacity: limit)
    }

    /// A fixed-result read, also used to initialize the constructor's separately allocated render slots.
    func entry(at index: Int) -> Entry? {
        guard index >= 0, index < count else { return nil }
        return storage[index]
    }

    /// Stable insertion: at most 32,640 frame comparisons and shifts over 256 entries.
    private mutating func insert(_ event: KernelEvent) {
        var index = count
        while index > 0 {
            guard storage[index - 1].event.frame > event.frame else { break }
            storage[index] = storage[index - 1]
            index -= 1
        }
        storage[index] = Entry(event: event, weight: 1)
        count += 1
    }

    /// Walk backwards so only the last event of each key survives. Zero weight marks a superseded entry.
    /// At most 32,640 later-entry visits; no hash table, recursion or data-dependent unbounded retry.
    private mutating func coalesceAndCheckOverflow() -> Bool {
        var index = count
        while index > 0 {
            index -= 1
            let event = storage[index].event
            var later = index + 1
            if event.payload.isCoalescible {
                while later < count {
                    let survivor = storage[later]
                    if survivor.weight > 0, Self.sameKey(event, survivor.event) {
                        storage[later] = Entry(event: survivor.event, weight: survivor.weight + 1)
                        storage[index] = Entry(event: event, weight: 0)
                        superseded += 1
                        break
                    }
                    later += 1
                }
            }
            // Validate every survivor BEFORE the capacity cut, but never a superseded/invalid ramp.
            if storage[index].weight > 0, case let .rampTo(_, _, duration) = event.payload,
               event.frame.addingReportingOverflow(KernelEventPayload.rampFrames(duration)).overflow {
                return false
            }
        }
        return true
    }

    private mutating func compact(capacity: Int) {
        var read = 0
        var kept = 0
        while read < count {
            let entry = storage[read]
            if entry.weight > 0 {
                if kept < capacity {
                    storage[kept] = entry
                    kept += 1
                } else {
                    cut.drop(entry.event.payload)
                }
            }
            read += 1
        }
        count = kept
    }

    /// A data-entry control has no planning key. Ramp keys include scope here, NOT render's matching rule.
    private static func sameKey(_ lhs: KernelEvent, _ rhs: KernelEvent) -> Bool {
        guard lhs.scope == rhs.scope, lhs.payload.isCoalescible else { return false }
        return switch (lhs.payload, rhs.payload) {
        case let (.control(channel, controller, _), .control(otherChannel, otherController, _)):
            channel == otherChannel && controller == otherController
        case let (.program(channel, _, _), .program(otherChannel, _, _)):
            channel == otherChannel
        case let (.rampTo(parameter, _, _), .rampTo(otherParameter, _, _)):
            parameter == otherParameter
        default:
            false
        }
    }
}
