// #64 M5 fan-out: one producer publishes each value into N private SPSC rings, one per consumer. A full ring
// refuses only its own consumer's copy and counts it. Reference model; not RT-certified.

/// Which consumers took one published value. Bit `i` stands for consumer `i`; `accepted` and `refused` are
/// disjoint and together cover every consumer. Reference model; not RT-certified.
struct FanOutResult: Sendable, BitwiseCopyable, Equatable {
    let accepted: UInt64
    /// Consumers whose ring was full; each refusal is also counted on that consumer's ring.
    let refused: UInt64

    /// Every consumer took the value.
    var isComplete: Bool { refused == 0 }
}

/// One producer, up to 64 consumers, each with a private `SPSCRing`. Reference model; not RT-certified.
///
/// `publish` offers the value to every ring in consumer order, exactly once each, without retrying an offer. A
/// slow consumer whose ring is full is refused alone (its bit in `FanOutResult.refused`, plus its ring's
/// `refusedCount`), and every other consumer still receives the value. Nothing is skipped silently and no
/// consumer blocks another. Each consumer drains its own ring through `ring(_:)`.
///
/// Policies. One validated SPSC policy per consumer (M2 rules: refusing, FIFO, one producer); all must declare
/// the same producer context, because one producer feeds every ring. Capacities and consumers may differ.
///
/// Progress (source level only). `publish` makes one M2 `tryPush` per consumer; atomic lowering and target progress
/// remain unqualified. No source-level allocation follows `init`. Unretained ring references (`rings` owns them)
/// avoid reference counting in the inspected configurations; this is not final-target qualification.
///
/// `@unchecked Sendable`: each ring is safe under its own SPSC contract; this type only adds immutable state.
final class FanOutHandoff<Element: BitwiseCopyable>: @unchecked Sendable {
    /// Why `init` refused to prepare a fan-out.
    enum PreparationError: Error, Equatable, Sendable {
        /// No policies, or more than `maximumConsumers`.
        case consumerCountOutOfRange(Int)
        /// The consumer's policy fails `HandoffPolicy.validate()` or declares more than one producer.
        case policy(consumer: Int, HandoffPolicyError)
        /// The consumer's policy is valid but needs a different container.
        case unsupportedPolicy(consumer: Int, SPSCRing<Element>.Unsupported)
        /// The consumer's policy names a different producer context from consumer 0's.
        case mixedProducers(consumer: Int)
    }

    /// One bit per consumer in `FanOutResult`.
    static var maximumConsumers: Int { UInt64.bitWidth }

    let consumerCount: Int

    /// Owns the rings; hot paths use `ringRefs`.
    private let rings: [SPSCRing<Element>]
    private let ringRefs: UnsafeMutablePointer<Unmanaged<SPSCRing<Element>>>

    /// Validates every policy and allocates every ring. Control-side only.
    init(policies: [HandoffPolicy]) throws(PreparationError) {
        guard let first = policies.first, policies.count <= Self.maximumConsumers else {
            throw .consumerCountOutOfRange(policies.count)
        }
        var built: [SPSCRing<Element>] = []
        built.reserveCapacity(policies.count)
        for (consumer, policy) in policies.enumerated() {
            do {
                built.append(try SPSCRing<Element>(policy: policy))
            } catch {
                switch error {
                case .policy(let reason): throw .policy(consumer: consumer, reason)
                case .unsupportedPolicy(let reason): throw .unsupportedPolicy(consumer: consumer, reason)
                }
            }
            guard policy.producer == first.producer else { throw .mixedProducers(consumer: consumer) }
        }
        consumerCount = built.count
        rings = built
        ringRefs = .allocate(capacity: built.count)
        for index in built.indices { (ringRefs + index).initialize(to: .passUnretained(built[index])) }
    }

    /// Control-side teardown.
    deinit {
        ringRefs.deinitialize(count: consumerCount)
        ringRefs.deallocate()
    }

    /// The producer only (see Progress). Offers `value` once to every consumer's ring and reports which took it.
    func publish(_ value: Element) -> FanOutResult {
        var accepted: UInt64 = 0
        var refused: UInt64 = 0
        var consumer = 0
        while consumer < consumerCount {
            let bit: UInt64 = 1 &<< UInt64(truncatingIfNeeded: consumer)
            if ringRefs[consumer]._withUnsafeGuaranteedRef({ $0.tryPush(value) }) == .ok {
                accepted |= bit
            } else {
                refused |= bit
            }
            consumer &+= 1
        }
        return FanOutResult(accepted: accepted, refused: refused)
    }

    /// Consumer `consumer`'s ring, for that consumer to drain, or `nil` when out of range. Control-side setup.
    func ring(_ consumer: Int) -> SPSCRing<Element>? {
        guard consumer >= 0, consumer < consumerCount else { return nil }
        return rings[consumer]
    }

    /// Values refused to `consumer` because its ring was full (M2 counter), or `nil` when out of range.
    func refusedCount(consumer: Int) -> UInt64? {
        guard consumer >= 0, consumer < consumerCount else { return nil }
        return ringRefs[consumer]._withUnsafeGuaranteedRef { $0.refusedCount }
    }
}
