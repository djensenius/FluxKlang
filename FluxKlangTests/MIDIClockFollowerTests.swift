import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

#if os(macOS)
@Suite(.productionAccessAudit)
#endif
struct MIDIClockFollowerTests {
    private static func host(_ ticks: UInt64) -> HostStamp { HostStamp(ticks: ticks) }

    /// Feeds messages at increasing host times starting at `from`.
    private static func feed(_ follower: inout MIDIClockFollower, _ messages: [MIDIClockMessage],
                             from start: UInt64 = 0) throws -> [MIDIClockFollowerEvent?] {
        var events: [MIDIClockFollowerEvent?] = []
        for (offset, message) in messages.enumerated() {
            events.append(try follower.receive(message, at: host(start + UInt64(offset))))
        }
        return events
    }

    @Test
    func startPlaysTickZeroAtTheNextClock() throws {
        var follower = try MIDIClockFollower()
        let events = try Self.feed(&follower, [.start, .clock, .clock, .clock])
        #expect(events == [.started, .pulse(ticks: 0, host: Self.host(1), located: false),
                           .pulse(ticks: 640, host: Self.host(2), located: false),
                           .pulse(ticks: 1_280, host: Self.host(3), located: false)])
        #expect(events[0]?.bumpReason == .transportRestart)
        #expect(events[1]?.bumpReason == nil)
        #expect(follower.state == .running && follower.nextPulseTicks == 1_920)
    }

    @Test
    func stopKeepsThePositionAndContinueResumesThereWithoutABump() throws {
        var follower = try MIDIClockFollower()
        _ = try Self.feed(&follower, [.start, .clock, .clock])
        let events = try Self.feed(&follower, [.stop, .clock, .clock, .continue, .clock], from: 10)
        #expect(events == [.stopped(ticks: 1_280), nil, nil, .continued(ticks: 1_280, relocated: false),
                           .pulse(ticks: 1_280, host: Self.host(14), located: false)])
        #expect(events[3]?.bumpReason == nil)
        #expect(events[0]?.bumpReason == nil)
    }

    @Test
    func songPositionWhileStoppedLocatesAndContinueStartsThere() throws {
        var follower = try MIDIClockFollower()
        _ = try Self.feed(&follower, [.start, .clock, .stop])
        let events = try Self.feed(&follower, [.songPosition(4), .continue, .clock], from: 10)
        #expect(events == [.located(ticks: 15_360), .continued(ticks: 15_360, relocated: false),
                           .pulse(ticks: 15_360, host: Self.host(12), located: false)])
        #expect(events[0]?.bumpReason == .locate(ticks: 15_360))
        #expect(follower.nextPulseTicks == 16_000)
    }

    @Test
    func startOverridesASongPosition() throws {
        var follower = try MIDIClockFollower()
        let events = try Self.feed(&follower, [.songPosition(16_383), .start, .clock])
        #expect(events == [.located(ticks: 62_910_720), .started, .pulse(ticks: 0, host: Self.host(2), located: false)])
    }

    @Test
    func songPositionWhileRunningJumpsVisiblyAtTheNextClock() throws {
        var follower = try MIDIClockFollower()
        _ = try Self.feed(&follower, [.start, .clock, .clock])
        let events = try Self.feed(&follower, [.songPosition(2), .songPosition(8), .clock, .clock], from: 10)
        #expect(events == [nil, nil, .pulse(ticks: 30_720, host: Self.host(12), located: true),
                           .pulse(ticks: 31_360, host: Self.host(13), located: false)])
        #expect(events[2]?.bumpReason == .locate(ticks: 30_720))
        #expect(events[3]?.bumpReason == nil)
    }

    @Test
    func stopBeforeAPendingJumpPlaysMakesContinueRelocate() throws {
        var follower = try MIDIClockFollower()
        _ = try Self.feed(&follower, [.start, .clock, .songPosition(1)])
        let events = try Self.feed(&follower, [.stop, .continue, .clock], from: 10)
        #expect(events == [.stopped(ticks: 3_840), .continued(ticks: 3_840, relocated: true),
                           .pulse(ticks: 3_840, host: Self.host(12), located: false)])
        #expect(events[1]?.bumpReason == .locate(ticks: 3_840))
        #expect(follower.pendingLocateTicks == nil)
    }

    @Test
    func continueFromAnUnreportedPositionRelocates() throws {
        var fresh = try MIDIClockFollower()
        #expect(try fresh.receive(.continue, at: Self.host(0)) == .continued(ticks: 0, relocated: true))
        var restored = try MIDIClockFollower(position: 7_680)
        let event = try restored.receive(.continue, at: Self.host(0))
        #expect(event?.bumpReason == .locate(ticks: 7_680))
        #expect(throws: MIDIClockError.negativeTicks(-1)) { try MIDIClockFollower(position: -1) }
    }

    @Test
    func redundantTransportMessagesAreIgnored() throws {
        var follower = try MIDIClockFollower()
        #expect(try Self.feed(&follower, [.stop, .clock]) == [nil, nil])
        _ = try Self.feed(&follower, [.start, .clock], from: 10)
        #expect(try follower.receive(.continue, at: Self.host(20)) == nil)
        #expect(try follower.receive(.start, at: Self.host(21)) == .started)
        #expect(follower.state == .armed && follower.nextPulseTicks == 0)
        #expect(try follower.receive(.stop, at: Self.host(22)) == .stopped(ticks: 0))
        #expect(try follower.receive(.stop, at: Self.host(22)) == nil)
    }

    @Test
    func songPositionWhileArmedMovesTheFirstPulse() throws {
        var follower = try MIDIClockFollower()
        let events = try Self.feed(&follower, [.start, .songPosition(1), .clock])
        #expect(events == [.started, .located(ticks: 3_840), .pulse(ticks: 3_840, host: Self.host(2), located: false)])
    }

    @Test
    func refusalsLeaveStateUnchanged() throws {
        var follower = try MIDIClockFollower()
        _ = try follower.receive(.start, at: Self.host(100))
        #expect(throws: MIDIClockError.nonMonotonicHost(previous: 100, current: 99)) {
            try follower.receive(.clock, at: Self.host(99))
        }
        #expect(throws: MIDIClockError.songPositionOutOfRange(16_384)) {
            try follower.receive(.songPosition(16_384), at: Self.host(100))
        }
        #expect(follower.state == .armed && follower.lastHost == Self.host(100))
        #expect(try follower.receive(.clock, at: Self.host(100))
                == .pulse(ticks: 0, host: Self.host(100), located: false))
        #expect(try follower.receive(.clock, at: Self.host(.max)) != nil)
    }

    @Test
    func positionNeverOverflows() throws {
        let last = Int64.max - 640
        var follower = try MIDIClockFollower(position: last)
        _ = try follower.receive(.continue, at: Self.host(0))
        #expect(try follower.receive(.clock, at: Self.host(1))
                == .pulse(ticks: last, host: Self.host(1), located: false))
        #expect(follower.nextPulseTicks == .max)
        #expect(throws: MIDIClockError.positionOverflow) { try follower.receive(.clock, at: Self.host(2)) }
        #expect(follower.nextPulseTicks == .max && follower.lastHost == Self.host(1))

        var edge = try MIDIClockFollower(position: last + 1)
        _ = try edge.receive(.continue, at: Self.host(0))
        #expect(throws: MIDIClockError.positionOverflow) { try edge.receive(.clock, at: Self.host(1)) }
        #expect(edge.state == .armed)
    }
}
