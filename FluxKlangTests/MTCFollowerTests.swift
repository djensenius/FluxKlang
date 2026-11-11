import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// The pure MTC follower (#85 X2). The topic suites live in `MTCFollowerTests+*.swift` extensions.
#if os(macOS)
@Suite("MTCFollower", .productionAccessAudit)
#else
@Suite("MTCFollower")
#endif
struct MTCFollowerTests {
    @Test func aNewFollowerIsAbsentWithNoPositionAndNoCounters() throws {
        let follower = try Self.follower()
        #expect(follower.state == .absent)
        #expect(follower.rate == nil)
        #expect(follower.direction == nil)
        #expect(follower.consecutivePositions == 0)
        #expect(follower.counters == MTCFollowerCounters())
        #expect(Self.thrown { try follower.frameCount(at: Self.stamp(5)) } == .noPosition)
        #expect(Self.thrown { try follower.host(forFrameCount: 5) } == .noPosition)
    }

    @Test func followerFactoryRefusesAnInvalidTimebase() throws {
        let zeroNumerator = HostTimebase(numer: 0, denom: 1)
        let zeroDenominator = HostTimebase(numer: 1, denom: 0)
        #expect(Self.thrown { try MTCFollower.make(policy: .standard, timebase: zeroNumerator) } == .invalidTimebase)
        #expect(Self.thrown { try MTCFollower.make(policy: .standard, timebase: zeroDenominator) } == .invalidTimebase)
        let smallest = HostTimebase(numer: 1, denom: 1)
        #expect(Self.thrown { try MTCFollower.make(policy: .standard, timebase: smallest) } == nil)
    }

    @Test func theSameStreamTwiceProducesIdenticalEventsAndSnapshots() throws {
        let sequences = try Self.stream(rate: .fps2997DropFrame, direction: .reverse, firstEncoded: 5000, count: 4)
        var first = try Self.follower()
        var second = try Self.follower()
        let firstEvents = try Self.feed(&first, sequences)
        let secondEvents = try Self.feed(&second, sequences)
        #expect(firstEvents == secondEvents)
        #expect(firstEvents == [.locked(frameCount: 5000 - 2 - 2 * 1)])
        #expect(first.snapshot == second.snapshot)
    }
}
