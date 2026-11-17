import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

// MARK: - Removing a driver's stream (#83)

extension UMPTranslationStreamTests {
    @Test func removeSendsTheHeldDataEntryForgetsTheStreamAndCancelsTheTimer() async throws {
        let fixture = Fixture()
        try await Self.hold(fixture, Self.one, at: 0)
        await fixture.driver.remove(Self.one)
        #expect(fixture.sink.received == [try Self.batch(15)])
        #expect(fixture.sink.streams == [Self.one])
        #expect(await fixture.driver.stream(Self.one) == nil)
        #expect(fixture.timer.armedAt == nil)
        #expect(fixture.timer.cancelCount == 1)
    }

    @Test func removingTheStreamWithTheEarlierDeadlineRearmsTheTimerForTheOther() async throws {
        let fixture = Fixture()
        try await Self.hold(fixture, Self.two, at: 12 * Self.msec, value: 20, channel: 1)
        try await Self.hold(fixture, Self.one, at: 10 * Self.msec)
        #expect(fixture.timer.armedAt == 15 * Self.msec)
        await fixture.driver.remove(Self.one)
        #expect(fixture.sink.received == [try Self.batch(15)])
        #expect(fixture.timer.armedAt == 17 * Self.msec)
        await fixture.fire(at: 17 * Self.msec)
        #expect(fixture.sink.received == [try Self.batch(15), try Self.batch(20, channel: 1)])
        #expect(fixture.sink.streams == [Self.one, Self.two])
        #expect(fixture.timer.armedAt == nil)
    }

    /// The removed stream's last accepted time (20 ms) and its late poll's baseline (30 ms) are gone: an event stamped
    /// 10 ms is accepted at its own stamp, and the new stream's telemetry starts at zero.
    @Test func aReceiveAfterRemoveStartsAFreshStream() async throws {
        let fixture = Fixture()
        try await Self.hold(fixture, Self.one, at: 20 * Self.msec)
        await fixture.fire(at: 30 * Self.msec)
        #expect(fixture.sink.received == [try Self.batch(15)])
        #expect(await fixture.driver.stream(Self.one)?.idleFlushes == 1)
        await fixture.driver.remove(Self.one)
        #expect(fixture.sink.received.count == 1)
        try await Self.hold(fixture, Self.one, at: 10 * Self.msec)
        let stream = try #require(await fixture.driver.stream(Self.one))
        #expect(stream.lastAcceptedTime == 10 * Self.msec)
        #expect(stream.deadline == 15 * Self.msec)
        #expect(stream.idleFlushes == 0)
        #expect(stream.resetFlushes == 0)
        #expect(fixture.timer.armedAt == 15 * Self.msec)
    }

    /// A callback queued while stream one still held a CC 6 runs after `remove`: it sends stream two's CC 6 and
    /// nothing for stream one.
    @Test func aCallbackQueuedBeforeRemoveSendsNothingForTheRemovedStream() async throws {
        let fixture = Fixture()
        try await Self.hold(fixture, Self.one, at: 0)
        try await Self.hold(fixture, Self.two, at: 30 * Self.msec, value: 20, channel: 1)
        let queued = try #require(fixture.timer.latest)
        await fixture.driver.remove(Self.one)
        #expect(fixture.sink.received == [try Self.batch(15)])
        fixture.clock.set(50 * Self.msec)
        await queued()
        #expect(fixture.sink.received == [try Self.batch(15), try Self.batch(20, channel: 1)])
        #expect(fixture.sink.streams == [Self.one, Self.two])
    }

    @Test func removeOfAnUnknownStreamOrAfterStopSendsNothingAndLeavesTheTimerAlone() async throws {
        let fixture = Fixture()
        try await Self.hold(fixture, Self.one, at: 0)
        await fixture.driver.remove(Self.two)
        #expect(fixture.sink.received.isEmpty)
        #expect(fixture.timer.armedAt == 5 * Self.msec)
        #expect(fixture.timer.armCount == 1)
        #expect(fixture.timer.cancelCount == 0)
        await fixture.driver.stop()
        #expect(fixture.sink.received == [try Self.batch(15)])
        await fixture.driver.remove(Self.one)
        #expect(fixture.sink.received.count == 1)
        #expect(fixture.timer.armCount == 1)
        #expect(fixture.timer.cancelCount == 1)
    }
}
