import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

// MARK: - The deadline-driven driver (#83)

final class FakeClock: UMPTranslationStreamClock, @unchecked Sendable {
    private let lock = NSLock()
    private var now: UInt64 = 0

    func nowNanoseconds() -> UInt64 { lock.withLock { now } }
    func set(_ value: UInt64) { lock.withLock { now = value } }
}

/// Records the armed deadline and the arm and cancel counts, and retains the most recent callback. The test runs the
/// callback itself, after `consume()`, which makes the timer idle again as a real one-shot timer is when it fires.
/// `latest` survives `cancel()` and `consume()`, to model a callback already queued when the timer was cancelled.
/// Given a clock, an arming for a deadline the clock has reached also starts the callback at once in a `Task`, as a
/// real timer would; `started` is that task.
final class FakeTimer: UMPTranslationStreamTimer, @unchecked Sendable {
    private let lock = NSLock()
    private let clock: FakeClock?
    private var armed: UInt64?
    private var callback: (@Sendable () async -> Void)?
    private var task: Task<Void, Never>?
    private var arms = 0
    private var cancels = 0

    init(clock: FakeClock? = nil) {
        self.clock = clock
    }

    var armedAt: UInt64? { lock.withLock { armed } }
    var latest: (@Sendable () async -> Void)? { lock.withLock { callback } }
    var started: Task<Void, Never>? { lock.withLock { task } }
    var armCount: Int { lock.withLock { arms } }
    var cancelCount: Int { lock.withLock { cancels } }

