import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension ActiveSensingTests {
    @Test
    func pollReportsLossAtTheDeadlineNotBeforeAndNeverAgain() throws {
        var observer = try Self.armed(timeout: 100, at: 1_000)
        #expect(try observer.poll(at: Self.at(1_099)) == .none)
        #expect(observer.phase == .armed(deadline: 1_100))
        #expect(try observer.poll(at: Self.at(1_100)) == Self.lost())
        #expect(observer.phase == .lost(since: 1_100))
        #expect(try observer.poll(at: Self.at(1_101)) == .none)
        #expect(try observer.poll(at: Self.at(1_100_000)) == .none)
        #expect(observer.phase == .lost(since: 1_100))
    }

    @Test
    func lostSinceIsTheElapsedDeadlineNotTheStampOfTheNoticingCall() throws {
        var observer = try Self.armed(timeout: 100, at: 1_000)
        #expect(try observer.poll(at: Self.at(5_000)) == Self.lost())
        #expect(observer.phase == .lost(since: 1_100))
        #expect(observer.lastTick == 5_000)
    }

    @Test
    func eventOneTickBeforeTheDeadlineRefreshesInsteadOfLosing() throws {
        var observer = try Self.armed(timeout: 100, at: 0)
        #expect(try observer.observe(Self.channelEvent, at: Self.at(99)) == .none)
        #expect(observer.phase == .armed(deadline: 199))
    }

    @Test
    func lateOtherEventReportsTheLossAndDoesNotRefresh() throws {
        var observer = try Self.armed(timeout: 100, action: .requestInputLost, at: 0)
        let outcome = try observer.observe(Self.channelEvent, at: Self.at(100))
        #expect(outcome == Self.lost(request: true))
        #expect(observer.phase == .lost(since: 100))
        #expect(try observer.poll(at: Self.at(5_000)) == .none)
    }

    @Test
    func lateSensingByteReportsTheLossThenArmsAgain() throws {
        var observer = try Self.armed(timeout: 100, at: 0)
        #expect(try observer.observe(Self.sensing, at: Self.at(100)) == Self.lost())
        #expect(observer.phase == .armed(deadline: 200))
        #expect(try observer.poll(at: Self.at(199)) == .none)
        #expect(try observer.poll(at: Self.at(200)) == Self.lost())
    }

    @Test
    func lateSystemResetReportsTheLossThenDisarms() throws {
        var observer = try Self.armed(timeout: 100, at: 0)
        #expect(try observer.observe(Self.reset, at: Self.at(150)) == Self.lost())
        #expect(observer.phase == .unarmed)
        #expect(try observer.poll(at: Self.at(10_000)) == .none)
    }

    @Test
    func stampZeroIsALegitimateStampAndIsRecorded() throws {
        var observer = try Self.observer(timeout: 100)
        #expect(try observer.observe(Self.sensing, at: Self.at(0)) == .armed)
        #expect(observer.lastTick == 0)
        #expect(observer.phase == .armed(deadline: 100))
        #expect(try observer.poll(at: Self.at(0)) == .none)
        #expect(observer.lastTick == 0)
    }

    @Test
    func stampZeroAfterALaterStampIsRefusedAndKeepsTheLastTick() throws {
        var observer = try Self.observer(timeout: 100)
        _ = try observer.poll(at: Self.at(5))
        #expect(throws: ActiveSensingRefusal.tickRegressed(last: 5, found: 0)) {
            try observer.poll(at: Self.at(0))
        }
        #expect(observer.lastTick == 5)
    }

    @Test
    func equalStampsAreAcceptedForEveryCallKind() throws {
        var observer = try Self.armed(timeout: 100, at: 50)
        #expect(try observer.poll(at: Self.at(50)) == .none)
        #expect(try observer.observe(Self.channelEvent, at: Self.at(50)) == .none)
        #expect(try observer.observe(Self.sensing, at: Self.at(50)) == .none)
        #expect(observer.phase == .armed(deadline: 150))
        #expect(observer.lastTick == 50)
    }

    @Test
    func pollAdvancesTimeSoAnEarlierEventIsRefused() throws {
        var observer = try Self.armed(timeout: 1_000, at: 0)
        _ = try observer.poll(at: Self.at(500))
        #expect(throws: ActiveSensingRefusal.tickRegressed(last: 500, found: 499)) {
            try observer.observe(Self.channelEvent, at: Self.at(499))
        }
        #expect(try observer.observe(Self.channelEvent, at: Self.at(500)) == .none)
    }

    @Test
    func timeoutOfOneTickLosesOneTickAfterTheEvent() throws {
        var observer = try Self.armed(timeout: 1, at: 10)
        #expect(observer.phase == .armed(deadline: 11))
        #expect(try observer.poll(at: Self.at(10)) == .none)
        #expect(try observer.poll(at: Self.at(11)) == Self.lost())
    }

    @Test
    func maximumTimeoutPlacesTheDeadlineExactlyTwoToTheFortyEighthTicksAhead() throws {
        let maximum: UInt64 = 1 << 48
        var observer = try Self.armed(timeout: maximum, at: 7)
        #expect(observer.phase == .armed(deadline: 7 + maximum))
        #expect(try observer.poll(at: Self.at(7 + maximum - 1)) == .none)
        #expect(try observer.poll(at: Self.at(7 + maximum)) == Self.lost())
    }

    @Test
    func repeatedRunsOfTheSameScriptGiveTheSameOutcomes() throws {
        func run() throws -> [ActiveSensingOutcome] {
            var observer = try Self.observer(timeout: 20, action: .requestInputLost)
            var outcomes: [ActiveSensingOutcome] = []
            outcomes.append(try observer.observe(Self.sensing, at: Self.at(0)))
            outcomes.append(try observer.poll(at: Self.at(20)))
            outcomes.append(try observer.observe(Self.sensing, at: Self.at(30)))
            outcomes.append(try observer.observe(Self.channelEvent, at: Self.at(60)))
            return outcomes
        }
        let expected: [ActiveSensingOutcome] = [.armed, Self.lost(request: true), .armed, Self.lost(request: true)]
        #expect(try run() == expected)
        #expect(try run() == expected)
    }
}
