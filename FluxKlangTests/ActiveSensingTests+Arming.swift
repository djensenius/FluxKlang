import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension ActiveSensingTests {
    @Test
    func unarmedObserverNeverReportsLossHoweverLargeTheGap() throws {
        var observer = try Self.observer(timeout: 1)
        for tick: UInt64 in [0, 1, 2, 1 << 48, UInt64.max - 1, UInt64.max] {
            #expect(try observer.poll(at: Self.at(tick)) == .none, "poll at \(tick)")
            #expect(observer.phase == .unarmed)
        }
        #expect(observer.lastTick == UInt64.max)
    }

    @Test
    func unarmedObserverIgnoresEveryOtherEventWithoutArming() throws {
        for item in Self.otherEvents {
            var observer = try Self.observer(timeout: 10)
            #expect(try observer.observe(item.event, at: Self.at(5)) == .none, "\(item.label)")
            #expect(observer.phase == .unarmed, "\(item.label) must not arm")
            #expect(observer.lastTick == 5, "\(item.label) still records the stamp")
            #expect(try observer.poll(at: Self.at(1_000)) == .none, "\(item.label) gap")
        }
    }

    @Test
    func systemResetDoesNotArmAnUnarmedObserver() throws {
        var observer = try Self.observer(timeout: 10)
        #expect(try observer.observe(Self.reset, at: Self.at(5)) == .none)
        #expect(observer.phase == .unarmed)
        #expect(observer.lastTick == 5)
        #expect(try observer.poll(at: Self.at(500)) == .none)
    }

    @Test
    func firstSensingByteArmsWithADeadlineOfStampPlusTimeout() throws {
        var observer = try Self.observer(timeout: 300)
        #expect(try observer.observe(Self.sensing, at: Self.at(1_000)) == .armed)
        #expect(observer.phase == .armed(deadline: 1_300))
        #expect(observer.lastTick == 1_000)
    }

    @Test
    func armingReportsArmedOnlyForTheTransition() throws {
        var observer = try Self.observer(timeout: 100)
        #expect(try observer.observe(Self.sensing, at: Self.at(0)) == .armed)
        #expect(try observer.observe(Self.sensing, at: Self.at(10)) == .none)
        #expect(try observer.observe(Self.channelEvent, at: Self.at(20)) == .none)
    }

    @Test
    func everyOtherEventKindRefreshesTheDeadlineWhileArmed() throws {
        for item in Self.otherEvents {
            var observer = try Self.armed(timeout: 100, at: 0)
            #expect(try observer.observe(item.event, at: Self.at(60)) == .none, "\(item.label)")
            #expect(observer.phase == .armed(deadline: 160), "\(item.label) refreshes to 160")
            #expect(try observer.poll(at: Self.at(159)) == .none, "\(item.label) at 159")
            #expect(try observer.poll(at: Self.at(160)) == Self.lost(), "\(item.label) at 160")
        }
    }

    @Test
    func sensingByteWhileArmedRefreshesTheDeadlineWithoutArmingAgain() throws {
        var observer = try Self.armed(timeout: 100, at: 0)
        #expect(try observer.observe(Self.sensing, at: Self.at(60)) == .none)
        #expect(observer.phase == .armed(deadline: 160))
        #expect(try observer.poll(at: Self.at(100)) == .none)
        #expect(try observer.poll(at: Self.at(160)) == Self.lost())
    }

    @Test
    func systemResetDisarmsAnArmedObserverAndNoLossFollows() throws {
        var observer = try Self.armed(timeout: 100, at: 0)
        #expect(try observer.observe(Self.reset, at: Self.at(40)) == .none)
        #expect(observer.phase == .unarmed)
        #expect(observer.lastTick == 40)
        #expect(try observer.poll(at: Self.at(100_000)) == .none)
        #expect(observer.phase == .unarmed)
    }

    @Test
    func systemResetTakesALostObserverBackToUnarmed() throws {
        var observer = try Self.armed(timeout: 100, at: 0)
        #expect(try observer.poll(at: Self.at(100)) == Self.lost())
        #expect(try observer.observe(Self.reset, at: Self.at(150)) == .none)
        #expect(observer.phase == .unarmed)
    }

    @Test
    func sensingByteAfterResetOrLossArmsAgain() throws {
        var observer = try Self.armed(timeout: 100, at: 0)
        _ = try observer.observe(Self.reset, at: Self.at(10))
        #expect(try observer.observe(Self.sensing, at: Self.at(20)) == .armed)
        #expect(observer.phase == .armed(deadline: 120))
        #expect(try observer.poll(at: Self.at(120)) == Self.lost())
        #expect(try observer.observe(Self.sensing, at: Self.at(200)) == .armed)
        #expect(observer.phase == .armed(deadline: 300))
        #expect(try observer.poll(at: Self.at(300)) == Self.lost())
        #expect(try observer.poll(at: Self.at(301)) == .none)
    }

    @Test
    func otherEventsNeitherRefreshNorArmALostObserver() throws {
        for item in Self.otherEvents {
            var observer = try Self.armed(timeout: 100, at: 0)
            #expect(try observer.poll(at: Self.at(100)) == Self.lost())
            #expect(try observer.observe(item.event, at: Self.at(150)) == .none, "\(item.label)")
            #expect(observer.phase == .lost(since: 100), "\(item.label) keeps the loss")
            #expect(try observer.poll(at: Self.at(10_000)) == .none, "\(item.label) does not report twice")
        }
    }
}
