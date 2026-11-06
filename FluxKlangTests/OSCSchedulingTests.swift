import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// Shared fixture for the OSC scheduling suites. With the unit timebase one
/// host tick is one nanosecond; the anchor pairs `referenceSeconds` (era 0,
/// late 2025) with host tick `anchorTicks`.
enum OSCSchedulingFixture {
    typealias OSC = OpenSoundControl
    typealias Refusal = OpenSoundControl.SchedulingRefusal

    static let unitTimebase = HostTimebase(numer: 1, denom: 1)
    /// Apple silicon: one tick is 125/3 ns, so one second is exactly 24 000 000 ticks.
    static let appleTimebase = HostTimebase(numer: 125, denom: 3)
    static let referenceSeconds: UInt32 = 3_970_000_000
    static let anchorTicks: UInt64 = 10_000_000_000_000
    static let second: Int64 = 1_000_000_000

    /// The host stamp `offset` ticks after the anchor.
    static func host(_ offset: Int64) -> HostStamp {
        HostStamp(ticks: UInt64(Int64(anchorTicks) + offset))
    }

    /// The tag `seconds` after the reference, wrapping like the 32-bit field does.
    static func tag(after seconds: Int64, fraction: UInt32 = 0) -> OSC.TimeTag {
        OSC.TimeTag(seconds: UInt32(truncatingIfNeeded: Int64(referenceSeconds) + seconds), fraction: fraction)
    }

    static func wall(era: Int = 0, seconds: UInt32 = referenceSeconds, fraction: UInt32 = 0) throws -> OSC.WallInstant {
        try OSC.WallInstant(era: era, seconds: seconds, fraction: fraction)
    }

    static func mapping(
        wall: OSC.WallInstant? = nil, host: UInt64 = anchorTicks, uncertainty: UInt64 = 0,
        rate: Int = 0, rateUncertainty: Int = 0
    ) throws -> OSC.WallClockMapping {
        try OSC.WallClockMapping(
            wall: wall ?? Self.wall(), host: HostStamp(ticks: host), uncertaintyNanoseconds: uncertainty,
            ratePartsPerBillion: rate, rateUncertaintyPartsPerBillion: rateUncertainty
        )
    }

    static func policy(
        late: UInt64 = 1_000_000_000, future: UInt64 = 60_000_000_000, batches: Int = 256, messages: Int = 4_096,
        depth: Int = 8
    ) throws -> OSC.SchedulingPolicy {
        try OSC.SchedulingPolicy(
            lateHorizonNanoseconds: late, maximumFutureNanoseconds: future, maximumPendingBatches: batches,
            maximumPendingMessages: messages, maximumBundleDepth: depth
        )
    }

    static func allowList() throws -> OSC.AllowList {
        try OSC.AllowList(["/go", "/mixer/*/fader", "/fx/[1-4]/on"].map { try OSC.AddressPattern($0) })
    }

    static func scheduler(
        timebase: HostTimebase = unitTimebase, mapping: OSC.WallClockMapping? = nil, policy: OSC.SchedulingPolicy? = nil
    ) throws -> OSC.BundleScheduler {
        try OSC.BundleScheduler(
            timebase: timebase, mapping: mapping ?? Self.mapping(), policy: policy ?? Self.policy(),
            allowList: allowList()
        )
    }

    /// A message whose int argument identifies it in batch assertions.
    static func message(_ value: Int32 = 0, _ address: String = "/go") throws -> OSC.Packet {
        .message(OSC.Message(address: try OSC.AddressPattern(address), arguments: [.int32(value)]))
    }

    static func bundle(_ timeTag: OSC.TimeTag, _ elements: [OSC.Packet] = []) -> OSC.Packet {
        .bundle(OSC.Bundle(timeTag: timeTag, elements: elements))
    }

