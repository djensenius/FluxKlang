//
//  OpenSoundControl+BundlePlanner.swift
//  FluxKlang
//
//  Splits one OSC packet into dispatch batches: one per bundle with direct
//  messages (or one for a bare message), in depth-first pre-order of bundles.
//  Planning is atomic: its first refusal refuses the whole packet. It is also
//  bounded: depth, element count and budgets are checked before the work or
//  storage they guard, so a packet built in memory (which skips the decoder's
//  limits and may repeat shared children) is walked through at most
//  `SchedulingPolicy.maximumPacketElements` elements and plans at most the
//  budgeted batches and messages. The scheduler and the immediate stage differ
//  only in how a timed tag resolves and in their budgets.
//

extension OpenSoundControl {
    /// The messages directly inside one bundle, in element order.
    struct PlannedBatch: Sendable, Hashable {
        /// Depth-first pre-order index of the bundle in its packet; a bare message is 0.
        private(set) var bundleIndex: Int
        /// The bundle's own or inherited resolved time; nil dispatches at once.
        private(set) var time: ResolvedTime?
        private(set) var messages: [Message]

        fileprivate init(bundleIndex: Int, time: ResolvedTime?, messages: [Message]) {
            self.bundleIndex = bundleIndex
            self.time = time
            self.messages = messages
        }
    }

    /// Maps a timed tag to its resolved time or refuses it.
    typealias TimeTagResolver = (TimeTag) throws(SchedulingRefusal) -> ResolvedTime

    /// How many batches and messages one packet may add (each pending capacity
    /// minus what is already pending), and the capacities a refusal names.
    struct PlanningBudget: Sendable, Hashable {
        /// No pending state, as in the immediate stage: only the depth and
        /// element bounds limit the plan.
        static let unbounded = PlanningBudget(batches: .max, batchLimit: .max, messages: .max, messageLimit: .max)

        let batches: Int
        let batchLimit: Int
        let messages: Int
        let messageLimit: Int
    }

    /// Traversal state of one planning pass.
    fileprivate struct PlanningContext {
        let allowList: AllowList
        let maximumDepth: Int
        let budget: PlanningBudget
        var nextBundleIndex = 0
        var elementCount = 0
        var messageCount = 0
        var batches: [PlannedBatch] = []

        /// Counts all of a bundle's elements before any is visited, as the codec
        /// counts them across a packet, so planning work stays bounded.
        mutating func countElements(of bundle: Bundle) throws(SchedulingRefusal) {
            let limit = SchedulingPolicy.maximumPacketElements
            guard bundle.elements.count <= limit - elementCount else { throw .tooManyElements(limit: limit) }
            elementCount += bundle.elements.count
        }

        /// Refuses before one more message, or the batch it belongs to, would
        /// exceed its budget; the batch is checked first.
        mutating func reserveMessage() throws(SchedulingRefusal) {
            guard batches.count < budget.batches else {
                throw .capacityExceeded(.pendingBatches, limit: budget.batchLimit)
            }
            guard messageCount < budget.messages else {
                throw .capacityExceeded(.pendingMessages, limit: budget.messageLimit)
            }
            messageCount += 1
        }
    }

    /// Planning order: a bundle's depth, then its element count, then its own
    /// tag (reserved, resolution, nesting), then its direct messages in element
    /// order (each: allow-list, then room for its batch, then for itself), then
    /// its child bundles in element order. An immediate bundle inherits the
    /// enclosing bundle's resolved time and, at top level, dispatches at once.
    enum BundlePlanner {

        static func plan(
            _ packet: Packet, allowList: AllowList, maximumBundleDepth: Int, budget: PlanningBudget,
            resolve: TimeTagResolver
        ) throws(SchedulingRefusal) -> [PlannedBatch] {
            var context = PlanningContext(allowList: allowList, maximumDepth: maximumBundleDepth, budget: budget)
            switch packet {
            case .message(let message):
                try allowList.admit(message)
                try context.reserveMessage()
                return [PlannedBatch(bundleIndex: 0, time: nil, messages: [message])]
            case .bundle(let bundle):
                try visit(bundle, depth: 1, enclosing: nil, context: &context, resolve: resolve)
                return context.batches
            }
        }

        /// Recursion is bounded: depth is checked on entry, before anything else.
        private static func visit(
            _ bundle: Bundle, depth: Int, enclosing: ResolvedTime?, context: inout PlanningContext,
            resolve: TimeTagResolver
        ) throws(SchedulingRefusal) {
            guard depth <= context.maximumDepth else { throw .bundleTooDeep(limit: context.maximumDepth) }
            try context.countElements(of: bundle)
            let index = context.nextBundleIndex
            context.nextBundleIndex += 1
            let time = try effectiveTime(of: bundle.timeTag, enclosing: enclosing, resolve: resolve)
            var messages: [Message] = []
            for case .message(let message) in bundle.elements {
                try context.allowList.admit(message)
                try context.reserveMessage()
                messages.append(message)
            }
            if !messages.isEmpty {
                context.batches.append(PlannedBatch(bundleIndex: index, time: time, messages: messages))
            }
            for case .bundle(let child) in bundle.elements {
                try visit(child, depth: depth + 1, enclosing: time, context: &context, resolve: resolve)
            }
        }

        private static func effectiveTime(
            of timeTag: TimeTag, enclosing: ResolvedTime?, resolve: TimeTagResolver
        ) throws(SchedulingRefusal) -> ResolvedTime? {
            guard timeTag.rawValue != 0 else { throw .reservedTimeTag(timeTag) }
            guard !timeTag.isImmediate else { return enclosing }
            let time = try resolve(timeTag)
            // Resolved instants, not raw tags, so nesting holds across the 2036 wrap.
            if let enclosing, time.wall < enclosing.wall {
                throw .nestedTimeTagEarlier(enclosing: enclosing.timeTag, inner: timeTag)
            }
            return time
        }
    }

    /// The stage that runs while scheduling is disabled: it dispatches only
    /// immediate content and reports `unsupportedScheduling` for the first
    /// non-immediate tag instead of dispatching it early. It keeps nothing
    /// pending, so only the depth and element bounds limit a packet.
    enum ImmediateStage {
        /// Batches in dispatch order, each all-or-nothing in element order.
        static func admit(
            _ packet: Packet, allowList: AllowList,
            maximumBundleDepth: Int = SchedulingPolicy.defaultMaximumBundleDepth
        ) throws(SchedulingRefusal) -> [[Message]] {
            let plans = try BundlePlanner.plan(
                packet, allowList: allowList, maximumBundleDepth: maximumBundleDepth, budget: .unbounded
            ) { timeTag throws(SchedulingRefusal) in
                throw .unsupportedScheduling(timeTag)
            }
            return plans.map(\.messages)
        }
    }
}
