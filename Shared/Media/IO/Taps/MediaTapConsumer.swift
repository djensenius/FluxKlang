// #109 IO3: tap identity, consumer roles and the validated consumer spec. Pure Swift; no clock, no ring.

/// Names one capture tap. Positive, built only by `make(_:)`.
struct MediaTapID: Hashable, Comparable, Sendable {
    let rawValue: Int

    private init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// Refuses a value below 1 with `.invalidTap`. Any larger value, up to `Int.max`, is a valid name.
    static func make(_ rawValue: Int) throws(MediaTapRefusal) -> MediaTapID {
        guard rawValue >= 1 else { throw .invalidTap(rawValue) }
        return MediaTapID(rawValue: rawValue)
    }

    static func < (lhs: MediaTapID, rhs: MediaTapID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Who drains a tap. Role order is raw-value order, and is the order of a plan's policies.
enum MediaTapRole: UInt8, CaseIterable, Comparable, Sendable {
    case playback, recorder, tuner

    /// Smallest ring, in blocks. The recorder needs one block in flight plus one queued; the others need one.
    var minimumCapacityBlocks: Int {
        self == .recorder ? 2 : 1
    }

    /// Losing this role's blocks is a lost-frame event the caller must surface. The tuner is advisory and
    /// playback is not a capture of record, so only the recorder is critical. The plan states this, counts nothing.
    var lossIsCritical: Bool {
        self == .recorder
    }

    /// Playback and recorder drain on a worker; the advisory tuner may drain on a worker or on control. Render and UI
    /// never drain a capture ring, and externally owned callbacks are not allowed to either.
    func accepts(_ context: ExecutionContext) -> Bool {
        switch self {
        case .playback, .recorder: context == .worker
        case .tuner: context == .worker || context == .control
        }
    }

    static func < (lhs: MediaTapRole, rhs: MediaTapRole) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// One consumer of a tap: a role, a ring capacity in blocks and the context that drains it. Built only by `make`.
struct MediaTapConsumerSpec: Equatable, Sendable {
    let role: MediaTapRole
    let capacityBlocks: Int
    let consumerContext: ExecutionContext

    private init(role: MediaTapRole, capacityBlocks: Int, consumerContext: ExecutionContext) {
        self.role = role
        self.capacityBlocks = capacityBlocks
        self.consumerContext = consumerContext
    }

    /// Checks the context first (`.invalidContext`), then the capacity (`.invalidCapacity`), which must be in
    /// `role.minimumCapacityBlocks...KernelLimits.maximumCapacity`.
    static func make(
        role: MediaTapRole,
        capacityBlocks: Int,
        consumerContext: ExecutionContext
    ) throws(MediaTapRefusal) -> MediaTapConsumerSpec {
        guard role.accepts(consumerContext) else { throw .invalidContext(role) }
        guard capacityBlocks >= role.minimumCapacityBlocks, capacityBlocks <= KernelLimits.maximumCapacity else {
            throw .invalidCapacity(role, capacityBlocks)
        }
        return MediaTapConsumerSpec(role: role, capacityBlocks: capacityBlocks, consumerContext: consumerContext)
    }

    /// The fixed policy shape: render events into one private FIFO ring that refuses the producer when full, drained
    /// by exactly one consumer. The plan validates it before it is stored.
    func handoffPolicy() -> HandoffPolicy {
        HandoffPolicy(
            purpose: .events,
            producer: .render,
            producers: ProducerCardinality(maximum: 1, evidence: .appOwned),
            consumer: consumerContext,
            consumers: 1,
            capacity: capacityBlocks,
            ordering: .fifo,
            deadline: .none,
            overflow: .refuseProducer,
            lifetime: .session
        )
    }
}
