import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension AutomationBankTests {
    @Test func automationBankChecksTheEventLimitAfterEachLaneBeforeTheNextLaneRenders() throws {
        let first = try Self.bankSteps(Self.parA, 512)
        let second = try Self.bankSteps(Self.parB, 513)
        let third = try Self.bankSteps(Self.parC, 1_025)
        #expect(try Self.aloneCount(first) == 512)
        #expect(try Self.aloneCount(second) == 513)
        #expect(throws: AutomationRenderRefusal.tooManyEvents(limit: 1_024)) { try Self.aloneCount(third) }
        var bank = try Self.makeBank([first, second, third])
        let before = bank
        let tally = Self.Tally()
        let step = try tally.counting(Self.stepper())
        #expect(throws: AutomationBankRefusal.tooManyEvents(limit: 1_024)) {
            try bank.render(from: 0, to: 4_096, using: step)
        }
        #expect(tally.calls == 2)
        #expect(bank == before)
    }

    @Test func automationBankAcceptsExactlyTheEventLimitAcrossLanesAndRefusesOneMore() throws {
        let step = try Self.stepper()
        #expect(try Self.aloneCount(Self.bankSteps(Self.parA, 512)) == 512)
        #expect(try Self.aloneCount(Self.bankSteps(Self.parB, 511)) == 511)
        #expect(try Self.aloneCount(Self.bankSteps(Self.parB, 512)) == 512)
        #expect(try Self.aloneCount(Self.bankSteps(Self.parB, 513)) == 513)
        func eventCount(_ other: Int) throws -> Int {
            var bank = try Self.makeBank([Self.bankSteps(Self.parA, 512), Self.bankSteps(Self.parB, other)])
            return try bank.render(from: 0, to: 4_096, using: step).count
        }
        #expect(try eventCount(511) == 1_023)
        #expect(try eventCount(512) == 1_024)
        var over = try Self.makeBank([Self.bankSteps(Self.parA, 512), Self.bankSteps(Self.parB, 513)])
        let before = over
        #expect(throws: AutomationBankRefusal.tooManyEvents(limit: 1_024)) {
            try over.render(from: 0, to: 4_096, using: step)
        }
        #expect(over == before)
    }

    @Test func automationBankRendersSixtyFourLanesAtTheEventLimitInByteOrder() throws {
        let step = try Self.stepper()
        let last = AutomationBank.maximumLanes - 1
        func steppedBank(lastCount: Int) throws -> AutomationBank {
            var bank = AutomationBank()
            for index in (0..<AutomationBank.maximumLanes).reversed() {
                let count = index == last ? lastCount : 16
                try bank.add(Fixture.renderer(Self.bankSteps(Self.laneID(index), count)))
            }
            return bank
        }
        #expect(try Self.aloneCount(Self.bankSteps(Self.parA, 16)) == 16)
        #expect(try Self.aloneCount(Self.bankSteps(Self.parA, 17)) == 17)
        var full = try steppedBank(lastCount: 16)
        let events = try full.render(from: 0, to: 4_096, using: step)
        #expect(events.count == 1_024)
        #expect(Self.inMergeOrder(events, strict: true))
        var over = try steppedBank(lastCount: 17)
        let before = over
        #expect(throws: AutomationBankRefusal.tooManyEvents(limit: 1_024)) {
            try over.render(from: 0, to: 4_096, using: step)
        }
        #expect(over == before)
    }

    @Test func automationBankRefusesTheSixtyFifthLaneAndStaysUnchanged() throws {
        var bank = try Self.filledBank(63)
        #expect(bank.count == 63)
        try bank.add(Fixture.renderer(Self.bankLane(Self.laneID(63), [])))
        #expect(bank.count == 64)
        #expect(bank.count == AutomationBank.maximumLanes)
        let before = bank
        let extra = try Fixture.renderer(Self.bankLane(Self.laneID(64), []))
        #expect(throws: AutomationBankRefusal.laneLimitReached(limit: 64)) { try bank.add(extra) }
        #expect(bank.count == 64)
        #expect(bank == before)
    }

    @Test func automationBankChecksTheWindowBeforeAnyLaneRenders() throws {
        let limit = AutomationBlockRenderer.maximumBlockFrames
        let beyond = limit + 1
        let tally = Self.Tally()
        let step = try tally.counting(Self.stepper())
        let crowded = try Self.makeBank([Self.bankSteps(Self.parA, 1_025)])
        for var bank in [AutomationBank(), crowded] {
            let before = bank
            #expect(throws: AutomationBankRefusal.invalidWindow(start: 5, end: 5)) {
                try bank.render(from: 5, to: 5, using: step)
            }
            #expect(throws: AutomationBankRefusal.invalidWindow(start: 10, end: 5)) {
                try bank.render(from: 10, to: 5, using: step)
            }
            #expect(throws: AutomationBankRefusal.windowTooLong(start: 0, end: beyond, limit: limit)) {
                try bank.render(from: 0, to: beyond, using: step)
            }
            #expect(throws: AutomationBankRefusal.windowTooLong(start: .min, end: .max, limit: limit)) {
                try bank.render(from: .min, to: .max, using: step)
            }
            #expect(throws: AutomationBankRefusal.invalidWindow(start: .max, end: .min)) {
                try bank.render(from: .max, to: .min, using: step)
            }
            #expect(bank == before)
        }
        #expect(tally.calls == 0)
        var single = try Self.makeBank([Self.bankRamp(Self.parA)])
        let nearly = try single.render(from: 0, to: limit - 1, using: step)
        #expect(nearly == Self.golden(Self.parA))
        single.reset()
        let exact = try single.render(from: 0, to: limit, using: step)
        #expect(exact == Self.golden(Self.parA))
        #expect(single.renderers.map(\.cursor) == [limit])
    }
}
