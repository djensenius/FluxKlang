//
//  OpenSoundControl+SchedulingPolicy.swift
//  FluxKlang
//
//  The injected bounds and the method allow-list of the OSC scheduler. Both
//  are validated once at construction and immutable afterwards.
//

extension OpenSoundControl {
    /// Late and future horizons (host nanoseconds, compared exactly against host
    /// ticks through the timebase) and the bounded pending state.
    struct SchedulingPolicy: Sendable, Hashable {
        static let defaultMaximumPendingBatches = 256
        static let defaultMaximumPendingMessages = 4_096
        /// Matches the codec's default `Limits.maximumBundleDepth`.
        static let defaultMaximumBundleDepth = 8
        /// Most bundle elements one packet may hold, counted at any depth as the
        /// codec counts them: its default `Limits.maximumBundleElements`. Bounds
        /// planning work for packets built in memory, which skip the decoder.
        static let maximumPacketElements = Limits.standard.maximumBundleElements
        /// Hard ceiling for either capacity.
        static let capacityLimit = 1 << 20
        static let bundleDepthLimit = 64
        /// 2³⁰ s (about 34 years), half the ±2³¹ s span that resolves a time tag's era.
        static let futureHorizonLimitNanoseconds: UInt64 = (1 << 30) * 1_000_000_000

        /// A window whose `latest` is more than this before now is refused as too late.
        private(set) var lateHorizonNanoseconds: UInt64
        /// A window whose `earliest` is more than this after now is refused as too far ahead;
        /// at most `futureHorizonLimitNanoseconds`.
        private(set) var maximumFutureNanoseconds: UInt64
        private(set) var maximumPendingBatches: Int
        private(set) var maximumPendingMessages: Int
        /// A top-level bundle has depth 1; a bare message has depth 0.
        private(set) var maximumBundleDepth: Int

        init(
            lateHorizonNanoseconds: UInt64, maximumFutureNanoseconds: UInt64,
            maximumPendingBatches: Int = SchedulingPolicy.defaultMaximumPendingBatches,
            maximumPendingMessages: Int = SchedulingPolicy.defaultMaximumPendingMessages,
            maximumBundleDepth: Int = SchedulingPolicy.defaultMaximumBundleDepth
        ) throws(SchedulingRefusal) {
            guard maximumFutureNanoseconds <= Self.futureHorizonLimitNanoseconds else {
                throw .futureHorizonOutOfRange(nanoseconds: maximumFutureNanoseconds)
            }
            guard (1...Self.capacityLimit).contains(maximumPendingBatches) else {
                throw .invalidCapacity(.pendingBatches, maximumPendingBatches)
            }
            guard (1...Self.capacityLimit).contains(maximumPendingMessages) else {
                throw .invalidCapacity(.pendingMessages, maximumPendingMessages)
            }
            guard (1...Self.bundleDepthLimit).contains(maximumBundleDepth) else {
                throw .invalidBundleDepth(maximumBundleDepth)
            }
            self.lateHorizonNanoseconds = lateHorizonNanoseconds
            self.maximumFutureNanoseconds = maximumFutureNanoseconds
            self.maximumPendingBatches = maximumPendingBatches
            self.maximumPendingMessages = maximumPendingMessages
            self.maximumBundleDepth = maximumBundleDepth
        }
    }

    /// The methods scheduled messages may target, as operator-compiled address
    /// patterns. Direction: each ENTRY is the pattern and the incoming message's
    /// address is the literal it is matched against (`entry.matches(address)`).
    /// Incoming wildcard patterns are refused, because without the receiver's
    /// method table nothing proves they reach only allowed methods.
    struct AllowList: Sendable, Hashable {
        static let maximumEntries = 256

        private(set) var entries: [AddressPattern]

        init(_ entries: [AddressPattern]) throws(SchedulingRefusal) {
            guard (1...Self.maximumEntries).contains(entries.count) else {
                throw .invalidAllowList(count: entries.count)
            }
            self.entries = entries
        }

        /// Refuses `message` unless its address is literal and some entry matches it.
        func admit(_ message: Message) throws(SchedulingRefusal) {
            let pattern = message.address
            guard !pattern.hasWildcards else { throw .wildcardAddress(pattern.stringValue) }
            // A pattern without wildcards is a valid literal address of its own length.
            let limits = Limits(maximumStringBytes: pattern.bytes.count)
            guard let address = try? Address(pattern.stringValue, limits: limits),
                  entries.contains(where: { $0.matches(address) }) else {
                throw .disallowedAddress(pattern.stringValue)
            }
        }
    }
}
