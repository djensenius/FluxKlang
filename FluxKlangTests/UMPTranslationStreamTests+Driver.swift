import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

// MARK: - The deadline-driven driver (#83)

private final class FakeClock: UMPTranslationStreamClock, @unchecked Sendable {
    private let lock = NSLock()
    private var now: UInt64 = 0

    func nowNanoseconds() -> UInt64 { lock.withLock { now } }
    func set(_ value: UInt64) { lock.withLock { now = value } }
}

/// Records the armed deadline and the arm and cancel counts. The test calls `driver.fire()` itself, after
/// `consume()`, which makes the timer idle again as a real one-shot timer is when it fires.
private final class FakeTimer: UMPTranslationStreamTimer, @unchecked Sendable {
    private let lock = NSLock()
    private var armed: UInt64?
    private var arms = 0
    private var cancels = 0

    var armedAt: UInt64? { lock.withLock { armed } }
    var armCount: Int { lock.withLock { arms } }
    var cancelCount: Int { lock.withLock { cancels } }

    func arm(atNanoseconds: UInt64, fire: @escaping @Sendable () -> Void) {
        lock.withLock {
            armed = atNanoseconds
            arms += 1
        }
    }

    func cancel() {
        lock.withLock {
            armed = nil
            cancels += 1
        }
    }

    func consume() { lock.withLock { armed = nil } }
}

private final class FakeSink: @unchecked Sendable {
    private let lock = NSLock()
    private var batches: [(stream: UMPTranslationStreamID, messages: [UMPMIDI2ChannelVoice])] = []

    /// The messages of each flush, in the order sent.
    var received: [[UMPMIDI2ChannelVoice]] { lock.withLock { batches.map(\.messages) } }
    /// The stream ID of each flush, in the order sent.
    var streams: [UMPTranslationStreamID] { lock.withLock { batches.map(\.stream) } }
    func append(_ stream: UMPTranslationStreamID, _ batch: [UMPMIDI2ChannelVoice]) {
        lock.withLock { batches.append((stream, batch)) }
    }
}

private struct Fixture {
    let driver: UMPTranslationStreamDriver
    let clock = FakeClock()
    let timer = FakeTimer()
    let sink = FakeSink()

    init() {
        let sink = self.sink
        driver = UMPTranslationStreamDriver(clock: clock, timer: timer) { sink.append($0, $1) }
    }

    /// The test's timer firing: the clock moves to `time`, the timer goes idle, the driver's `fire()` runs.
    func fire(at time: UInt64) async {
        clock.set(time)
        timer.consume()
        await driver.fire()
    }
}

extension UMPTranslationStreamTests {
    private static let one = UMPTranslationStreamID(1)
    private static let two = UMPTranslationStreamID(2)

    private static func control(_ channel: UInt8, _ controller: UInt8, _ value: UInt8) -> MIDI1Event {
        .channel(status: 0xB0 | channel, data1: controller, data2: value)
    }

    /// Selects RPN 0/6 and receives CC 6 value `value` at `time`: the CC 6 is held until `time` + 5 ms.
    private static func hold(_ fixture: Fixture, _ id: UMPTranslationStreamID, at time: UInt64, value: UInt8 = 15,
                             channel: UInt8 = 0) async throws {
        let group = try UMPGroup(0)
        for (controller, data) in [(UInt8(101), UInt8(0)), (100, 6), (6, value)] {
            let items = try await fixture.driver.receive(control(channel, controller, data), group: group,
                                                         stream: id, atNanoseconds: time)
            #expect(items.isEmpty)
        }
    }

    @Test func aLoneDataEntryFollowedByIdleIsSentThroughTheSinkAfterTheTimeout() async throws {
        let fixture = Fixture()
        try await Self.hold(fixture, Self.one, at: 10 * Self.msec)
        #expect(fixture.timer.armedAt == 15 * Self.msec)
        await fixture.fire(at: 14 * Self.msec)
        #expect(fixture.sink.received.isEmpty)
        await fixture.fire(at: 15 * Self.msec)
        #expect(fixture.sink.received == [[try Self.mpe(15)]])
        #expect(fixture.sink.streams == [Self.one])
        #expect(await fixture.driver.stream(Self.one)?.idleFlushes == 1)
        await fixture.fire(at: 40 * Self.msec)
        #expect(fixture.sink.received.count == 1)
    }

