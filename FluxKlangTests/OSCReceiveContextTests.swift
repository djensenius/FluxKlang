import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// The receive context and the context-tagged scheduler wrapper (#89, O2c): construction, the context limit and
/// admit. Cancel, dispatch revalidation and ordering are in the `+Cancel`, `+Revalidate` and `+Order` files. No clock,
/// no socket and no `Date`: every host stamp is a tick count the test picks. With the unit timebase one tick is one
/// nanosecond, and tick 0 is the anchor of the wall-clock mapping, so a bundle tagged `n` seconds after the reference
/// instant opens `n` seconds after tick 0.
@Suite("OSC receive context and scheduler wrapper", .productionAccessAudit)
struct OSCReceiveContextTests {
    typealias OSC = OpenSoundControl
    typealias Context = OpenSoundControl.ReceiveContext
    typealias Wrapper = OpenSoundControl.ContextScheduler
    typealias Refusal = OpenSoundControl.ContextRefusal
    typealias Inner = OpenSoundControl.SchedulingRefusal

    // MARK: Context construction

    @Test func makeCarriesPeerKey() throws {
        let issued = try Fixture.principal()
        #expect(Context.make(principal: issued, peer: Fixture.peer(42)).peer == Fixture.peer(42))
        #expect(Context.make(principal: issued, peer: Fixture.peer(7)).peer == Fixture.peer(7))
    }

    @Test func makeCarriesHostEpoch() throws {
        let issued = try Fixture.principal()
        let context = Context.make(principal: issued, peer: Fixture.peer(1))
        #expect(context.hostEpoch == issued.hostEpoch)
        #expect(context.hostEpoch.generation == Fixture.generation(7))
        #expect(context.hostEpoch.generation != context.connectionEpoch.generation)
    }

    @Test func makeCarriesConnectionEpoch() throws {
        let issued = try Fixture.principal()
        let context = Context.make(principal: issued, peer: Fixture.peer(1))
        #expect(context.connectionEpoch == issued.connectionEpoch)
        #expect(context.connectionEpoch.generation == Fixture.generation(3))
    }

    @Test func makeCarriesPermissionFingerprint() throws {
        for permission in ["perm.osc.1", "perm.osc.2"] {
            let issued = try Fixture.principal(permission: permission)
            let context = Context.make(principal: issued, peer: Fixture.peer(1))
            #expect(context.permission == PermissionFingerprint(rawValue: permission))
        }
    }

    @Test func contextsDifferingInOneFieldAreNotEqual() throws {
        let base = try Fixture.context()
        #expect(try Fixture.context() == base)
        var distinct: Set<Context> = [base]
        for field in ContextField.allCases {
            let variant = try Fixture.variant(field)
            #expect(Fixture.differingFields(base, variant) == [field], "\(field)")
            #expect(variant != base, "\(field)")
            distinct.insert(variant)
        }
        #expect(distinct.count == 5)
    }

    // MARK: Context limit

    @Test func initAcceptsLowestContextLimit() throws {
        let wrapper = try Fixture.wrapper(limit: 1)
        #expect(wrapper.maximumContexts == 1)
    }

    @Test func initAcceptsHighestContextLimit() throws {
        #expect(OSC.EndpointPolicy.peerLimit == 256)
        let wrapper = try Fixture.wrapper(limit: 256)
        #expect(wrapper.maximumContexts == 256)
    }

    @Test func initRefusesZeroContextLimit() throws {
        let scheduler = try Fixture.scheduler()
        #expect(throws: Refusal.invalidContextLimit(0)) { try Wrapper(scheduler: scheduler, maximumContexts: 0) }
    }

