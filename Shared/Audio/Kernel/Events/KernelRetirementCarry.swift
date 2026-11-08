// #364 E5c kernel cycle component: a fixed-capacity carry of the stateful events a retiring cycle would drop.
// Inline storage, no allocation, no lock; wiring into `KernelCycle.retire()` is a later slice.
// Reference model; not RT-certified.

/// Up to `capacity` stateful events (`control`, `program`, `rampTo`) recorded by a retiring cycle, in recorded order,
/// for `KernelCarryRetiming.plan` to re-time into a replacement cycle. Other payloads are never carried: a `noteOn` is
/// lost (never stuck), a `noteOff` keeps its tombstone and a `clockPulse` is timing.
///
/// Storage is an `InlineArray` inside the value: `init` and `record` allocate nothing, take no lock and never touch
/// an `Array`; `record` is O(1). A full carry never overwrites: the event is counted in `droppedForCapacity`
/// (saturating at `Int.max`). Slots past `count` always hold one filler, so they carry no information. `==` compares
/// the recorded events bitwise, so a `NaN` ramp equals itself. `events` allocates and belongs to the control side.
/// Reference model; not RT-certified.
struct KernelRetirementCarry: Sendable, BitwiseCopyable, Equatable {
    /// Events held at most; at most `KernelCycle.maximumBlockCapacity`.
    static let capacity = 256

    enum RecordResult: Sendable, Equatable {
        /// Stored at the end.
        case stored
        /// The carry was full: nothing stored, `droppedForCapacity` incremented.
        case droppedFull
        /// Not `control`, `program` or `rampTo`: nothing changed, not even `droppedForCapacity`.
        case notStateful
    }

    private static let filler = KernelEvent(frame: 0, scope: 0, sequence: 0, payload: .clockPulse)

    private var storage: InlineArray<256, KernelEvent>
    /// Events held, `0...capacity`.
    private(set) var count = 0
    /// Stateful events `record` refused because the carry was full; saturates at `Int.max`.
    private(set) var droppedForCapacity = 0

    init() {
        storage = InlineArray(repeating: Self.filler)
    }

    #if DEBUG
    /// Seeds the drop counter so the saturation is testable; Debug builds only.
    init(seedingDroppedForCapacity dropped: Int) {
        self.init()
        droppedForCapacity = dropped
    }
    #endif

    /// Stores a stateful `event` when there is room. O(1).
    @discardableResult
    mutating func record(_ event: KernelEvent) -> RecordResult {
        switch event.payload {
        case .noteOn, .noteOff, .clockPulse:
            return .notStateful
        case .control, .program, .rampTo:
            break
        }
        guard count < Self.capacity else {
            if droppedForCapacity < Int.max { droppedForCapacity += 1 }
            return .droppedFull
        }
        storage[count] = event
        count += 1
        return .stored
    }

    /// The `index`th recorded event, or `nil` outside `0..<count`.
    func event(at index: Int) -> KernelEvent? {
        guard index >= 0, index < count else { return nil }
        return storage[index]
    }

    /// The recorded events in recorded order. Allocates: control side only.
    var events: [KernelEvent] {
        (0..<count).map { storage[$0] }
    }

    static func == (lhs: KernelRetirementCarry, rhs: KernelRetirementCarry) -> Bool {
        guard lhs.count == rhs.count, lhs.droppedForCapacity == rhs.droppedForCapacity else { return false }
        for index in 0..<lhs.count where !sameBits(lhs.storage[index], rhs.storage[index]) { return false }
        return true
    }

    private static func sameBits(_ lhs: KernelEvent, _ rhs: KernelEvent) -> Bool {
        guard lhs.frame == rhs.frame, lhs.scope == rhs.scope, lhs.sequence == rhs.sequence else { return false }
        if case let .rampTo(leftParameter, leftValue, leftDuration) = lhs.payload,
           case let .rampTo(rightParameter, rightValue, rightDuration) = rhs.payload {
            return leftParameter == rightParameter && leftValue.bitPattern == rightValue.bitPattern
                && leftDuration == rightDuration
        }
        return lhs.payload == rhs.payload
    }
}