    @Test func endOfStreamReturnsAHeldDataEntryAndCancelsTheTimer() async throws {
        let fixture = Fixture()
        try await Self.hold(fixture, Self.one, at: 0)
        #expect(await fixture.driver.endOfStream(Self.one) == [try Self.mpe(15)])
        #expect(fixture.timer.armedAt == nil)
        #expect(fixture.timer.cancelCount == 1)
        #expect(await fixture.driver.stream(Self.one)?.endOfStreamFlushes == 1)
        await fixture.fire(at: 50 * Self.msec)
        #expect(fixture.sink.received.isEmpty)
    }

    @Test func aFireOneNanosecondBeforeTheDeadlineSendsNothingAndKeepsTheTimerArmed() async throws {
        let fixture = Fixture()
        try await Self.hold(fixture, Self.one, at: 0)
        let deadline = 5 * Self.msec
        await fixture.fire(at: deadline - 1)
        #expect(fixture.sink.received.isEmpty)
        #expect(fixture.timer.armedAt == deadline)
        #expect(fixture.timer.armCount == 2)
        await fixture.fire(at: deadline)
        #expect(fixture.sink.received == [[try Self.mpe(15)]])
        #expect(fixture.timer.armedAt == nil)
    }

    @Test func aFireAfterTheDeadlineSendsToo() async throws {
        let fixture = Fixture()
        try await Self.hold(fixture, Self.one, at: 0)
        await fixture.fire(at: 9 * Self.msec)
        #expect(fixture.sink.received == [[try Self.mpe(15)]])
    }

    @Test func theTimerFollowsTheStreamsDeadlineAndIsCancelledWhenNothingIsHeld() async throws {
        let fixture = Fixture()
        try await Self.hold(fixture, Self.one, at: 10 * Self.msec)
        #expect(fixture.timer.armedAt == (await fixture.driver.stream(Self.one))?.deadline)
        #expect(fixture.timer.armCount == 1)
        // A second CC 6 sends the first and holds itself: the deadline moves.
        let moved = try await fixture.driver.receive(Self.control(0, 6, 20), group: UMPGroup(0), stream: Self.one,
                                                     atNanoseconds: 12 * Self.msec)
        #expect(moved == [.voice(try Self.mpe(15))])
        #expect(fixture.timer.armedAt == 17 * Self.msec)
        #expect(fixture.timer.armedAt == (await fixture.driver.stream(Self.one))?.deadline)
        #expect(fixture.timer.armCount == 2)
        // A CC 38 completes the pair: nothing is held any more.
        let completed = try await fixture.driver.receive(Self.control(0, 38, 3), group: UMPGroup(0),
                                                         stream: Self.one, atNanoseconds: 13 * Self.msec)
        #expect(completed == [.voice(try Self.mpe(20, lsb: 3))])
        #expect(fixture.timer.armedAt == nil)
        #expect(fixture.timer.cancelCount == 1)
        #expect(fixture.timer.armCount == 2)
    }

    @Test func resetReturnsAHeldDataEntryAndALaterFireSendsNothing() async throws {
        let fixture = Fixture()
        try await Self.hold(fixture, Self.one, at: 0)
        #expect(await fixture.driver.reset(Self.one) == [try Self.mpe(15)])
        #expect(fixture.timer.armedAt == nil)
        #expect(await fixture.driver.stream(Self.one)?.resetFlushes == 1)
        await fixture.fire(at: 50 * Self.msec)
        #expect(fixture.sink.received.isEmpty)
    }

