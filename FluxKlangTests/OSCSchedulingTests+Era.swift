import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// NTP eras, the 2036 wrap, reserved tags, fraction quantization and the
/// extremes of the 64-bit tag and host-tick ranges.
extension OSCSchedulingTests {
    @Test func wallInstantErasAreBounded() throws {
        #expect(throws: Refusal.eraOutOfRange(-1)) { try OSC.WallInstant(era: -1, seconds: 0, fraction: 0) }
        #expect(throws: Refusal.eraOutOfRange(256)) { try OSC.WallInstant(era: 256, seconds: 0, fraction: 0) }
        let last = try OSC.WallInstant(era: 255, seconds: .max, fraction: .max)
        #expect(last.era == 255 && last.timeTag == OSC.TimeTag(rawValue: .max))
        #expect(last.units == Int128(256) << 64 - 1)
        let first = try OSC.WallInstant(era: 0, seconds: 0, fraction: 0)
        #expect(first.units == 0 && first < last)
    }

    @Test func eraZeroEndsWhereEraOneBegins() throws {
        let end = try Fixture.wall(era: 0, seconds: .max, fraction: .max)
        let start = try Fixture.wall(era: 1, seconds: 0, fraction: 0)
        #expect(start.units - end.units == 1)
        #expect(start.description == "era 1 + 0 s + 0 / 2^32 s")
    }

    @Test func resolutionCrossesTheWrapForward() throws {
        let reference = try Fixture.wall(era: 0, seconds: .max - 10)
        let resolved = try reference.resolve(OSC.TimeTag(seconds: 5, fraction: 7))
        #expect(resolved == (try Fixture.wall(era: 1, seconds: 5, fraction: 7)))
        let before = try reference.resolve(OSC.TimeTag(seconds: .max - 20, fraction: 0))
        #expect(before.era == 0)
    }

    @Test func resolutionCrossesTheWrapBackward() throws {
        let reference = try Fixture.wall(era: 1, seconds: 10)
        let resolved = try reference.resolve(OSC.TimeTag(seconds: .max - 5, fraction: 0))
        #expect(resolved == (try Fixture.wall(era: 0, seconds: .max - 5)))
        #expect(try reference.resolve(OSC.TimeTag(seconds: 2, fraction: 0)).era == 1)
    }

    @Test func resolutionTieGoesToThePast() throws {
        let reference = try Fixture.wall(era: 0, seconds: (1 << 31) + 100)
        let tie = try reference.resolve(OSC.TimeTag(seconds: 100, fraction: 0))
        #expect(tie == (try Fixture.wall(era: 0, seconds: 100)))
        let justInside = try reference.resolve(OSC.TimeTag(seconds: 99, fraction: .max))
        #expect(justInside == (try Fixture.wall(era: 1, seconds: 99, fraction: .max)))
        let wrapped = try Fixture.wall(era: 1, seconds: 100)
        #expect(try wrapped.resolve(OSC.TimeTag(seconds: (1 << 31) + 100, fraction: 0)).era == 0)
        #expect(try wrapped.resolve(OSC.TimeTag(seconds: (1 << 31) + 100, fraction: 1)).era == 0)
        #expect(try wrapped.resolve(OSC.TimeTag(seconds: (1 << 31) + 99, fraction: .max)).era == 1)
    }

    @Test func referenceAtTheWrapResolvesBothNeighbours() throws {
        let reference = try Fixture.wall(era: 0, seconds: .max, fraction: .max)
        #expect(try reference.resolve(OSC.TimeTag(rawValue: 2)) == (try Fixture.wall(era: 1, seconds: 0, fraction: 2)))
        #expect(try reference.resolve(OSC.TimeTag(rawValue: .max)) == reference)
        let start = try Fixture.wall(era: 1, seconds: 0, fraction: 0)
        #expect(try start.resolve(OSC.TimeTag(rawValue: .max)) == reference)
    }

    @Test func resolutionOutsideSupportedErasIsRefused() throws {
        let first = try Fixture.wall(era: 0, seconds: 10)
        #expect(throws: Refusal.eraOutOfRange(-1)) { try first.resolve(OSC.TimeTag(seconds: .max - 10, fraction: 0)) }
        let last = try Fixture.wall(era: 255, seconds: .max - 10)
        #expect(throws: Refusal.eraOutOfRange(256)) { try last.resolve(OSC.TimeTag(seconds: 10, fraction: 0)) }
        let mapping = try Fixture.mapping(wall: first)
        let scheduler = try Fixture.scheduler(mapping: mapping)
        let tag = OSC.TimeTag(seconds: .max - 10, fraction: 0)
        let packet = Fixture.bundle(tag, [try Fixture.message()])
        #expect(Fixture.refusal(scheduler) { try $0.admit(packet, now: Fixture.host(0)) } == .eraOutOfRange(-1))
    }

