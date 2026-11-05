//
//  OpenSoundControl+BundlePlanner.swift
//  FluxKlang
//
//  Splits one OSC packet into dispatch batches: one per bundle with direct
//  messages (or one for a bare message), in depth-first pre-order of bundles.
//  Planning is atomic: its first refusal refuses the whole packet. The
//  scheduler and the immediate stage differ only in how a timed tag resolves.
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

    /// Traversal state of one planning pass.
    fileprivate struct PlanningContext {
        let allowList: AllowList
        let maximumDepth: Int
        var nextBundleIndex = 0
        var batches: [PlannedBatch] = []
    }

    /// Planning order: a bundle's depth, then its own tag (reserved, resolution,
    /// nesting), then its direct messages in element order, then its child
    /// bundles in element order. An immediate bundle inherits the enclosing
    /// bundle's resolved time and, at top level, dispatches at once.
    enum BundlePlanner {

        static func plan(
            _ packet: Packet, allowList: AllowList, maximumBundleDepth: Int, resolve: TimeTagResolver
        ) throws(SchedulingRefusal) -> [PlannedBatch] {
            switch packet {
            case .message(let message):
                try allowList.admit(message)
                return [PlannedBatch(bundleIndex: 0, time: nil, messages: [message])]
            case .bundle(let bundle):
                var context = PlanningContext(allowList: allowList, maximumDepth: maximumBundleDepth)
                try visit(bundle, depth: 1, enclosing: nil, context: &context, resolve: resolve)
                return context.batches
            }
        }

        private static func visit(
            _ bundle: Bundle, depth: Int, enclosing: ResolvedTime?, context: inout PlanningContext,
            resolve: TimeTagResolver
        ) throws(SchedulingRefusal) {
            guard depth <= context.maximumDepth else { throw .bundleTooDeep(limit: context.maximumDepth) }
            let index = context.nextBundleIndex
            context.nextBundleIndex += 1
            let time = try effectiveTime(of: bundle.timeTag, enclosing: enclosing, resolve: resolve)
            var messages: [Message] = []
            for case .message(let message) in bundle.elements {
                try context.allowList.admit(message)
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
    /// non-immediate tag instead of dispatching it early.
    enum ImmediateStage {
        /// Batches in dispatch order, each all-or-nothing in element order.
        static func admit(
            _ packet: Packet, allowList: AllowList,
            maximumBundleDepth: Int = SchedulingPolicy.defaultMaximumBundleDepth
        ) throws(SchedulingRefusal) -> [[Message]] {
            let plans = try BundlePlanner.plan(
                packet, allowList: allowList, maximumBundleDepth: maximumBundleDepth
            ) { timeTag throws(SchedulingRefusal) in
                throw .unsupportedScheduling(timeTag)
            }
            return plans.map(\.messages)
        }
    }
}