    /// Admits `packet` at `now` ticks after the anchor and returns its only batch.
    static func single(
        _ scheduler: inout OSC.BundleScheduler, _ packet: OSC.Packet, at now: Int64 = 0,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> OSC.ScheduledBatch {
        let batches = try scheduler.admit(packet, now: host(now))
        return try #require(batches.count == 1 ? batches.first : nil, sourceLocation: sourceLocation)
    }

    /// A bundle of `/go` messages carrying `values`.
    static func timed(_ timeTag: OSC.TimeTag, _ values: Int32...) throws -> OSC.Packet {
        bundle(timeTag, try values.map { try message($0) })
    }

    /// The reference instant moved by `seconds` within era 0.
    static func instant(after seconds: Int64) throws -> OSC.WallInstant {
        try wall(seconds: UInt32(Int64(referenceSeconds) + seconds))
    }

    /// The default mapping with its wall clock stepped by `seconds` at the same host anchor.
    static func stepped(by seconds: Int64) throws -> OSC.WallClockMapping {
        try mapping(wall: instant(after: seconds))
    }

    static func values(_ messages: [OSC.Message]) -> [Int32] {
        messages.map { if case .int32(let value) = $0.arguments.first { value } else { -1 } }
    }

    /// Window bounds as tick offsets from the anchor.
    static func offsets(_ window: OSC.HostWindow) -> [Int64] {
        [Int64(window.earliest.ticks) - Int64(anchorTicks), Int64(window.latest.ticks) - Int64(anchorTicks)]
    }

    static func offsets(_ bounds: (earliest: Int128, latest: Int128)) -> [Int64] {
        [Int64(bounds.earliest - Int128(anchorTicks)), Int64(bounds.latest - Int128(anchorTicks))]
    }

    /// Runs `operation` on a copy and returns its refusal, checking the refusal left the copy unchanged.
    static func refusal<Value>(
        _ scheduler: OSC.BundleScheduler, sourceLocation: SourceLocation = #_sourceLocation,
        _ operation: (inout OSC.BundleScheduler) throws -> Value
    ) -> Refusal? {
        var copy = scheduler
        do {
            _ = try operation(&copy)
            return nil
        } catch {
            #expect(copy == scheduler, "a refusal changed the scheduler", sourceLocation: sourceLocation)
            #expect(error is Refusal, "not a scheduling refusal: \(error)", sourceLocation: sourceLocation)
            return error as? Refusal
        }
    }
}

@Suite("OSC timetag scheduling")
struct OSCSchedulingTests {
    typealias Fixture = OSCSchedulingFixture
    typealias OSC = OpenSoundControl

    @Test func bareMessageDispatchesAtOnce() throws {
        var scheduler = try Fixture.scheduler()
        let batches = try scheduler.admit(Fixture.message(7), now: Fixture.host(5))
        let batch = try #require(batches.first)
        #expect(batches.count == 1)
        #expect(batch.timeTag == .immediate && batch.wall == nil && batch.timing == .onTime)
        #expect(Fixture.offsets(batch.window) == [5, 5])
        #expect(batch.id.value == 0 && batch.arrival == 0 && batch.bundleIndex == 0)
        #expect(Fixture.values(batch.messages) == [7])
        #expect(scheduler.pending == batches && scheduler.pendingMessageCount == 1)
        #expect(scheduler.latestNow == Fixture.host(5))
    }

    @Test func timedBundleResolvesToHostWindow() throws {
        var scheduler = try Fixture.scheduler()
        let tag = Fixture.tag(after: 2)
        let packet = Fixture.bundle(tag, [try Fixture.message(1), try Fixture.message(2, "/mixer/3/fader")])
        let batch = try #require(try scheduler.admit(packet, now: Fixture.host(0)).first)
        #expect(batch.timeTag == tag && batch.timing == .onTime)
        #expect(batch.wall == (try Fixture.wall(seconds: Fixture.referenceSeconds + 2)))
        #expect(Fixture.offsets(batch.window) == [2 * Fixture.second, 2 * Fixture.second + 1])
        #expect(Fixture.values(batch.messages) == [1, 2])
        #expect(scheduler.pendingMessageCount == 2)
    }