    @Test func initRefusesContextLimitAbovePeerLimit() throws {
        let scheduler = try Fixture.scheduler()
        for limit in [257, 1_000, -1, Int.min, Int.max] {
            #expect(throws: Refusal.invalidContextLimit(limit)) {
                try Wrapper(scheduler: scheduler, maximumContexts: limit)
            }
        }
    }

    @Test func initRefusesSchedulerThatAlreadyQueuesBatches() throws {
        var scheduler = try Fixture.scheduler()
        _ = try scheduler.admit(Fixture.message(1), now: Fixture.host(0))
        #expect(throws: Refusal.schedulerNotEmpty(pending: 1)) { try Wrapper(scheduler: scheduler, maximumContexts: 4) }
        _ = try scheduler.admit(Fixture.threeBatches(), now: Fixture.host(0))
        #expect(throws: Refusal.schedulerNotEmpty(pending: 4)) { try Wrapper(scheduler: scheduler, maximumContexts: 4) }
    }

    @Test func initReportsInvalidLimitBeforeNonEmptyScheduler() throws {
        var scheduler = try Fixture.scheduler()
        _ = try scheduler.admit(Fixture.message(1), now: Fixture.host(0))
        #expect(throws: Refusal.invalidContextLimit(0)) { try Wrapper(scheduler: scheduler, maximumContexts: 0) }
        #expect(throws: Refusal.invalidContextLimit(257)) { try Wrapper(scheduler: scheduler, maximumContexts: 257) }
    }

    @Test func initKeepsSchedulerAndLimit() throws {
        let scheduler = try Fixture.scheduler()
        let wrapper = try Wrapper(scheduler: scheduler, maximumContexts: 5)
        #expect(wrapper.scheduler == scheduler && wrapper.maximumContexts == 5)
        #expect(wrapper.taggedBatchCount == 0 && wrapper.contextCount == 0)
    }

    // MARK: Admit

    @Test func admitTagsEveryBatchOfAThreeBundlePacket() throws {
        var wrapper = try Fixture.wrapper()
        let context = try Fixture.context()
        let batches = try Fixture.admit(&wrapper, Fixture.threeBatches(), context)
        #expect(batches.count == 3 && Fixture.values(batches.flatMap(\.messages)) == [1, 2, 3])
        for batch in batches {
            #expect(wrapper.context(of: batch.id) == context)
        }
        #expect(wrapper.taggedBatchCount == 3 && wrapper.pendingCount(for: context) == 3)
        #expect(wrapper.contextCount == 1 && wrapper.scheduler.pending == batches)
    }

    @Test func admitReturnsTheBatchesTheSchedulerQueued() throws {
        var wrapper = try Fixture.wrapper()
        var bare = try Fixture.scheduler()
        let packet = try Fixture.threeBatches()
        let queued = try Fixture.admit(&wrapper, packet, Fixture.context())
        let expected = try bare.admit(packet, now: Fixture.host(0))
        #expect(queued == expected && queued.count == 3)
        #expect(wrapper.scheduler == bare)
    }

    @Test func admitCountsEveryBatchPerContext() throws {
        var wrapper = try Fixture.wrapper()
        let alpha = try Fixture.context(peer: 1)
        let bravo = try Fixture.context(peer: 2)
        try Fixture.admit(&wrapper, Fixture.threeBatches(), alpha)
        try Fixture.admit(&wrapper, Fixture.message(9), alpha)
        try Fixture.admit(&wrapper, Fixture.spread(2, first: 20), bravo)
        #expect(wrapper.pendingCount(for: alpha) == 4 && wrapper.pendingCount(for: bravo) == 2)
        #expect(wrapper.contextCount == 2 && wrapper.taggedBatchCount == 6 && wrapper.scheduler.pending.count == 6)
    }

    @Test func admitEmptyPacketAddsNoContextEntry() throws {
        var wrapper = try Fixture.wrapper()
        let context = try Fixture.context()
        let queued = try Fixture.admit(&wrapper, Fixture.bundle(.immediate), context)
        #expect(queued.isEmpty)
        #expect(wrapper.contextCount == 0 && wrapper.taggedBatchCount == 0 && wrapper.pendingCount(for: context) == 0)
    }

    @Test func admitRefusesNewContextBeyondLimit() throws {
        var wrapper = try Fixture.wrapper(limit: 2)
        let alpha = try Fixture.context(peer: 1)
        let bravo = try Fixture.context(peer: 2)
        try Fixture.admit(&wrapper, Fixture.message(1), alpha)
        try Fixture.admit(&wrapper, Fixture.message(2), bravo)
        let refusal = try Fixture.admitRefusal(wrapper, Fixture.message(3), Fixture.context(peer: 3))
        #expect(refusal == .contextTableFull(limit: 2))
        #expect(wrapper.contextCount == 2 && wrapper.pendingCount(for: alpha) == 1)
        #expect(wrapper.pendingCount(for: bravo) == 1)
    }

    @Test func admitAcceptsNewContextAtLastFreeSlot() throws {
        var single = try Fixture.wrapper(limit: 1)
        try Fixture.admit(&single, Fixture.message(1), Fixture.context(peer: 1))
        #expect(single.contextCount == 1 && single.taggedBatchCount == 1)
        var pair = try Fixture.wrapper(limit: 2)
        try Fixture.admit(&pair, Fixture.message(1), Fixture.context(peer: 1))
        try Fixture.admit(&pair, Fixture.message(2), Fixture.context(peer: 2))
        #expect(pair.contextCount == 2 && pair.taggedBatchCount == 2)
    }

    @Test func admitAcceptsExistingContextWhenTableIsFull() throws {
        var wrapper = try Fixture.wrapper(limit: 1)
        let alpha = try Fixture.context()
        try Fixture.admit(&wrapper, Fixture.message(1), alpha)
        try Fixture.admit(&wrapper, Fixture.message(2), alpha)
        #expect(wrapper.contextCount == 1 && wrapper.pendingCount(for: alpha) == 2)
    }

    @Test func admitRefusesNewContextWhenTableIsFullEvenForAnEmptyPacket() throws {
        var wrapper = try Fixture.wrapper(limit: 1)
        try Fixture.admit(&wrapper, Fixture.message(1), Fixture.context(peer: 1))
        let refusal = try Fixture.admitRefusal(wrapper, Fixture.bundle(.immediate), Fixture.context(peer: 2))
        #expect(refusal == .contextTableFull(limit: 1))
    }

    @Test func admitReportsTableFullBeforeInnerRefusal() throws {
        let alpha = try Fixture.context(peer: 1)
        let bravo = try Fixture.context(peer: 2)
        var wrapper = try Fixture.wrapper(limit: 1)
        try Fixture.admit(&wrapper, Fixture.message(1), alpha)
        // A disallowed address: the scheduler alone would refuse it, and so would the table for a second context.
        let disallowed = try Fixture.message(2, "/nope")
        #expect(Fixture.admitRefusal(wrapper, disallowed, alpha) == .scheduling(.disallowedAddress("/nope")))
        #expect(Fixture.admitRefusal(wrapper, disallowed, bravo) == .contextTableFull(limit: 1))
        // A stamp earlier than the latest one.
        let valid = try Fixture.message(2)
        let regressed = Inner.nowRegressed(previous: Fixture.host(0), now: Fixture.host(-1))
        #expect(Fixture.admitRefusal(wrapper, valid, alpha, at: -1) == .scheduling(regressed))
        #expect(Fixture.admitRefusal(wrapper, valid, bravo, at: -1) == .contextTableFull(limit: 1))
        // A full queue.
        var queueFull = try Fixture.wrapper(limit: 1, policy: Fixture.policy(batches: 1))
        try Fixture.admit(&queueFull, Fixture.message(1), alpha)
        let full = Inner.capacityExceeded(.pendingBatches, limit: 1)
        #expect(Fixture.admitRefusal(queueFull, valid, alpha) == .scheduling(full))
        #expect(Fixture.admitRefusal(queueFull, valid, bravo) == .contextTableFull(limit: 1))
    }

    @Test func admitWrapsInnerRefusalsAsTheyAre() throws {
        var wrapper = try Fixture.wrapper(limit: 4, policy: Fixture.policy(batches: 1))
        let alpha = try Fixture.context(peer: 1)
        let bravo = try Fixture.context(peer: 2)
        try Fixture.admit(&wrapper, Fixture.message(1), alpha, at: 10)
        let nope = try Fixture.message(2, "/nope")
        let valid = try Fixture.message(2)
        let disallowed = Inner.disallowedAddress("/nope")
        let regressed = Inner.nowRegressed(previous: Fixture.host(10), now: Fixture.host(9))
        let full = Inner.capacityExceeded(.pendingBatches, limit: 1)
        for context in [alpha, bravo] {
            #expect(Fixture.admitRefusal(wrapper, nope, context, at: 10) == .scheduling(disallowed))
            #expect(Fixture.admitRefusal(wrapper, valid, context, at: 9) == .scheduling(regressed))
            #expect(Fixture.admitRefusal(wrapper, valid, context, at: 10) == .scheduling(full))
        }
    }

    @Test func admitRefusalLeavesWholeWrapperUnchanged() throws {
        var wrapper = try Fixture.wrapper(limit: 3)
        let alpha = try Fixture.context(peer: 1)
        let bravo = try Fixture.context(peer: 2)
        let charlie = try Fixture.context(peer: 3)
        try Fixture.admit(&wrapper, Fixture.threeBatches(), alpha, at: 5)
        try Fixture.admit(&wrapper, Fixture.message(9), bravo, at: 5)
        let disallowed = try Fixture.message(0, "/nope")
        let valid = try Fixture.message(0)
        let regressed = Inner.nowRegressed(previous: Fixture.host(5), now: Fixture.host(4))
        // The helper checks, for every refusal, that a copy of the wrapper is equal to what it was before.
        #expect(Fixture.admitRefusal(wrapper, disallowed, charlie, at: 5) == .scheduling(.disallowedAddress("/nope")))
        #expect(Fixture.admitRefusal(wrapper, disallowed, alpha, at: 5) == .scheduling(.disallowedAddress("/nope")))
        #expect(Fixture.admitRefusal(wrapper, valid, charlie, at: 4) == .scheduling(regressed))
        #expect(wrapper.contextCount == 2)
        try Fixture.admit(&wrapper, Fixture.message(10), charlie, at: 5)
        let fourth = try Fixture.context(peer: 4)
        #expect(Fixture.admitRefusal(wrapper, valid, fourth, at: 5) == .contextTableFull(limit: 3))
        #expect(wrapper.contextCount == 3 && wrapper.taggedBatchCount == 5)
    }

    @Test func admitRefusalFromNewContextLeavesRoomForAnother() throws {
        var wrapper = try Fixture.wrapper(limit: 2)
        try Fixture.admit(&wrapper, Fixture.message(1), Fixture.context(peer: 1))
        let refused = try Fixture.admitRefusal(wrapper, Fixture.message(2, "/nope"), Fixture.context(peer: 2))
        #expect(refused == .scheduling(.disallowedAddress("/nope")))
        try Fixture.admit(&wrapper, Fixture.message(3), Fixture.context(peer: 3))
        #expect(wrapper.contextCount == 2 && wrapper.taggedBatchCount == 2)
    }

    @Test func admitInheritsPendingBatchCapacityAtTheEdge() throws {
        var wrapper = try Fixture.wrapper(limit: 1)
        let context = try Fixture.context()
        for value in 0..<256 {
            try Fixture.admit(&wrapper, Fixture.message(Int32(value)), context)
        }
        #expect(wrapper.pendingCount(for: context) == 256 && wrapper.taggedBatchCount == 256)
        let full = Inner.capacityExceeded(.pendingBatches, limit: 256)
        #expect(try Fixture.admitRefusal(wrapper, Fixture.message(256), context) == .scheduling(full))
    }

    @Test func admitFillsTwoHundredFiftySixContextsAndRefusesTheNext() throws {
        var wrapper = try Fixture.wrapper(limit: 256)
        let contexts = try Fixture.peers(257)
        for context in contexts.prefix(256) {
            try Fixture.admit(&wrapper, Fixture.message(0), context)
        }
        #expect(wrapper.contextCount == 256 && wrapper.taggedBatchCount == 256)
        let overflow = try #require(contexts.last)
        let first = try #require(contexts.first)
        let full = Inner.capacityExceeded(.pendingBatches, limit: 256)
        #expect(try Fixture.admitRefusal(wrapper, Fixture.message(1), overflow) == .contextTableFull(limit: 256))
        #expect(try Fixture.admitRefusal(wrapper, Fixture.message(1), first) == .scheduling(full))
    }

    @Test func wrapperEqualityIsSensitiveToTheContextOfAdmittedBatches() throws {
        let packet = try Fixture.threeBatches()
        var reference = try Fixture.wrapper()
        try Fixture.admit(&reference, packet, Fixture.context())
        var same = try Fixture.wrapper()
        try Fixture.admit(&same, packet, Fixture.context())
        #expect(same == reference)
        for field in ContextField.allCases {
            var other = try Fixture.wrapper()
            try Fixture.admit(&other, packet, Fixture.variant(field))
            #expect(other != reference, "\(field)")
        }
    }

    @Test func wrapperEqualitySeesWhichBatchHoldsWhichContext() throws {
        let alpha = try Fixture.context(peer: 1)
        let bravo = try Fixture.context(peer: 2)
        var forward = try Fixture.wrapper()
        try Fixture.admit(&forward, Fixture.message(1), alpha)
        try Fixture.admit(&forward, Fixture.message(2), bravo)
        var swapped = try Fixture.wrapper()
        try Fixture.admit(&swapped, Fixture.message(1), bravo)
        try Fixture.admit(&swapped, Fixture.message(2), alpha)
        #expect(forward.scheduler == swapped.scheduler && forward.contextCount == swapped.contextCount)
        #expect(forward.pendingCount(for: alpha) == swapped.pendingCount(for: alpha))
        #expect(forward != swapped)
    }
}

