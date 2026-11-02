import Testing
@testable import FluxKlang

/// Root suite for the #64 realtime kernel (`Shared/Audio/Kernel/**`). Each slice adds a
/// `RealtimeHandoffTests+<Area>.swift` extension; nested suites must not shadow production type names.
struct RealtimeHandoffTests {}

extension RealtimeHandoffTests {
    /// Compiles only when `Value` is statically `BitwiseCopyable`.
    static func requireBitwise<Value: BitwiseCopyable>(_: Value.Type) {}

    /// Boundary and hostile values for counts, sizes, slots and lanes.
    static let adversarialInts: [Int] = [.min, -1, 0, 1, 2, .max]

    /// Boundary and hostile frame values.
    static let adversarialFrames: [Int64] = [.min, -1, 0, 1, .max]

    /// A valid control-to-render event policy; tests override one field at a time.
    static func policy(
        purpose: HandoffPurpose = .events,
        producer: ExecutionContext = .control,
        producers: ProducerCardinality = .init(maximum: 1, evidence: .appOwned),
        consumer: ExecutionContext = .render,
        consumers: Int = 1,
        capacity: Int = 256,
        ordering: HandoffOrdering = .fifo,
        deadline: DeadlineHorizon = .frames(lateTolerance: 480, lookahead: 96_000),
        overflow: OverflowPolicy = .refuseProducer,
        lifetime: HandoffLifetime = .session
    ) -> HandoffPolicy {
        HandoffPolicy(purpose: purpose, producer: producer, producers: producers, consumer: consumer,
                      consumers: consumers, capacity: capacity, ordering: ordering, deadline: deadline,
                      overflow: overflow, lifetime: lifetime)
    }

    /// A valid render-to-UI telemetry policy.
    static func telemetryPolicy(consumer: ExecutionContext = .ui, consumers: Int = 1) -> HandoffPolicy {
        policy(purpose: .telemetry, producer: .render, consumer: consumer, consumers: consumers,
               ordering: .latestOnly, deadline: .none, overflow: .overwriteLatest)
    }

    /// A valid MIDI-receive-to-control SysEx policy with conservative fan-in.
    static func sysexPolicy(
        consumer: ExecutionContext = .control,
        consumers: Int = 1,
        ordering: HandoffOrdering = .completeMessagesFIFO,
        overflow: OverflowPolicy = .refuseProducer
    ) -> HandoffPolicy {
        policy(purpose: .sysex, producer: .midiReceive, producers: .conservativeDefault(for: .midiReceive),
               consumer: consumer, consumers: consumers, ordering: ordering, deadline: .none, overflow: overflow)
    }

    /// The rule a policy violates, or `nil` when it validates.
    static func violation(_ policy: HandoffPolicy) -> HandoffPolicyRule? {
        do {
            try policy.validate()
            return nil
        } catch {
            switch error {
            case .violates(let rule): return rule
            }
        }
    }
}