    @Test func immediateTopLevelBundleDispatchesAtOnce() throws {
        var scheduler = try Fixture.scheduler()
        let batch = try #require(
            try scheduler.admit(Fixture.bundle(.immediate, [try Fixture.message()]), now: Fixture.host(9)).first
        )
        #expect(batch.timeTag == .immediate && batch.wall == nil)
        #expect(Fixture.offsets(batch.window) == [9, 9])
    }

    @Test func rawZeroIsReservedAtAnyDepth() throws {
        let scheduler = try Fixture.scheduler()
        let zero = OSC.TimeTag(rawValue: 0)
        let top = Fixture.bundle(zero, [try Fixture.message()])
        #expect(Fixture.refusal(scheduler) { try $0.admit(top, now: Fixture.host(0)) } == .reservedTimeTag(zero))
        let nested = Fixture.bundle(Fixture.tag(after: 1), [try Fixture.message(), Fixture.bundle(zero)])
        #expect(Fixture.refusal(scheduler) { try $0.admit(nested, now: Fixture.host(0)) } == .reservedTimeTag(zero))
        #expect(throws: Refusal.reservedTimeTag(zero)) {
            try OSC.ImmediateStage.admit(top, allowList: Fixture.allowList())
        }
    }

    @Test func immediateInnerBundleInheritsEnclosingTime() throws {
        var scheduler = try Fixture.scheduler()
        let outer = Fixture.tag(after: 3)
        let inner = try Fixture.timed(.immediate, 2)
        let packet = Fixture.bundle(outer, [try Fixture.message(1), inner])
        let batches = try scheduler.admit(packet, now: Fixture.host(0))
        #expect(batches.map(\.bundleIndex) == [0, 1])
        #expect(batches.map(\.timeTag) == [outer, outer])
        #expect(batches[1].window == batches[0].window && batches[1].wall == batches[0].wall)
    }

    @Test func timedInnerBundlesOfImmediateOuterAreBoundedOnlyByHorizons() throws {
        var scheduler = try Fixture.scheduler()
        let late = Fixture.tag(after: -1, fraction: 1 << 31)
        let packet = Fixture.bundle(.immediate, [
            Fixture.bundle(Fixture.tag(after: 2), [try Fixture.message(1)]),
            Fixture.bundle(late, [try Fixture.message(2)])
        ])
        let batches = try scheduler.admit(packet, now: Fixture.host(0))
        #expect(batches.map(\.timing) == [.onTime, .late(by: UInt64(Fixture.second / 2 - 1))])
        #expect(Fixture.values(scheduler.pending.flatMap(\.messages)) == [2, 1])
    }

    @Test func earlierInnerTagRefusesTheWholePacket() throws {
        let scheduler = try Fixture.scheduler()
        let outer = Fixture.tag(after: 10)
        let inner = Fixture.tag(after: 5)
        let packet = Fixture.bundle(outer, [try Fixture.message(), Fixture.bundle(inner, [try Fixture.message()])])
        #expect(Fixture.refusal(scheduler) { try $0.admit(packet, now: Fixture.host(0)) }
            == .nestedTimeTagEarlier(enclosing: outer, inner: inner))
        let grand = Fixture.tag(after: 9)
        let deep = Fixture.bundle(outer, [Fixture.bundle(.immediate, [Fixture.bundle(grand, [try Fixture.message()])])])
        #expect(Fixture.refusal(scheduler) { try $0.admit(deep, now: Fixture.host(0)) }
            == .nestedTimeTagEarlier(enclosing: outer, inner: grand))
        let seven = Fixture.tag(after: 7)
        let middle = Fixture.bundle(outer, [try Fixture.message(), Fixture.bundle(seven, [try Fixture.message()])])
        let three = Fixture.bundle(Fixture.tag(after: 5), [middle])
        #expect(Fixture.refusal(scheduler) { try $0.admit(three, now: Fixture.host(0)) }
            == .nestedTimeTagEarlier(enclosing: outer, inner: seven))
    }

    @Test func nestingBoundaryIsOneFractionUnit() throws {
        let scheduler = try Fixture.scheduler()
        let outer = Fixture.tag(after: 10)
        let same = Fixture.bundle(outer, [Fixture.bundle(outer, [try Fixture.message()])])
        var accepted = scheduler
        #expect(try accepted.admit(same, now: Fixture.host(0)).count == 1)
        let earlier = Fixture.tag(after: 9, fraction: .max)
        let packet = Fixture.bundle(outer, [Fixture.bundle(earlier, [try Fixture.message()])])
        #expect(Fixture.refusal(scheduler) { try $0.admit(packet, now: Fixture.host(0)) }
            == .nestedTimeTagEarlier(enclosing: outer, inner: earlier))
    }

    @Test func nestingComparesResolvedInstantsAcrossTheWrap() throws {
        let mapping = try Fixture.mapping(wall: Fixture.wall(seconds: .max - 10))
        let scheduler = try Fixture.scheduler(mapping: mapping)
        let beforeWrap = OSC.TimeTag(seconds: .max - 2, fraction: 0)
        let afterWrap = OSC.TimeTag(seconds: 3, fraction: 0)
        var accepted = scheduler
        let forward = Fixture.bundle(beforeWrap, [Fixture.bundle(afterWrap, [try Fixture.message()])])
        let batch = try #require(try accepted.admit(forward, now: Fixture.host(0)).first)
        #expect(batch.wall?.era == 1)
        let backward = Fixture.bundle(afterWrap, [Fixture.bundle(beforeWrap, [try Fixture.message()])])
        #expect(Fixture.refusal(scheduler) { try $0.admit(backward, now: Fixture.host(0)) }
            == .nestedTimeTagEarlier(enclosing: afterWrap, inner: beforeWrap))
    }

    @Test func disallowedMessageAnywhereRefusesTheWholePacket() throws {
        let scheduler = try Fixture.scheduler()
        let packet = Fixture.bundle(Fixture.tag(after: 1), [
            try Fixture.message(1),
            Fixture.bundle(Fixture.tag(after: 2), [try Fixture.message(2), try Fixture.message(3, "/secret")])
        ])
        let refusal = Fixture.refusal(scheduler) { try $0.admit(packet, now: Fixture.host(0)) }
        #expect(refusal == .disallowedAddress("/secret"))
        #expect(throws: Refusal.disallowedAddress("/secret")) {
            try OSC.ImmediateStage.admit(try Fixture.message(0, "/secret"), allowList: Fixture.allowList())
        }
    }

    @Test func incomingWildcardAddressesAreRefused() throws {
        let scheduler = try Fixture.scheduler()
        let packet = try Fixture.message(0, "/mixer/*/fader")
        #expect(Fixture.refusal(scheduler) { try $0.admit(packet, now: Fixture.host(0)) }
            == .wildcardAddress("/mixer/*/fader"))
        let braces = try Fixture.message(0, "/{go}")
        #expect(Fixture.refusal(scheduler) { try $0.admit(braces, now: Fixture.host(0)) } == .wildcardAddress("/{go}"))
    }

    @Test(arguments: [
        ("/go", true), ("/fx/1/on", true), ("/fx/4/on", true), ("/fx/5/on", false), ("/mixer/12/fader", true),
        ("/mixer/1/2/fader", false), ("/go/now", false), ("/g", false)
    ])
    func allowListEntriesArePatternsOverLiteralAddresses(address: String, allowed: Bool) throws {
        let message = OSC.Message(address: try OSC.AddressPattern(address))
        let allowList = try Fixture.allowList()
        var refusal: Refusal?
        do { try allowList.admit(message) } catch { refusal = error }
        #expect(refusal == (allowed ? nil : .disallowedAddress(address)))
    }

    @Test func allowListSizeIsBounded() throws {
        let entry = try OSC.AddressPattern("/go")
        #expect(throws: Refusal.invalidAllowList(count: 0)) { try OSC.AllowList([]) }
        #expect(try OSC.AllowList(Array(repeating: entry, count: OSC.AllowList.maximumEntries)).entries.count == 256)
        #expect(throws: Refusal.invalidAllowList(count: 257)) { try OSC.AllowList(Array(repeating: entry, count: 257)) }
    }

    @Test func bundleDepthIsBoundedAtNAndNPlusOne() throws {
        let scheduler = try Fixture.scheduler(policy: Fixture.policy(depth: 2))
        let tag = Fixture.tag(after: 1)
        let two = Fixture.bundle(tag, [Fixture.bundle(tag, [try Fixture.message()])])
        var accepted = scheduler
        #expect(try accepted.admit(two, now: Fixture.host(0)).map(\.bundleIndex) == [1])
        let three = Fixture.bundle(tag, [two])
        #expect(Fixture.refusal(scheduler) { try $0.admit(three, now: Fixture.host(0)) } == .bundleTooDeep(limit: 2))
        #expect(throws: Refusal.bundleTooDeep(limit: 2)) {
            try OSC.ImmediateStage.admit(
                Fixture.bundle(.immediate, [Fixture.bundle(.immediate, [Fixture.bundle(.immediate)])]),
                allowList: Fixture.allowList(), maximumBundleDepth: 2
            )
        }
    }

    @Test func refusalsFollowPlanningOrder() throws {
        let scheduler = try Fixture.scheduler()
        let late = Fixture.tag(after: -5)
        let ownTagFirst = Fixture.bundle(late, [try Fixture.message(0, "/secret")])
        #expect(Fixture.refusal(scheduler) { try $0.admit(ownTagFirst, now: Fixture.host(0)) } == .tooLate(late))
        let zero = OSC.TimeTag(rawValue: 0)
        let messagesBeforeChildren = Fixture.bundle(.immediate, [Fixture.bundle(zero), try Fixture.message(0, "/x")])
        #expect(Fixture.refusal(scheduler) { try $0.admit(messagesBeforeChildren, now: Fixture.host(0)) }
            == .disallowedAddress("/x"))
    }

    @Test func immediateStageReportsUnsupportedScheduling() throws {
        let allow = try Fixture.allowList()
        let tag = Fixture.tag(after: 1)
        #expect(throws: Refusal.unsupportedScheduling(tag)) {
            try OSC.ImmediateStage.admit(Fixture.bundle(tag, [try Fixture.message()]), allowList: allow)
        }
        let nested = Fixture.bundle(.immediate, [try Fixture.message(), Fixture.bundle(tag)])
        #expect(throws: Refusal.unsupportedScheduling(tag)) { try OSC.ImmediateStage.admit(nested, allowList: allow) }
    }

    @Test func immediateStageDispatchesImmediateContentInBatches() throws {
        let allow = try Fixture.allowList()
        let packet = Fixture.bundle(.immediate, [
            try Fixture.message(1), Fixture.bundle(.immediate, [try Fixture.message(2)]), try Fixture.message(3)
        ])
        #expect(try OSC.ImmediateStage.admit(packet, allowList: allow).map(Fixture.values) == [[1, 3], [2]])
        #expect(try OSC.ImmediateStage.admit(try Fixture.message(4), allowList: allow).map(Fixture.values) == [[4]])
        #expect(try OSC.ImmediateStage.admit(Fixture.bundle(.immediate), allowList: allow).isEmpty)
    }

    @Test func emptyBundleAdmitsNothingButItsArrival() throws {
        var scheduler = try Fixture.scheduler()
        #expect(try scheduler.admit(Fixture.bundle(Fixture.tag(after: 1)), now: Fixture.host(0)).isEmpty)
        let next = try #require(try scheduler.admit(Fixture.message(), now: Fixture.host(0)).first)
        #expect(next.arrival == 1 && next.id.value == 0)
    }

    typealias Refusal = OSC.SchedulingRefusal
}
