import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension MTCFollowerTests {
    @discardableResult
    private static func locate(_ follower: inout MTCFollower, _ event: MIDI1Event, at ticks: UInt64) throws
        -> [MTCFollowerEvent] {
        try follower.consume(fullFrame: event, receiver: Self.receiver, at: Self.stamp(ticks))
    }

    @Test func aFullFrameForAnotherDeviceIsIgnoredWithoutAnyChange() throws {
        var result = try Self.locked()
        let before = result.follower.snapshot
        let other = try Self.fullFrame(Self.label(777, .fps25), device: 0x11)
        // Even a stamp far past the dropout threshold must not run the silence machine.
        #expect(try Self.locate(&result.follower, other, at: result.last + 10_000_000_000).isEmpty)
        #expect(result.follower.snapshot == before)
        #expect(result.follower.state == .locked)
    }

    @Test func anAllCallFullFrameIsAcceptedByAnyReceiver() throws {
        var subject = try Self.follower()
        let time = try Self.label(777, .fps25)
        let event = MTCFullFrame(deviceID: .allCall, time: time).event
        #expect(try Self.locate(&subject, event, at: 5) == [.located(frameCount: 777)])
    }

    @Test func aMalformedFullFrameIsRefusedWithTheTypedDecodeErrorAndNoChange() throws {
        var result = try Self.locked()
        let before = result.follower.snapshot
        let cases: [(MIDI1Event, TimecodeError)] = [
            (.sysEx(payload: [0x7F, 0x10, 0x01, 0x01, 0x01]), .lengthMismatch(expected: 8, actual: 5)),
            (.realTime(status: 0xF8), .notTimecodeMessage),
            (.sysEx(payload: [0x7F, 0x10, 0x01, 0x01, 0x80, 0, 0, 0]), .dataByteOutOfRange(0x80)),
            (.sysEx(payload: [0x7F, 0x10, 0x01, 0x01, 0x00, 60, 0, 0]), .fieldOutOfRange(.minutes, value: 60))
        ]
        for (event, error) in cases {
            let refusal = Self.thrown { try result.follower.consume(fullFrame: event, receiver: Self.receiver,
                                                                    at: Self.stamp(result.last + 1)) }
            #expect(refusal == .malformedFullFrame(error))
            #expect(result.follower.snapshot == before)
        }
    }

    @Test func aValidFullFrameSetsTheExactFrameCountForEveryRateAndHoldsIt() throws {
        for rate in SMPTEFrameRate.allCases {
            var subject = try Self.follower()
            let time = try SMPTETime(hours: 1, minutes: 2, seconds: 3, frames: 4, rate: rate)
            let events = try Self.locate(&subject, Self.fullFrame(time), at: 50_000)
            #expect(events == [.located(frameCount: time.frameCount)])
            #expect(subject.state == .located)
            #expect(subject.rate == rate)
            #expect(subject.direction == nil)
            #expect(try subject.frameCount(at: Self.stamp(50_000)) == time.frameCount)
            #expect(try subject.frameCount(at: Self.stamp(50_000 + 9_000_000_000)) == time.frameCount)
            #expect(Self.thrown { try subject.host(forFrameCount: time.frameCount) } == .stationary)
        }
    }

    @Test func dropFrameLabelsAreExcludedFromTheLocatedFrameCount() throws {
        var subject = try Self.follower()
        let afterTheDroppedLabels = try SMPTETime(hours: 0, minutes: 1, seconds: 0, frames: 2, rate: .fps2997DropFrame)
        #expect(try Self.locate(&subject, Self.fullFrame(afterTheDroppedLabels), at: 1) == [.located(frameCount: 1800)])
        let tenMinutes = try SMPTETime(hours: 0, minutes: 10, seconds: 0, frames: 0, rate: .fps2997DropFrame)
        #expect(try Self.locate(&subject, Self.fullFrame(tenMinutes), at: 2) == [.located(frameCount: 17_982)])
    }

    @Test func quarterFramesAfterALocateLockWithoutARelocation() throws {
        var subject = try Self.follower()
        let time = try Self.label(5000, .fps25)
        try Self.locate(&subject, Self.fullFrame(time), at: 1)
        let sequences = try Self.stream(rate: .fps25, firstEncoded: 5000, count: 2, start: 1_000)
        #expect(try Self.feed(&subject, sequences[0]) == [])
        #expect(subject.state == .acquiring)
        #expect(subject.consecutivePositions == 1)
        #expect(try Self.feed(&subject, sequences[1]) == [.locked(frameCount: 5004)])
        #expect(subject.state == .locked)
    }

    @Test func theFirstQuarterFrameAfterALocateKeepsTheFrozenPositionUntilAPositionCompletes() throws {
        var subject = try Self.follower()
        try Self.locate(&subject, Self.fullFrame(Self.label(5000, .fps25)), at: 1)
        let sequence = try Self.sequence(encoded: 9000, rate: .fps25, start: 1_000)
        try Self.feed(&subject, Array(sequence.prefix(3)))
        #expect(subject.state == .acquiring)
        #expect(try subject.frameCount(at: Self.stamp(900_000_000)) == 5000)
    }

    @Test func aLocateWhileLockedEmitsLocatedAndFreezesTheExtrapolation() throws {
        var result = try Self.locked()
        let stampAfter = result.last + 1_000
        let events = try Self.locate(&result.follower, Self.fullFrame(Self.label(123_456, .fps25)), at: stampAfter)
        #expect(events == [.located(frameCount: 123_456)])
        #expect(result.follower.state == .located)
        #expect(result.follower.consecutivePositions == 0)
        #expect(try result.follower.frameCount(at: Self.stamp(stampAfter + 400_000_000)) == 123_456)
    }

    @Test func aLocateDoesNotLockEvenWithOneRequiredPosition() throws {
        var subject = try Self.follower(Self.policy(lock: 1))
        let events = try Self.locate(&subject, Self.fullFrame(Self.label(100, .fps24)), at: 5)
        #expect(events == [.located(frameCount: 100)])
        #expect(subject.state == .located)
    }

    @Test func aLocateDiscardsAPartialSequence() throws {
        var subject = try Self.follower()
        let sequence = try Self.sequence(encoded: 1000, rate: .fps25, start: 1_000)
        try Self.feed(&subject, Array(sequence.prefix(4)))
        try Self.locate(&subject, Self.fullFrame(Self.label(2000, .fps25)), at: 100_000_000)
        let events = try Self.feed(&subject, [(sequence[4].frame, 110_000_000)])
        #expect(events == [.pieceDiscarded(.unsynchronized(piece: 4))])
    }

    @Test func aLocatedFollowerStaysLocatedForeverWhenPolled() throws {
        var subject = try Self.follower()
        try Self.locate(&subject, Self.fullFrame(Self.label(2000, .fps25)), at: 10)
        for ticks in [UInt64(1_000_000), 10_000_000_000, 5_000_000_000_000_000] {
            #expect(try subject.poll(at: Self.stamp(ticks)).isEmpty)
            #expect(subject.state == .located)
        }
    }
}