    @Test func schedulerResolvesTagsAcrossTheWrap() throws {
        let mapping = try Fixture.mapping(wall: Fixture.wall(seconds: .max - 9))
        var scheduler = try Fixture.scheduler(mapping: mapping)
        let tag = OSC.TimeTag(seconds: 5, fraction: 0)
        let batch = try Fixture.single(&scheduler, Fixture.timed(tag, 0))
        #expect(batch.wall == (try Fixture.wall(era: 1, seconds: 5)))
        #expect(Fixture.offsets(batch.window) == [15 * Fixture.second, 15 * Fixture.second + 1])
    }

    @Test(arguments: [
        (0, [0, 1]), (1, [0, 1]), (5, [1, 2]), (1 << 31, [500_000_000, 500_000_001]),
        (.max, [999_999_999, 1_000_000_000])
    ] as [(UInt32, [Int64])])
    func fractionQuantumRoundsOutwardToWholeNanoseconds(fraction: UInt32, expected: [Int64]) throws {
        let mapping = try Fixture.mapping()
        let instant = try Fixture.wall(fraction: fraction)
        let bounds = try mapping.hostBounds(of: instant, timebase: Fixture.unitTimebase)
        let offsets = [bounds.earliest, bounds.latest].map { Int64($0) - Int64(Fixture.anchorTicks) }
        #expect(offsets == expected)
    }

    @Test(arguments: [
        (0, [0, 1]), (1 << 31, [12_000_000, 12_000_001]), (.max, [23_999_999, 24_000_000])
    ] as [(UInt32, [Int64])])
    func appleTimebaseQuantumNeverClaimsSubTickPrecision(fraction: UInt32, expected: [Int64]) throws {
        let instant = try Fixture.wall(fraction: fraction)
        let bounds = try Fixture.mapping().hostBounds(of: instant, timebase: Fixture.appleTimebase)
        #expect([bounds.earliest, bounds.latest].map { Int64($0) - Int64(Fixture.anchorTicks) } == expected)
    }

    /// The window is the tightest whole-tick cover of the exact quantum: one more
    /// tick inward on either side would exclude part of it.
    @Test func windowIsTheTightestOutwardCoverOfTheQuantum() throws {
        var generator = OSCSchedulingGenerator(seed: 0x90_7151)
        let mapping = try Fixture.mapping()
        for _ in 0..<2_000 {
            let delta = Int128(Int64(bitPattern: generator.next()) >> 2)
            let timebase = generator.next().isMultiple(of: 2) ? Fixture.unitTimebase : Fixture.appleTimebase
            let raw = UInt64(truncatingIfNeeded: mapping.wall.units + delta)
            let instant = try mapping.wall.resolve(OSC.TimeTag(rawValue: raw))
            let bounds = try mapping.hostBounds(of: instant, timebase: timebase)
            let start = (instant.units - mapping.wall.units) * 1_000_000_000 * Int128(timebase.denom)
            let end = start + 1_000_000_000 * Int128(timebase.denom)
            let tick = Int128(timebase.numer) << 32
            let low = bounds.earliest - Int128(Fixture.anchorTicks)
            let high = bounds.latest - Int128(Fixture.anchorTicks)
            #expect(low * tick <= start && (low + 1) * tick > start)
            #expect(high * tick >= end && (high - 1) * tick < end)
        }
    }

    @Test func largestTagIsAnOrdinaryInstant() throws {
        let limit = OSC.SchedulingPolicy.futureHorizonLimitNanoseconds
        var scheduler = try Fixture.scheduler(policy: Fixture.policy(future: limit))
        let largest = OSC.TimeTag(rawValue: .max)
        let batch = try Fixture.single(&scheduler, Fixture.timed(largest, 0))
        #expect(batch.wall == (try Fixture.wall(era: 0, seconds: .max, fraction: .max)))
        #expect(Fixture.offsets(batch.window) == [324_967_295_999_999_999, 324_967_296_000_000_000])
        let refused = try Fixture.scheduler()
        let packet = Fixture.bundle(largest, [try Fixture.message()])
        #expect(Fixture.refusal(refused) { try $0.admit(packet, now: Fixture.host(0)) } == .tooFarInFuture(largest))
    }

    @Test func largestTagResolvesIntoThePastAfterTheWrap() throws {
        let mapping = try Fixture.mapping(wall: Fixture.wall(era: 1, seconds: 1))
        var scheduler = try Fixture.scheduler(mapping: mapping, policy: Fixture.policy(late: 3_000_000_000))
        let largest = OSC.TimeTag(rawValue: .max)
        let batch = try Fixture.single(&scheduler, Fixture.timed(largest, 0))
        #expect(batch.wall?.era == 0)
        #expect(Fixture.offsets(batch.window) == [-Fixture.second - 1, -Fixture.second])
        #expect(batch.timing == .late(by: UInt64(Fixture.second)))
    }

    @Test func smallestNonReservedTagsResolveNormally() throws {
        let mapping = try Fixture.mapping(wall: Fixture.wall(era: 1, seconds: 0))
        var scheduler = try Fixture.scheduler(mapping: mapping)
        let tag = OSC.TimeTag(rawValue: 2)
        let batch = try Fixture.single(&scheduler, Fixture.timed(tag, 0))
        #expect(batch.wall == (try Fixture.wall(era: 1, seconds: 0, fraction: 2)))
        #expect(Fixture.offsets(batch.window) == [0, 1])
    }