extension OSCReceiveContextTests {
    /// The four fields a receive context is compared by.
    enum ContextField: CaseIterable {
        case peer, hostEpoch, connectionEpoch, permission
    }

    /// Recipes: one host, one connection, one permission and an allow list of `/go`. Contexts are built from a real
    /// principal, so the host epoch and the connection epoch differ in generation (7 and 3).
    enum Fixture {
        static let unitTimebase = HostTimebase(numer: 1, denom: 1)
        static let referenceSeconds: UInt32 = 3_970_000_000
        static let anchorTicks: UInt64 = 10_000_000_000_000
        static let second: Int64 = 1_000_000_000
        static let hostID = HostID(validated: "host.osc")
        static let connectionID = ConnectionID(validated: "con.osc")
        static let fader = ParameterID(validated: "par.fader")
        static let basePermission = "perm.osc.1"

        /// The host stamp `offset` ticks after the anchor.
        static func host(_ offset: Int64) -> HostStamp {
            HostStamp(ticks: UInt64(Int64(anchorTicks) + offset))
        }

        /// The tag `seconds` after the reference instant.
        static func tag(after seconds: Int64) -> OSC.TimeTag {
            OSC.TimeTag(seconds: UInt32(truncatingIfNeeded: Int64(referenceSeconds) + seconds), fraction: 0)
        }

