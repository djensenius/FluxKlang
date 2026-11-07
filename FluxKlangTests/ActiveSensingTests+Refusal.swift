import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension ActiveSensingTests {
    /// One observer per phase, each with a non-default input, loss action and last tick.
    static func observersInEveryPhase() throws -> [(label: String, observer: ActiveSensingObserver)] {
        var unarmed = try observer(timeout: 300, action: .requestInputLost, input: inputNine)
        _ = try unarmed.poll(at: at(1_000))
        let armedOne = try armed(timeout: 300, action: .requestInputLost, input: inputNine, at: 1_000)
        var lostOne = try armed(timeout: 300, action: .requestInputLost, input: inputNine, at: 1_000)
        _ = try lostOne.poll(at: at(1_400))
        return [("unarmed", unarmed), ("armed", armedOne), ("lost", lostOne)]
    }

    @Test
    func regressedObserveAndPollLeaveTheWholeObserverUnchangedInEveryPhase() throws {
        for item in try Self.observersInEveryPhase() {
            var observer = item.observer
            let before = observer
            let last = try #require(before.lastTick)
            #expect(throws: ActiveSensingRefusal.tickRegressed(last: last, found: last - 1)) {
                try observer.observe(Self.sensing, at: Self.at(last - 1))
            }
            #expect(observer == before, "\(item.label) after refused observe")
            #expect(throws: ActiveSensingRefusal.tickRegressed(last: last, found: 0)) {
                try observer.poll(at: Self.at(0))
            }
            #expect(observer == before, "\(item.label) after refused poll")
            #expect(throws: ActiveSensingRefusal.tickRegressed(last: last, found: 999)) {
                try observer.observe(Self.reset, at: Self.at(999))
            }
            #expect(observer == before, "\(item.label) after refused reset")
        }
    }

    @Test
    func deadlineOverflowIsRefusedOneTickBeyondTheLargestFittingStamp() throws {
        var fits = try Self.observer(timeout: 5)
        #expect(try fits.observe(Self.sensing, at: Self.at(UInt64.max - 5)) == .armed)
        #expect(fits.phase == .armed(deadline: UInt64.max))

        var overflows = try Self.observer(timeout: 5, action: .requestInputLost, input: Self.inputNine)
        let before = overflows
        #expect(throws: ActiveSensingRefusal.deadlineOverflow) {
            try overflows.observe(Self.sensing, at: Self.at(UInt64.max - 4))
        }
        #expect(overflows == before)
        #expect(overflows.phase == .unarmed)
        #expect(overflows.lastTick == nil)
    }

    @Test
    func refreshOverflowIsRefusedAndKeepsTheArmedStateUnchanged() throws {
        let maxStamp = UInt64.max
        var observer = try Self.armed(timeout: 100, action: .requestInputLost, input: Self.inputNine,
                                      at: maxStamp - 150)
        #expect(observer.phase == .armed(deadline: maxStamp - 50))
        let before = observer
        #expect(throws: ActiveSensingRefusal.deadlineOverflow) {
            try observer.observe(Self.channelEvent, at: Self.at(maxStamp - 99))
        }
        #expect(observer == before)
        #expect(try observer.observe(Self.channelEvent, at: Self.at(maxStamp - 100)) == .none)
        #expect(observer.phase == .armed(deadline: maxStamp))
    }

    @Test
    func overflowOnALateEventLeavesTheLossUnreportedUntilAPollNoticesIt() throws {
        let maxStamp = UInt64.max
        var observer = try Self.armed(timeout: 100, action: .requestInputLost, at: maxStamp - 150)
        let before = observer
        #expect(throws: ActiveSensingRefusal.deadlineOverflow) {
            try observer.observe(Self.sensing, at: Self.at(maxStamp - 40))
        }
        #expect(observer == before)
        #expect(try observer.poll(at: Self.at(maxStamp - 40)) == Self.lost(request: true))
        #expect(observer.phase == .lost(since: maxStamp - 50))
    }

    @Test
    func overflowOnlyAppliesToEventsThatArmOrRefreshNotToPollsResetsOrIgnoredEvents() throws {
        var polled = try Self.armed(timeout: 100, at: UInt64.max - 150)
        #expect(try polled.poll(at: Self.at(UInt64.max)) == Self.lost())
        var unarmed = try Self.observer(timeout: 100)
        #expect(try unarmed.observe(Self.channelEvent, at: Self.at(UInt64.max)) == .none)
        #expect(try unarmed.observe(Self.reset, at: Self.at(UInt64.max)) == .none)
        var lost = try Self.armed(timeout: 100, at: UInt64.max - 150)
        _ = try lost.poll(at: Self.at(UInt64.max - 50))
        #expect(try lost.observe(Self.channelEvent, at: Self.at(UInt64.max)) == .none)
        #expect(try lost.observe(Self.reset, at: Self.at(UInt64.max)) == .none)
        #expect(lost.phase == .unarmed)
    }

    @Test
    func aRegressionIsReportedBeforeAnOverflowWhenTheCallHasBothDefects() throws {
        var observer = try Self.observer(timeout: 5)
        _ = try observer.poll(at: Self.at(UInt64.max))
        let before = observer
        #expect(throws: ActiveSensingRefusal.tickRegressed(last: UInt64.max, found: UInt64.max - 1)) {
            try observer.observe(Self.sensing, at: Self.at(UInt64.max - 1))
        }
        #expect(observer == before)
    }

    @Test
    func regressionAndOverflowAreEachReportedWhenTheyAreTheOnlyDefect() throws {
        var regressed = try Self.observer(timeout: 5)
        _ = try regressed.poll(at: Self.at(100))
        #expect(throws: ActiveSensingRefusal.tickRegressed(last: 100, found: 99)) {
            try regressed.observe(Self.sensing, at: Self.at(99))
        }
        var overflowed = try Self.observer(timeout: 5)
        #expect(throws: ActiveSensingRefusal.deadlineOverflow) {
            try overflowed.observe(Self.sensing, at: Self.at(UInt64.max))
        }
    }

    @Test
    func aRefusedCallDoesNotConsumeThePendingLoss() throws {
        var observer = try Self.armed(timeout: 100, action: .requestInputLost, input: Self.inputNine, at: 1_000)
        _ = try observer.observe(Self.channelEvent, at: Self.at(1_050))
        let before = observer
        #expect(throws: ActiveSensingRefusal.tickRegressed(last: 1_050, found: 1_049)) {
            try observer.poll(at: Self.at(1_049))
        }
        #expect(observer == before)
        #expect(try observer.poll(at: Self.at(1_150)) == Self.lost(Self.inputNine, request: true))
    }

    @Test
    func lateNonSensingEventAtAnOverflowingStampStillReportsTheLoss() throws {
        let maxStamp = UInt64.max
        let events: [MIDI1Event] = [
            Self.channelEvent,
            .systemCommon(status: 0xF2, data1: 1, data2: 2),
            .sysEx(payload: [0x7E, 0x7F, 0x09]),
            .realTime(status: 0xF8)
        ]
        for event in events {
            var observer = try Self.armed(timeout: 100, action: .requestInputLost, at: maxStamp - 150)
            #expect(observer.phase == .armed(deadline: maxStamp - 50))
            #expect(try observer.observe(event, at: Self.at(maxStamp)) == Self.lost(request: true), "\(event)")
            #expect(observer.phase == .lost(since: maxStamp - 50), "\(event)")
            #expect(observer.lastTick == maxStamp)
        }
    }

    @Test
    func sensingByteOnALostObserverAtAnOverflowingStampIsRefusedWithTheWholeValueUnchanged() throws {
        let maxStamp = UInt64.max
        var observer = try Self.armed(timeout: 100, action: .requestInputLost, input: Self.inputNine,
                                      at: maxStamp - 150)
        #expect(try observer.poll(at: Self.at(maxStamp - 50)) == Self.lost(Self.inputNine, request: true))
        let before = observer
        #expect(throws: ActiveSensingRefusal.deadlineOverflow) {
            try observer.observe(Self.sensing, at: Self.at(maxStamp - 40))
        }
        #expect(observer == before)
        #expect(observer.phase == .lost(since: maxStamp - 50))
        #expect(observer.lastTick == maxStamp - 50)
    }

    @Test
    func aByteWithAnEarlierStampIsRefusedAndChangesNothing() throws {
        var observer = try Self.armed(action: .requestInputLost, at: 50)
        let before = observer
        for byte in [UInt8(0x40), 0xFE, 0xFF] {
            #expect(throws: ActiveSensingRefusal.tickRegressed(last: 50, found: 49)) {
                try observer.observe(byte: byte, at: Self.at(49))
            }
            #expect(observer == before, "byte \(byte)")
        }
        #expect(try observer.observe(byte: 0x40, at: Self.at(50)) == .none)
    }

    @Test
    func aLateSensingByteWhoseReArmOverflowsIsRefusedAndALaterPollReportsTheLoss() throws {
        let maxStamp = UInt64.max
        var observer = try Self.armed(timeout: 100, action: .requestInputLost, at: maxStamp - 150)
        let before = observer
        #expect(throws: ActiveSensingRefusal.deadlineOverflow) {
            try observer.observe(byte: 0xFE, at: Self.at(maxStamp))
        }
        #expect(observer == before)
        #expect(try observer.poll(at: Self.at(maxStamp)) == Self.lost(request: true))
        #expect(observer.phase == .lost(since: maxStamp - 50))
    }

    @Test
    func aSensingByteOnALostObserverAtAnOverflowingStampIsRefusedWithTheWholeValueUnchanged() throws {
        let maxStamp = UInt64.max
        var observer = try Self.armed(timeout: 100, at: maxStamp - 150)
        #expect(try observer.poll(at: Self.at(maxStamp - 50)) == Self.lost())
        let before = observer
        #expect(throws: ActiveSensingRefusal.deadlineOverflow) {
            try observer.observe(byte: 0xFE, at: Self.at(maxStamp - 40))
        }
        #expect(observer == before)
        #expect(try observer.observe(byte: 0x40, at: Self.at(maxStamp - 40)) == .none)
        #expect(observer.phase == .lost(since: maxStamp - 50))
    }

    @Test
    func aLateDataByteAtAnOverflowingStampStillReportsTheLoss() throws {
        let maxStamp = UInt64.max
        var observer = try Self.armed(timeout: 100, action: .requestInputLost, at: maxStamp - 150)
        #expect(try observer.observe(byte: 0x40, at: Self.at(maxStamp)) == Self.lost(request: true))
        #expect(observer.phase == .lost(since: maxStamp - 50))
        #expect(observer.lastTick == maxStamp)
    }
}