    @Test func twoStreamsShareOneTimerAtTheEarlierDeadline() async throws {
        let fixture = Fixture()
        try await Self.hold(fixture, Self.two, at: 12 * Self.msec, value: 20, channel: 1)
        #expect(fixture.timer.armedAt == 17 * Self.msec)
        try await Self.hold(fixture, Self.one, at: 10 * Self.msec)
        #expect(fixture.timer.armedAt == 15 * Self.msec)
        await fixture.fire(at: 15 * Self.msec)
        #expect(fixture.sink.received == [[try Self.mpe(15)]])
        #expect(fixture.timer.armedAt == 17 * Self.msec)
        #expect(await fixture.driver.stream(Self.two)?.translator.heldDataEntry != nil)
        await fixture.fire(at: 17 * Self.msec)
        #expect(fixture.sink.received == [[try Self.mpe(15)], [try Self.mpe(20, channel: 1)]])
        #expect(fixture.sink.streams == [Self.one, Self.two])
        #expect(fixture.timer.armedAt == nil)
    }

    @Test func stopCancelsTheTimerReturnsTheHeldMessagesAndLaterFiresSendNothing() async throws {
        let fixture = Fixture()
        try await Self.hold(fixture, Self.one, at: 0)
        let stopped = await fixture.driver.stop()
        #expect(stopped.map(\.stream) == [Self.one])
        #expect(stopped.map(\.messages) == [[try Self.mpe(15)]])
        #expect(fixture.timer.armedAt == nil)
        #expect(fixture.timer.cancelCount == 1)
        await fixture.fire(at: 50 * Self.msec)
        #expect(fixture.sink.received.isEmpty)
        try await Self.hold(fixture, Self.one, at: 60 * Self.msec)
        #expect(fixture.timer.armedAt == nil)
        #expect(fixture.timer.armCount == 1)
        await fixture.fire(at: 70 * Self.msec)
        #expect(fixture.sink.received.isEmpty)
    }

    @Test func aBackwardJitteringClockNeitherRefusesNorLosesTheHeldDataEntry() async throws {
        let fixture = Fixture()
        try await Self.hold(fixture, Self.one, at: 10 * Self.msec)
        await fixture.fire(at: 12 * Self.msec)
        await fixture.fire(at: 11 * Self.msec)
        #expect(await fixture.driver.pollRefusals == 0)
        #expect(fixture.sink.received.isEmpty)
        #expect(await fixture.driver.stream(Self.one)?.deadline == 15 * Self.msec)
        #expect(fixture.timer.armedAt == 15 * Self.msec)
        await fixture.fire(at: 15 * Self.msec)
        #expect(fixture.sink.received == [[try Self.mpe(15)]])
    }