        static func policy(
            late: UInt64 = 1_000_000_000, batches: Int = 256, messages: Int = 4_096
        ) throws -> OSC.SchedulingPolicy {
            try OSC.SchedulingPolicy(
                lateHorizonNanoseconds: late, maximumFutureNanoseconds: 60_000_000_000, maximumPendingBatches: batches,
                maximumPendingMessages: messages, maximumBundleDepth: 8
            )
        }

        static func mapping() throws -> OSC.WallClockMapping {
            try OSC.WallClockMapping(
                wall: OSC.WallInstant(era: 0, seconds: referenceSeconds, fraction: 0),
                host: HostStamp(ticks: anchorTicks), uncertaintyNanoseconds: 0, ratePartsPerBillion: 0,
                rateUncertaintyPartsPerBillion: 0
            )
        }

        static func scheduler(_ policy: OSC.SchedulingPolicy? = nil) throws -> OSC.BundleScheduler {
            try OSC.BundleScheduler(
                timebase: unitTimebase, mapping: mapping(), policy: policy ?? Self.policy(),
                allowList: OSC.AllowList([OSC.AddressPattern("/go")])
            )
        }

        static func wrapper(limit: Int = 8, policy: OSC.SchedulingPolicy? = nil) throws -> Wrapper {
            try Wrapper(scheduler: scheduler(policy), maximumContexts: limit)
        }

