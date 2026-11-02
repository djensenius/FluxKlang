//
//  ScriptedEventSource.swift
//  FluxKlangTests
//
//  A bounded, scripted stream of generation, restart and anchor events with
//  injectable delivery faults. Lost-event counters saturate; the record retains
//  only the first `capacity` losses for inspection.
//

@testable import FluxKlang

/// One event a scripted source delivers to `FixtureEventApplier`.
enum ContractFixtureEvent: Hashable, Sendable {
    case bump(GenerationKey, GenerationBumpReason)
    case restartRecord(ClockRestartRecord)
    /// A generation's first anchor, observed at the rate the observer believes is current.
    case anchor(ClockAnchor, nominalRate: Int)
}

/// A delivery fault, applied to the pending events when it is injected.
enum EventFault: Hashable, Sendable, CaseIterable {
    /// The next event is lost and counted in `droppedCount`.
    case drop
    /// The next event is delivered twice.
    case duplicate
    /// The next two events are delivered in the opposite order.
    case swapNext
    /// The source's buffer overflows: every pending event, not just the next one, is lost and
    /// counted in `overflowCount`.
    case overflow
}

/// Why a source was not created or refused a fault. A refusal changes nothing.
enum ScriptedEventSourceError: Error, Equatable, Sendable {
    case invalidCapacity
    /// More pending events than the capacity allows.
    case capacity
    /// The fault needs a pending event and there is none.
    case noPendingEvent
    /// `swapNext` needs two pending events.
    case nothingToSwap
}

struct ScriptedEventSource: Hashable, Sendable {
    static var maximumCapacity: Int { 4_096 }

    let capacity: Int
    /// Events still to deliver, in delivery order.
    private(set) var pending: [ContractFixtureEvent]
    private(set) var deliveredCount = 0
    /// Events lost to `drop`. Saturates at `Int.max` rather than trapping.
    private(set) var droppedCount = 0
    /// Events lost to `overflow`. Saturates at `Int.max` rather than trapping.
    private(set) var overflowCount = 0
    /// The first `capacity` lost events, in the order they were lost.
    private(set) var lost: BoundedRecorder<ContractFixtureEvent>

    init(capacity: Int, events: [ContractFixtureEvent]) throws(ScriptedEventSourceError) {
        guard (1...Self.maximumCapacity).contains(capacity) else { throw .invalidCapacity }
        guard events.count <= capacity else { throw .capacity }
        guard let lost = try? BoundedRecorder<ContractFixtureEvent>(capacity: capacity) else {
            throw .invalidCapacity
        }
        self.capacity = capacity
        self.lost = lost
        pending = events
    }

    var lostCount: Int { Self.increment(droppedCount, by: overflowCount) }

    mutating func inject(_ fault: EventFault) throws(ScriptedEventSourceError) {
        switch fault {
        case .drop:
            guard !pending.isEmpty else { throw .noPendingEvent }
            _ = lost.record(pending.removeFirst())
            droppedCount = Self.increment(droppedCount, by: 1)
        case .duplicate:
            guard let first = pending.first else { throw .noPendingEvent }
            guard pending.count < capacity else { throw .capacity }
            pending.insert(first, at: 0)
        case .swapNext:
            guard pending.count >= 2 else { throw .nothingToSwap }
            pending.swapAt(0, 1)
        case .overflow:
            // Loses the whole backlog, unlike `drop`.
            guard !pending.isEmpty else { throw .noPendingEvent }
            for event in pending { _ = lost.record(event) }
            overflowCount = Self.increment(overflowCount, by: pending.count)
            pending.removeAll()
        }
    }

    mutating func next() -> ContractFixtureEvent? {
        guard !pending.isEmpty else { return nil }
        deliveredCount = Self.increment(deliveredCount, by: 1)
        return pending.removeFirst()
    }

    private static func increment(_ value: Int, by amount: Int) -> Int {
        let (sum, overflow) = value.addingReportingOverflow(amount)
        return overflow ? Int.max : sum
    }
}