    @Test func aSystemRealTimeEventPassesThroughAndSysExHasNoStreamPath() async throws {
        let fixture = Fixture()
        let group = try UMPGroup(0)
        let clock = try await fixture.driver.receive(.realTime(status: 0xF8), group: group, stream: Self.one,
                                                     atNanoseconds: 0)
        let items = try #require(clock.first)
        #expect(clock.count == 1)
        guard case .system = items else {
            Issue.record("expected a system item")
            return
        }
        await #expect(throws: UMPTranslationStreamRefusal.translation(.notChannelVoice)) {
            try await fixture.driver.receive(.sysEx(payload: [0x7E]), group: group, stream: Self.one,
                                             atNanoseconds: 1)
        }
        #expect(fixture.timer.armCount == 0)
    }

    @Test func anEventStampedBeforeALateFiresTimeIsClampedNotDropped() async throws {
        let fixture = Fixture()
        try await Self.hold(fixture, Self.one, at: 18 * Self.msec)
        await fixture.fire(at: 20 * Self.msec)
        #expect(fixture.sink.received.isEmpty)
        let completed = try await fixture.driver.receive(Self.control(0, 38, 3), group: UMPGroup(0),
                                                         stream: Self.one, atNanoseconds: 19 * Self.msec)
        #expect(completed == [.voice(try Self.mpe(15, lsb: 3))])
        #expect(fixture.timer.armedAt == nil)
    }

    @Test func anEventEarlierThanAnAcceptedOneIsStillRefusedAfterALaterFire() async throws {
        let fixture = Fixture()
        try await Self.hold(fixture, Self.one, at: 15 * Self.msec)
        await fixture.fire(at: 20 * Self.msec)
        await #expect(throws: UMPTranslationStreamRefusal.timeWentBackward(previous: 20 * Self.msec,
                                                                           got: 14 * Self.msec)) {
            try await fixture.driver.receive(Self.control(0, 38, 3), group: UMPGroup(0), stream: Self.one,
                                             atNanoseconds: 14 * Self.msec)
        }
        #expect(fixture.sink.received == [[try Self.mpe(15)]])
        #expect(fixture.timer.armedAt == nil)
        #expect(fixture.timer.armCount == 1)
    }

    /// After `reset` or `endOfStream`, a fire for another stream neither polls this one nor gives it a baseline again,
    /// so its next event is admitted at its own stamp.
    @Test(arguments: [true, false])
    func resetAndEndOfStreamForgetTheLateFiresBaseline(isReset: Bool) async throws {
        let fixture = Fixture()
        try await Self.hold(fixture, Self.one, at: Self.msec)
        await fixture.fire(at: 20 * Self.msec)
        #expect(fixture.sink.received == [[try Self.mpe(15)]])
        let flushed = isReset ? await fixture.driver.reset(Self.one) : await fixture.driver.endOfStream(Self.one)
        #expect(flushed.isEmpty)
        try await Self.hold(fixture, Self.two, at: 25 * Self.msec, value: 20, channel: 1)
        await fixture.fire(at: 30 * Self.msec)
        #expect(fixture.sink.streams == [Self.one, Self.two])
        #expect(await fixture.driver.stream(Self.one)?.lastAcceptedTime == nil)
        try await Self.hold(fixture, Self.one, at: 10 * Self.msec)
        #expect(await fixture.driver.stream(Self.one)?.lastAcceptedTime == 10 * Self.msec)
        #expect(await fixture.driver.stream(Self.one)?.deadline == 15 * Self.msec)
        #expect(fixture.timer.armedAt == 15 * Self.msec)
    }

    @Test func aGenuinelyBackwardEventIsStillRefusedAndTheTimerKeepsItsArming() async throws {
        let fixture = Fixture()
        try await Self.hold(fixture, Self.one, at: 10 * Self.msec)
        await #expect(throws: UMPTranslationStreamRefusal.timeWentBackward(previous: 10 * Self.msec,
                                                                           got: 9 * Self.msec)) {
            try await fixture.driver.receive(Self.control(0, 38, 3), group: UMPGroup(0), stream: Self.one,
                                             atNanoseconds: 9 * Self.msec)
        }
        #expect(fixture.timer.armedAt == 15 * Self.msec)
        #expect(fixture.timer.armCount == 1)
        #expect(await fixture.driver.stream(Self.one)?.deadline == 15 * Self.msec)
    }

    @Test func aSystemCommonEventSendsTheHeldDataEntryFirstAndCancelsTheTimer() async throws {
        let fixture = Fixture()
        try await Self.hold(fixture, Self.one, at: 0)
        let items = try await fixture.driver.receive(.systemCommon(status: 0xF6, data1: nil, data2: nil),
                                                     group: UMPGroup(0), stream: Self.one,
                                                     atNanoseconds: Self.msec)
        #expect(items == [.voice(try Self.mpe(15)), .system(try Self.system(0x10F6_0000))])
        #expect(fixture.timer.armedAt == nil)
        #expect(fixture.timer.cancelCount == 1)
    }

    @Test func stopReturnsTheHeldMessagesInStreamIDOrder() async throws {
        let fixture = Fixture()
        try await Self.hold(fixture, Self.two, at: 0, value: 20, channel: 1)
        try await Self.hold(fixture, Self.one, at: 0)
        let stopped = await fixture.driver.stop()
        #expect(stopped.map(\.stream) == [Self.one, Self.two])
        #expect(stopped.map(\.messages) == [[try Self.mpe(15)], [try Self.mpe(20, channel: 1)]])
    }

    /// Two inputs on the same group and channel: the sink and `stop()` keep their flushes apart by stream ID, and
    /// `stop()` leaves out a stream that held nothing.
    @Test func flushesOfTwoStreamsOnOneGroupAndChannelCarryTheirStreamIDs() async throws {
        let fixture = Fixture()
        let three = UMPTranslationStreamID(3)
        try await Self.hold(fixture, Self.two, at: 10 * Self.msec, value: 20)
        try await Self.hold(fixture, Self.one, at: 12 * Self.msec)
        await fixture.fire(at: 15 * Self.msec)
        await fixture.fire(at: 17 * Self.msec)
        #expect(fixture.sink.streams == [Self.two, Self.one])
        #expect(fixture.sink.received == [[try Self.mpe(20)], [try Self.mpe(15)]])
        try await Self.hold(fixture, Self.two, at: 20 * Self.msec, value: 21)
        try await Self.hold(fixture, Self.one, at: 20 * Self.msec, value: 22)
        _ = try await fixture.driver.receive(.realTime(status: 0xF8), group: UMPGroup(0), stream: three,
                                             atNanoseconds: 20 * Self.msec)
        let stopped = await fixture.driver.stop()
        #expect(stopped.map(\.stream) == [Self.one, Self.two])
        #expect(stopped.map(\.messages) == [[try Self.mpe(22)], [try Self.mpe(21)]])
    }

    /// The poll baseline only admits a late event; its stamp still sets the deadline. A CC 6 stamped 18 ms and
    /// delivered after a poll at 20 ms is held until 23 ms, so a CC 38 stamped 24 ms finds it expired and is late.
    @Test func aDataEntryStampedBeforeALateFireTimesOutFromItsStamp() async throws {
        let fixture = Fixture()
        try await Self.hold(fixture, Self.one, at: 14 * Self.msec)
        await fixture.fire(at: 20 * Self.msec)
        #expect(fixture.sink.received == [[try Self.mpe(15)]])
        try await Self.hold(fixture, Self.one, at: 18 * Self.msec, value: 16)
        #expect(await fixture.driver.stream(Self.one)?.lastAcceptedTime == 20 * Self.msec)
        #expect(await fixture.driver.stream(Self.one)?.deadline == 23 * Self.msec)
        #expect(fixture.timer.armedAt == 23 * Self.msec)
        let late = try await fixture.driver.receive(Self.control(0, 38, 3), group: UMPGroup(0), stream: Self.one,
                                                    atNanoseconds: 24 * Self.msec)
        #expect(late == [.voice(try Self.mpe(16)), .voice(try Self.mpe(16, lsb: 3))])
        #expect(await fixture.driver.stream(Self.one)?.idleFlushes == 2)
        #expect(fixture.timer.armedAt == nil)
    }

    /// A CC 6 and its CC 38 stamped 10 ms and 12 ms still pair when both arrive after a poll at 20 ms. A CC 6 whose
    /// deadline is already past when it is admitted is armed for at once and sent by the next fire.
    @Test func aPairStampedBeforeALateFireStillPairsAndAPassedDeadlineIsSentByTheNextFire() async throws {
        let fixture = Fixture()
        try await Self.hold(fixture, Self.one, at: 4 * Self.msec)
        await fixture.fire(at: 20 * Self.msec)
        #expect(fixture.sink.received == [[try Self.mpe(15)]])
        try await Self.hold(fixture, Self.one, at: 10 * Self.msec, value: 16)
        #expect(await fixture.driver.stream(Self.one)?.deadline == 15 * Self.msec)
        #expect(fixture.timer.armedAt == 15 * Self.msec)
        let paired = try await fixture.driver.receive(Self.control(0, 38, 3), group: UMPGroup(0), stream: Self.one,
                                                      atNanoseconds: 12 * Self.msec)
        #expect(paired == [.voice(try Self.mpe(16, lsb: 3))])
        #expect(fixture.timer.armedAt == nil)
        let held = try await fixture.driver.receive(Self.control(0, 6, 17), group: UMPGroup(0), stream: Self.one,
                                                    atNanoseconds: 13 * Self.msec)
        #expect(held.isEmpty)
        #expect(fixture.timer.armedAt == 18 * Self.msec)
        await fixture.fire(at: 20 * Self.msec)
        #expect(fixture.sink.received == [[try Self.mpe(15)], [try Self.mpe(17)]])
        #expect(fixture.sink.streams == [Self.one, Self.one])
        #expect(await fixture.driver.stream(Self.one)?.idleFlushes == 2)
    }
}