        /// A `/go` message whose int argument identifies it in assertions.
        static func message(_ value: Int32 = 0, _ address: String = "/go") throws -> OSC.Packet {
            .message(OSC.Message(address: try OSC.AddressPattern(address), arguments: [.int32(value)]))
        }

        static func bundle(_ timeTag: OSC.TimeTag, _ elements: [OSC.Packet] = []) -> OSC.Packet {
            .bundle(OSC.Bundle(timeTag: timeTag, elements: elements))
        }

        /// A bundle at `timeTag` carrying one `/go` message per value: one batch.
        static func timed(_ timeTag: OSC.TimeTag, _ values: Int32...) throws -> OSC.Packet {
            bundle(timeTag, try values.map { try message($0) })
        }

        /// Three bundles, three batches: the outer bundle's own message now, and one inner bundle at +1 s and +2 s.
        static func threeBatches(_ first: Int32 = 1) throws -> OSC.Packet {
            bundle(.immediate, [
                try message(first), try timed(tag(after: 1), first + 1), try timed(tag(after: 2), first + 2)
            ])
        }

        /// An immediate bundle of `count` inner bundles at +1 s, +2 s and so on: `count` batches.
        static func spread(_ count: Int, first: Int32 = 1) throws -> OSC.Packet {
            bundle(.immediate, try (0..<count).map { step in
                try timed(tag(after: Int64(step) + 1), first + Int32(step))
            })
        }