    @Test func pastTheHostOriginIsTooLateBeforeItIsUnrepresentable() throws {
        let mapping = try Fixture.mapping(host: 0)
        let scheduler = try Fixture.scheduler(mapping: mapping)
        let past = Fixture.tag(after: -5)
        let packet = Fixture.bundle(past, [try Fixture.message()])
        #expect(Fixture.refusal(scheduler) { try $0.admit(packet, now: HostStamp(ticks: 0)) } == .tooLate(past))
        let lenient = try Fixture.scheduler(mapping: mapping, policy: Fixture.policy(late: .max))
        let unrepresentable = Fixture.refusal(lenient) { try $0.admit(packet, now: HostStamp(ticks: 0)) }
        #expect(unrepresentable == .hostTimeOutOfRange(past))
    }

    /// No host tick precedes 0: a window straddling the origin keeps its
    /// representable part, which still contains every possible tick of the instant.
    @Test func windowStraddlingTheHostOriginIsClampedToIt() throws {
        let mapping = try Fixture.mapping(host: 0, uncertainty: 1)
        var scheduler = try Fixture.scheduler(mapping: mapping)
        let bounds = try mapping.hostBounds(of: Fixture.wall(), timebase: Fixture.unitTimebase)
        #expect(bounds.earliest == -1 && bounds.latest == 2)
        let packet = try Fixture.timed(Fixture.tag(after: 0), 0)
        let batch = try #require(try scheduler.admit(packet, now: HostStamp(ticks: 0)).first)
        #expect(batch.window.earliest == HostStamp(ticks: 0) && batch.window.latest == HostStamp(ticks: 2))
        #expect(batch.timing == .onTime)
        var exact = try Fixture.scheduler(mapping: Fixture.mapping(host: 0))
        let justBefore = try Fixture.timed(Fixture.tag(after: -1, fraction: .max), 0)
        let touching = try #require(try exact.admit(justBefore, now: HostStamp(ticks: 0)).first)
        #expect(touching.window.earliest == HostStamp(ticks: 0) && touching.window.latest == HostStamp(ticks: 0))
    }

    @Test func pastTheLastHostTickIsClampedOrUnrepresentable() throws {
        let mapping = try Fixture.mapping(host: .max)
        let scheduler = try Fixture.scheduler(mapping: mapping)
        let next = Fixture.tag(after: 1)
        let packet = Fixture.bundle(next, [try Fixture.message()])
        let refusal = Fixture.refusal(scheduler) { try $0.admit(packet, now: HostStamp(ticks: .max)) }
        #expect(refusal == .hostTimeOutOfRange(next))
        let edge = Fixture.bundle(Fixture.tag(after: 0), [try Fixture.message()])
        var accepted = scheduler
        let batch = try #require(try accepted.admit(edge, now: HostStamp(ticks: .max)).first)
        #expect(batch.window.earliest == HostStamp(ticks: .max) && batch.window.latest == HostStamp(ticks: .max))
    }

    @Test func extremeTimebasesStayExactOrRefuse() throws {
        let tiny = HostTimebase(numer: 1, denom: .max)
        var fine = try Fixture.scheduler(timebase: tiny)
        let soon = Fixture.bundle(Fixture.tag(after: 2), [try Fixture.message()])
        let batch = try #require(try fine.admit(soon, now: Fixture.host(0)).first)
        #expect(Fixture.offsets(batch.window) == [8_589_934_590_000_000_000, 8_589_934_591_000_000_000])
        let later = Fixture.tag(after: 5)
        let refused = try Fixture.scheduler(timebase: tiny)
        let packet = Fixture.bundle(later, [try Fixture.message()])
        #expect(Fixture.refusal(refused) { try $0.admit(packet, now: Fixture.host(0)) } == .hostTimeOutOfRange(later))
        var coarse = try Fixture.scheduler(timebase: HostTimebase(numer: .max, denom: 1))
        let window = try #require(try coarse.admit(soon, now: Fixture.host(0)).first).window
        #expect(Fixture.offsets(window) == [0, 1])
    }

    @Test func boundsBeyondInt128AreTypedRefusals() throws {
        let mapping = try Fixture.mapping(wall: Fixture.wall(era: 0, seconds: 0), rateUncertainty: 1_000_000)
        let far = try Fixture.wall(era: 255, seconds: .max, fraction: .max)
        let tiny = HostTimebase(numer: 1, denom: .max)
        #expect(throws: Refusal.arithmeticOverflow) { try mapping.hostBounds(of: far, timebase: tiny) }
        #expect(throws: Refusal.invalidTimebase(numer: 0, denom: 1)) {
            try mapping.hostBounds(of: far, timebase: HostTimebase(numer: 0, denom: 1))
        }
        let bounds = try mapping.hostBounds(of: far, timebase: Fixture.unitTimebase)
        #expect(bounds.earliest > Int128(UInt64.max))
    }
}

/// SplitMix64, seeded, so property sweeps are reproducible.
private struct OSCSchedulingGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