    func arm(atNanoseconds: UInt64, fire: @escaping @Sendable () async -> Void) {
        let due = clock.map { atNanoseconds <= $0.nowNanoseconds() } ?? false
        lock.withLock {
            armed = atNanoseconds
            callback = fire
            arms += 1
            if due { task = Task { await fire() } }
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

final class FakeSink: @unchecked Sendable {
    private let lock = NSLock()
    private var batches: [(stream: UMPTranslationStreamID, items: [UMPTranslationStreamItem])] = []

    /// The items of each batch, in the order sent.
    var received: [[UMPTranslationStreamItem]] { lock.withLock { batches.map(\.items) } }
    /// The stream ID of each batch, in the order sent.
    var streams: [UMPTranslationStreamID] { lock.withLock { batches.map(\.stream) } }
    func append(_ stream: UMPTranslationStreamID, _ batch: [UMPTranslationStreamItem]) {
        lock.withLock { batches.append((stream, batch)) }
    }
}

/// Nested in the suite, not top level: several other test files declare a file-private top-level `Fixture`.
extension UMPTranslationStreamTests {
    struct Fixture {
        let driver: UMPTranslationStreamDriver
        let clock = FakeClock()
        let timer: FakeTimer
        let sink = FakeSink()

        /// `startsPassedDeadlines`: the timer starts the callback at once for a deadline the clock has reached.
        init(startsPassedDeadlines: Bool = false) {
            let sink = self.sink
            timer = FakeTimer(clock: startsPassedDeadlines ? clock : nil)
            driver = UMPTranslationStreamDriver(clock: clock, timer: timer) { sink.append($0, $1) }
        }

        /// The test's timer firing: the clock moves to `time`, the timer goes idle, and the most recently armed
        /// callback runs to completion, so its output is in the sink when this returns. Fails the test if nothing was
        /// ever armed.
        func fire(at time: UInt64) async {
            guard let callback = timer.latest else {
                Issue.record("the driver never armed the timer")
                return
            }
            clock.set(time)
            timer.consume()
            await callback()
        }
    }
}

extension UMPTranslationStreamTests {
    static let one = UMPTranslationStreamID(1)
    static let two = UMPTranslationStreamID(2)

    /// One sink batch holding the CC 6 `msb` (with `lsb`) as a MIDI 2.0 RPN 0/6 message.
    static func batch(_ msb: UInt8, lsb: UInt8 = 0, channel: UInt8 = 0) throws -> [UMPTranslationStreamItem] {
        [.voice(try mpe(msb, lsb: lsb, channel: channel))]
    }

    static func control(_ channel: UInt8, _ controller: UInt8, _ value: UInt8) -> MIDI1Event {
        .channel(status: 0xB0 | channel, data1: controller, data2: value)
    }

    /// Selects RPN 0/6 and receives CC 6 value `value` at `time`: the CC 6 is held until `time` + 5 ms. Nothing reaches
    /// the sink.
    static func hold(_ fixture: Fixture, _ id: UMPTranslationStreamID, at time: UInt64, value: UInt8 = 15,
                     channel: UInt8 = 0) async throws {
        let group = try UMPGroup(0)
        let sent = fixture.sink.received.count
        for (controller, data) in [(UInt8(101), UInt8(0)), (100, 6), (6, value)] {
            try await fixture.driver.receive(control(channel, controller, data), group: group, stream: id,
                                             atNanoseconds: time)
        }
        #expect(fixture.sink.received.count == sent)
    }

    @Test func aLoneDataEntryFollowedByIdleIsSentThroughTheSinkAfterTheTimeout() async throws {
        let fixture = Fixture()
        try await Self.hold(fixture, Self.one, at: 10 * Self.msec)
        #expect(fixture.timer.armedAt == 15 * Self.msec)
        await fixture.fire(at: 14 * Self.msec)
        #expect(fixture.sink.received.isEmpty)
        await fixture.fire(at: 15 * Self.msec)
        #expect(fixture.sink.received == [try Self.batch(15)])
        #expect(fixture.sink.streams == [Self.one])
        #expect(await fixture.driver.stream(Self.one)?.idleFlushes == 1)
        await fixture.fire(at: 40 * Self.msec)
        #expect(fixture.sink.received.count == 1)
    }

    @Test func endOfStreamSendsAHeldDataEntryAndCancelsTheTimer() async throws {
        let fixture = Fixture()
        try await Self.hold(fixture, Self.one, at: 0)
        await fixture.driver.endOfStream(Self.one)
        #expect(fixture.sink.received == [try Self.batch(15)])
        #expect(fixture.sink.streams == [Self.one])
        #expect(fixture.timer.armedAt == nil)
        #expect(fixture.timer.cancelCount == 1)
        #expect(await fixture.driver.stream(Self.one)?.endOfStreamFlushes == 1)
        await fixture.fire(at: 50 * Self.msec)
        #expect(fixture.sink.received.count == 1)
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
        #expect(fixture.sink.received == [try Self.batch(15)])
        #expect(fixture.timer.armedAt == nil)
    }

    @Test func aFireAfterTheDeadlineSendsToo() async throws {
        let fixture = Fixture()
        try await Self.hold(fixture, Self.one, at: 0)
        await fixture.fire(at: 9 * Self.msec)
        #expect(fixture.sink.received == [try Self.batch(15)])
    }

    @Test func theTimerFollowsTheStreamsDeadlineAndIsCancelledWhenNothingIsHeld() async throws {
        let fixture = Fixture()
        try await Self.hold(fixture, Self.one, at: 10 * Self.msec)
        #expect(fixture.timer.armedAt == (await fixture.driver.stream(Self.one))?.deadline)
        #expect(fixture.timer.armCount == 1)
        // A second CC 6 sends the first and holds itself: the deadline moves.
        try await fixture.driver.receive(Self.control(0, 6, 20), group: UMPGroup(0), stream: Self.one,
                                         atNanoseconds: 12 * Self.msec)
        #expect(fixture.sink.received == [try Self.batch(15)])
        #expect(fixture.timer.armedAt == 17 * Self.msec)
        #expect(fixture.timer.armedAt == (await fixture.driver.stream(Self.one))?.deadline)
        #expect(fixture.timer.armCount == 2)
        // A CC 38 completes the pair: nothing is held any more.
        try await fixture.driver.receive(Self.control(0, 38, 3), group: UMPGroup(0), stream: Self.one,
                                         atNanoseconds: 13 * Self.msec)
        #expect(fixture.sink.received == [try Self.batch(15), try Self.batch(20, lsb: 3)])
        #expect(fixture.sink.streams == [Self.one, Self.one])
        #expect(fixture.timer.armedAt == nil)
        #expect(fixture.timer.cancelCount == 1)
        #expect(fixture.timer.armCount == 2)
    }

    /// A replacement CC 6 whose deadline is already past when it is admitted: the receive sends the older CC 6, and
    /// the timer callback, armed at once, sends the newer one after it, through the same sink.
    @Test func aReplacementDataEntryWithAPassedDeadlineReachesTheSinkAfterTheOneItReplaces() async throws {
        let fixture = Fixture()
        fixture.clock.set(100 * Self.msec)
        try await Self.hold(fixture, Self.one, at: 10 * Self.msec)
        #expect(fixture.timer.armedAt == 15 * Self.msec)
        try await fixture.driver.receive(Self.control(0, 6, 20), group: UMPGroup(0), stream: Self.one,
                                         atNanoseconds: 11 * Self.msec)
        #expect(fixture.sink.received == [try Self.batch(15)])
        #expect(fixture.timer.armedAt == 16 * Self.msec)
        await fixture.fire(at: 100 * Self.msec)
        #expect(fixture.sink.received == [try Self.batch(15), try Self.batch(20)])
        #expect(fixture.sink.streams == [Self.one, Self.one])
    }

    /// As above, with a timer that starts the callback in a `Task` the moment it is armed for a passed deadline: the
    /// callback waits for the actor, so the older CC 6 still reaches the sink first.
    @Test func aReplacementDataEntryArmedForAnImmediateFireStillReachesTheSinkSecond() async throws {
        let fixture = Fixture(startsPassedDeadlines: true)
        fixture.clock.set(10 * Self.msec)
        try await Self.hold(fixture, Self.one, at: 10 * Self.msec)
        #expect(fixture.timer.started == nil)
        fixture.clock.set(100 * Self.msec)
        try await fixture.driver.receive(Self.control(0, 6, 20), group: UMPGroup(0), stream: Self.one,
                                         atNanoseconds: 11 * Self.msec)
        let started = try #require(fixture.timer.started)
        await started.value
        #expect(fixture.sink.received == [try Self.batch(15), try Self.batch(20)])
        #expect(fixture.sink.streams == [Self.one, Self.one])
    }

    /// One poll that flushes two streams sends them in `UMPTranslationStreamID` order, whatever order they were held.
    @Test func onePollFlushingTwoStreamsSendsThemInStreamIDOrder() async throws {
        let fixture = Fixture()
        try await Self.hold(fixture, Self.two, at: 10 * Self.msec, value: 20, channel: 1)
        try await Self.hold(fixture, Self.one, at: 10 * Self.msec)
        #expect(fixture.timer.armedAt == 15 * Self.msec)
        await fixture.fire(at: 15 * Self.msec)
        #expect(fixture.sink.streams == [Self.one, Self.two])
        #expect(fixture.sink.received == [try Self.batch(15), try Self.batch(20, channel: 1)])
        #expect(fixture.timer.armedAt == nil)
    }

    @Test func resetSendsAHeldDataEntryAndALaterFireSendsNothing() async throws {
        let fixture = Fixture()
        try await Self.hold(fixture, Self.one, at: 0)
        await fixture.driver.reset(Self.one)
        #expect(fixture.sink.received == [try Self.batch(15)])
        #expect(fixture.sink.streams == [Self.one])
        #expect(fixture.timer.armedAt == nil)
        #expect(await fixture.driver.stream(Self.one)?.resetFlushes == 1)
        await fixture.fire(at: 50 * Self.msec)
        #expect(fixture.sink.received.count == 1)
    }

    @Test func twoStreamsShareOneTimerAtTheEarlierDeadline() async throws {
        let fixture = Fixture()
        try await Self.hold(fixture, Self.two, at: 12 * Self.msec, value: 20, channel: 1)
        #expect(fixture.timer.armedAt == 17 * Self.msec)
        try await Self.hold(fixture, Self.one, at: 10 * Self.msec)
        #expect(fixture.timer.armedAt == 15 * Self.msec)
        await fixture.fire(at: 15 * Self.msec)
        #expect(fixture.sink.received == [try Self.batch(15)])
        #expect(fixture.timer.armedAt == 17 * Self.msec)
        #expect(await fixture.driver.stream(Self.two)?.translator.heldDataEntry != nil)
        await fixture.fire(at: 17 * Self.msec)
        #expect(fixture.sink.received == [try Self.batch(15), try Self.batch(20, channel: 1)])
        #expect(fixture.sink.streams == [Self.one, Self.two])
        #expect(fixture.timer.armedAt == nil)
    }

    @Test func stopCancelsTheTimerSendsTheHeldMessagesAndLaterFiresSendNothing() async throws {
        let fixture = Fixture()
        try await Self.hold(fixture, Self.one, at: 0)
        await fixture.driver.stop()
        #expect(fixture.sink.streams == [Self.one])
        #expect(fixture.sink.received == [try Self.batch(15)])
        #expect(fixture.timer.armedAt == nil)
        #expect(fixture.timer.cancelCount == 1)
        await fixture.fire(at: 50 * Self.msec)
        #expect(fixture.sink.received.count == 1)
        try await Self.hold(fixture, Self.one, at: 60 * Self.msec)
        #expect(fixture.timer.armedAt == nil)
        #expect(fixture.timer.armCount == 1)
        await fixture.fire(at: 70 * Self.msec)
        #expect(fixture.sink.received.count == 1)
    }

    /// A callback the timer had already queued when `stop()` ran sends nothing, even with a CC 6 offered after stop.
    @Test func aCallbackQueuedBeforeStopSendsNothingAfterIt() async throws {
        let fixture = Fixture()
        try await Self.hold(fixture, Self.one, at: 0)
        let queued = try #require(fixture.timer.latest)
        await fixture.driver.stop()
        #expect(fixture.sink.received == [try Self.batch(15)])
        try await Self.hold(fixture, Self.one, at: Self.msec, value: 16)
        fixture.clock.set(50 * Self.msec)
        await queued()
        #expect(fixture.sink.received == [try Self.batch(15)])
        #expect(fixture.sink.streams == [Self.one])
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
        #expect(fixture.sink.received == [try Self.batch(15)])
    }

    @Test func aSystemRealTimeEventAndCompleteSysExPassThroughInOrder() async throws {
        let fixture = Fixture()
        let group = try UMPGroup(0)
        try await fixture.driver.receive(.realTime(status: 0xF8), group: group, stream: Self.one, atNanoseconds: 0)
        #expect(fixture.sink.streams == [Self.one])
        let batch = try #require(fixture.sink.received.first)
        let item = try #require(batch.first)
        #expect(batch.count == 1)
        guard case .system = item else {
            Issue.record("expected a system item")
            return
        }
        try await fixture.driver.receive(.sysEx(payload: [0x7E]), group: group, stream: Self.one,
                                         atNanoseconds: 1)
        let packet = try UMPSysEx7Packet(group: group, status: .complete, bytes: [0x7E])
        #expect(fixture.sink.received == [batch, [.sysEx7(packet)]])
        #expect(fixture.sink.streams == [Self.one, Self.one])
        #expect(fixture.timer.armCount == 0)
    }

    @Test func anEventStampedBeforeALateFiresTimeIsClampedNotDropped() async throws {
        let fixture = Fixture()
        try await Self.hold(fixture, Self.one, at: 18 * Self.msec)
        await fixture.fire(at: 20 * Self.msec)
        #expect(fixture.sink.received.isEmpty)
        try await fixture.driver.receive(Self.control(0, 38, 3), group: UMPGroup(0), stream: Self.one,
                                         atNanoseconds: 19 * Self.msec)
        #expect(fixture.sink.received == [try Self.batch(15, lsb: 3)])
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
        #expect(fixture.sink.received == [try Self.batch(15)])
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
        #expect(fixture.sink.received == [try Self.batch(15)])
        if isReset { await fixture.driver.reset(Self.one) } else { await fixture.driver.endOfStream(Self.one) }
        #expect(fixture.sink.received.count == 1)
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
        try await fixture.driver.receive(.systemCommon(status: 0xF6, data1: nil, data2: nil), group: UMPGroup(0),
                                         stream: Self.one, atNanoseconds: Self.msec)
        #expect(fixture.sink.received == [[.voice(try Self.mpe(15)), .system(try Self.system(0x10F6_0000))]])
        #expect(fixture.sink.streams == [Self.one])
        #expect(fixture.timer.armedAt == nil)
        #expect(fixture.timer.cancelCount == 1)
    }

    @Test func stopSendsTheHeldMessagesInStreamIDOrder() async throws {
        let fixture = Fixture()
        try await Self.hold(fixture, Self.two, at: 0, value: 20, channel: 1)
        try await Self.hold(fixture, Self.one, at: 0)
        await fixture.driver.stop()
        #expect(fixture.sink.streams == [Self.one, Self.two])
        #expect(fixture.sink.received == [try Self.batch(15), try Self.batch(20, channel: 1)])
    }

    /// Two inputs on the same group and channel: the sink keeps their flushes apart by stream ID, and `stop()` leaves
    /// out a stream that held nothing.
    @Test func flushesOfTwoStreamsOnOneGroupAndChannelCarryTheirStreamIDs() async throws {
        let fixture = Fixture()
        let three = UMPTranslationStreamID(3)
        try await Self.hold(fixture, Self.two, at: 10 * Self.msec, value: 20)
        try await Self.hold(fixture, Self.one, at: 12 * Self.msec)
        await fixture.fire(at: 15 * Self.msec)
        await fixture.fire(at: 17 * Self.msec)
        #expect(fixture.sink.streams == [Self.two, Self.one])
        #expect(fixture.sink.received == [try Self.batch(20), try Self.batch(15)])
        try await Self.hold(fixture, Self.two, at: 20 * Self.msec, value: 21)
        try await Self.hold(fixture, Self.one, at: 20 * Self.msec, value: 22)
        try await fixture.driver.receive(.realTime(status: 0xF8), group: UMPGroup(0), stream: three,
                                         atNanoseconds: 20 * Self.msec)
        #expect(fixture.sink.streams == [Self.two, Self.one, three])
        await fixture.driver.stop()
        #expect(fixture.sink.streams == [Self.two, Self.one, three, Self.one, Self.two])
        #expect(Array(fixture.sink.received.suffix(2)) == [try Self.batch(22), try Self.batch(21)])
    }

    /// The poll baseline only admits a late event; its stamp still sets the deadline. A CC 6 stamped 18 ms and
    /// delivered after a poll at 20 ms is held until 23 ms, so a CC 38 stamped 24 ms finds it expired and is late.
    @Test func aDataEntryStampedBeforeALateFireTimesOutFromItsStamp() async throws {
        let fixture = Fixture()
        try await Self.hold(fixture, Self.one, at: 14 * Self.msec)
        await fixture.fire(at: 20 * Self.msec)
        #expect(fixture.sink.received == [try Self.batch(15)])
        try await Self.hold(fixture, Self.one, at: 18 * Self.msec, value: 16)
        #expect(await fixture.driver.stream(Self.one)?.lastAcceptedTime == 20 * Self.msec)
        #expect(await fixture.driver.stream(Self.one)?.deadline == 23 * Self.msec)
        #expect(fixture.timer.armedAt == 23 * Self.msec)
        try await fixture.driver.receive(Self.control(0, 38, 3), group: UMPGroup(0), stream: Self.one,
                                         atNanoseconds: 24 * Self.msec)
        #expect(fixture.sink.received.last == [.voice(try Self.mpe(16)), .voice(try Self.mpe(16, lsb: 3))])
        #expect(fixture.sink.received.count == 2)
        #expect(await fixture.driver.stream(Self.one)?.idleFlushes == 2)
        #expect(fixture.timer.armedAt == nil)
    }

    /// A CC 6 and its CC 38 stamped 10 ms and 12 ms still pair when both arrive after a poll at 20 ms. A CC 6 whose
    /// deadline is already past when it is admitted is armed for at once and sent by the next fire.
    @Test func aPairStampedBeforeALateFireStillPairsAndAPassedDeadlineIsSentByTheNextFire() async throws {
        let fixture = Fixture()
        try await Self.hold(fixture, Self.one, at: 4 * Self.msec)
        await fixture.fire(at: 20 * Self.msec)
        #expect(fixture.sink.received == [try Self.batch(15)])
        try await Self.hold(fixture, Self.one, at: 10 * Self.msec, value: 16)
        #expect(await fixture.driver.stream(Self.one)?.deadline == 15 * Self.msec)
        #expect(fixture.timer.armedAt == 15 * Self.msec)
        try await fixture.driver.receive(Self.control(0, 38, 3), group: UMPGroup(0), stream: Self.one,
                                         atNanoseconds: 12 * Self.msec)
        #expect(fixture.sink.received == [try Self.batch(15), try Self.batch(16, lsb: 3)])
        #expect(fixture.timer.armedAt == nil)
        try await fixture.driver.receive(Self.control(0, 6, 17), group: UMPGroup(0), stream: Self.one,
                                         atNanoseconds: 13 * Self.msec)
        #expect(fixture.sink.received.count == 2)
        #expect(fixture.timer.armedAt == 18 * Self.msec)
        await fixture.fire(at: 20 * Self.msec)
        #expect(fixture.sink.received == [try Self.batch(15), try Self.batch(16, lsb: 3), try Self.batch(17)])
        #expect(fixture.sink.streams == [Self.one, Self.one, Self.one])
        #expect(await fixture.driver.stream(Self.one)?.idleFlushes == 2)
    }
}