        static func values(_ messages: [OSC.Message]) -> [Int32] {
            messages.map { if case .int32(let value) = $0.arguments.first { value } else { -1 } }
        }

        /// The first int argument of every message of every batch, in the order given.
        static func payloads(_ tagged: [OSC.TaggedBatch]) -> [Int32] {
            values(tagged.flatMap(\.batch.messages))
        }

        static func generation(_ value: Int) -> Generation {
            do { return try Generation(value) } catch { preconditionFailure("invalid generation \(value)") }
        }

        static func principal(
            hostGeneration: Int = 7, connectionGeneration: Int = 3, permission: String = basePermission
        ) throws -> OSC.Principal {
            try OSC.Principal(
                hostEpoch: HostEpoch(host: hostID, generation: generation(hostGeneration)),
                connectionEpoch: ConnectionEpoch(
                    connection: connectionID, host: hostID, generation: generation(connectionGeneration)
                ),
                permission: PermissionFingerprint(rawValue: permission),
                grants: [OSC.PrincipalGrant(controlClass: .live, scope: .parameter(fader))]
            )
        }

        static func peer(_ value: UInt64) -> OSC.PeerKey {
            OSC.PeerKey(rawValue: value)
        }

        static func context(
            peer value: UInt64 = 1, hostGeneration: Int = 7, connectionGeneration: Int = 3,
            permission: String = basePermission
        ) throws -> Context {
            let issued = try principal(
                hostGeneration: hostGeneration, connectionGeneration: connectionGeneration, permission: permission
            )
            return Context.make(principal: issued, peer: peer(value))
        }

        /// `count` contexts that differ in the peer key only (peers 0 through `count - 1`).
        static func peers(_ count: Int) throws -> [Context] {
            let issued = try principal()
            return (0..<count).map { Context.make(principal: issued, peer: peer(UInt64($0))) }
        }

        /// The context of `context()` with exactly one field changed.
        static func variant(_ field: ContextField) throws -> Context {
            switch field {
            case .peer: return try context(peer: 2)
            case .hostEpoch: return try context(hostGeneration: 8)
            case .connectionEpoch: return try context(connectionGeneration: 4)
            case .permission: return try context(permission: "perm.osc.2")
            }
        }

        static func differingFields(_ lhs: Context, _ rhs: Context) -> [ContextField] {
            var fields: [ContextField] = []
            if lhs.peer != rhs.peer { fields.append(.peer) }
            if lhs.hostEpoch != rhs.hostEpoch { fields.append(.hostEpoch) }
            if lhs.connectionEpoch != rhs.connectionEpoch { fields.append(.connectionEpoch) }
            if lhs.permission != rhs.permission { fields.append(.permission) }
            return fields
        }

        /// Admits `packet` under `context` at `now` ticks after the anchor and returns the batches queued.
        @discardableResult
        static func admit(
            _ wrapper: inout Wrapper, _ packet: OSC.Packet, _ context: Context, at now: Int64 = 0
        ) throws -> [OSC.ScheduledBatch] {
            try wrapper.admit(packet, context: context, now: host(now))
        }

        /// Runs `operation` on a copy of `wrapper` and returns its refusal. A refusal must leave the copy equal to
        /// `wrapper`: the copy compares the inner scheduler, the tags and the table, field by field.
        static func refusal<Value>(
            _ wrapper: Wrapper, sourceLocation: SourceLocation = #_sourceLocation,
            _ operation: (inout Wrapper) throws -> Value
        ) -> Refusal? {
            var copy = wrapper
            do {
                _ = try operation(&copy)
                return nil
            } catch {
                #expect(copy == wrapper, "a refusal changed the wrapper", sourceLocation: sourceLocation)
                return error as? Refusal
            }
        }

        static func admitRefusal(
            _ wrapper: Wrapper, _ packet: OSC.Packet, _ context: Context, at now: Int64 = 0,
            sourceLocation: SourceLocation = #_sourceLocation
        ) -> Refusal? {
            refusal(wrapper, sourceLocation: sourceLocation) { try $0.admit(packet, context: context, now: host(now)) }
        }
    }
}
