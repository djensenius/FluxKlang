import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

private typealias Fixture = PeerBackpressureFixture
private typealias Refusal = PeerBackpressureRefusal

extension PeerBackpressureTests {
    // MARK: Budget and window

    @Test func admitAcceptsExactlyCommandsPerWindowThenRefusesTheNext() throws {
        var budget = try Fixture.budget(commands: 3, ticks: 100)
        let first = try budget.admit(now: 10)
        let second = try budget.admit(now: 10)
        let third = try budget.admit(now: 11)
        #expect([first.id, second.id, third.id] == [1, 2, 3])
        #expect(budget.admittedInWindow == 3)
        #expect(budget.windowStart == 10)
        #expect(budget.lastTick == 11)
        let before = budget
        let result = Fixture.refusal { () throws(Refusal) -> PeerInboundTicket in try budget.admit(now: 12) }
        #expect(result == .overBudget)
        #expect(budget == before)
    }

    @Test func admitWithOneCommandPerWindowRefusesTheSecondAtTheSameTick() throws {
        var budget = try Fixture.budget(commands: 1, ticks: 100)
        _ = try budget.admit(now: 5)
        let before = budget
        let result = Fixture.refusal { () throws(Refusal) -> PeerInboundTicket in try budget.admit(now: 5) }
        #expect(result == .overBudget)
        #expect(budget == before)
    }

    @Test func admitKeepsTheWindowOneTickBeforeWindowTicksAndRollsAtWindowTicks() throws {
        var budget = try Fixture.budget(commands: 1, ticks: 100)
        _ = try budget.admit(now: 1_000)
        let before = budget
        let early = Fixture.refusal { () throws(Refusal) -> PeerInboundTicket in try budget.admit(now: 1_099) }
        #expect(early == .overBudget)
        #expect(budget == before)
        let rolled = try budget.admit(now: 1_100)
        #expect(rolled.id == 2)
        #expect(budget.windowStart == 1_100)
        #expect(budget.admittedInWindow == 1)
        #expect(budget.lastTick == 1_100)
    }

    @Test func admitNewWindowStartsAtTheRollTickAndCountsFromOne() throws {
        var budget = try Fixture.budget(commands: 1, ticks: 100)
        _ = try budget.admit(now: 1_000)
        _ = try budget.admit(now: 1_150)
        let early = Fixture.refusal { () throws(Refusal) -> PeerInboundTicket in try budget.admit(now: 1_249) }
        #expect(early == .overBudget)
        _ = try budget.admit(now: 1_250)
        #expect(budget.windowStart == 1_250)
        #expect(budget.admittedInWindow == 1)
    }

    @Test func admitRollsTheWindowFromItsStartNotFromTheLastAdmission() throws {
        var budget = try Fixture.budget(commands: 2, ticks: 100)
        _ = try budget.admit(now: 1_000)
        _ = try budget.admit(now: 1_050)
        _ = try budget.admit(now: 1_100)
        #expect(budget.windowStart == 1_100)
        #expect(budget.admittedInWindow == 1)
    }

    @Test func admitFirstWindowOpensAtTheFirstTickAndAcceptsTickZeroRepeatedly() throws {
        var budget = try Fixture.budget(commands: 3, ticks: 100)
        _ = try budget.admit(now: 0)
        _ = try budget.admit(now: 0)
        #expect(budget.windowStart == 0)
        #expect(budget.lastTick == 0)
        #expect(budget.admittedInWindow == 2)
    }

    @Test func admitRefusesATickBelowTheLastAcceptedAndAcceptsAnEqualOne() throws {
        var budget = try Fixture.budget(commands: 5, ticks: 100)
        _ = try budget.admit(now: 10)
        _ = try budget.admit(now: 50)
        let before = budget
        let below = Fixture.refusal { () throws(Refusal) -> PeerInboundTicket in try budget.admit(now: 40) }
        #expect(below == .tickRegressed)
        let justBelow = Fixture.refusal { () throws(Refusal) -> PeerInboundTicket in try budget.admit(now: 49) }
        #expect(justBelow == .tickRegressed)
        #expect(budget == before)
        _ = try budget.admit(now: 50)
        #expect(budget.admittedInWindow == 3)
        #expect(budget.lastTick == 50)
    }

    @Test func admitSubtractionNearUInt64MaxKeepsTheWindowAndRollsAtTheExactTick() throws {
        let ticks: UInt64 = 4_294_967_296
        var near = try Fixture.budget(commands: 1, ticks: ticks)
        _ = try near.admit(now: UInt64.max - 5)
        let sameWindow = Fixture.refusal { () throws(Refusal) -> PeerInboundTicket in
            try near.admit(now: UInt64.max)
        }
        #expect(sameWindow == .overBudget)
        var exact = try Fixture.budget(commands: 1, ticks: ticks)
        _ = try exact.admit(now: UInt64.max - ticks)
        let oneBefore = Fixture.refusal { () throws(Refusal) -> PeerInboundTicket in
            try exact.admit(now: UInt64.max - 1)
        }
        #expect(oneBefore == .overBudget)
        _ = try exact.admit(now: UInt64.max)
        #expect(exact.windowStart == UInt64.max)
        #expect(exact.lastTick == UInt64.max)
        var far = try Fixture.budget(commands: 1, ticks: 1)
        _ = try far.admit(now: 0)
        _ = try far.admit(now: UInt64.max)
        #expect(far.windowStart == UInt64.max)
    }

    // MARK: In-flight cap and tickets

    @Test func admitRefusesInFlightFullAtMaxInFlightPlusOneAndAcceptsAfterComplete() throws {
        var budget = try Fixture.budget(commands: 10, ticks: 100, inFlight: 2)
        let first = try budget.admit(now: 1)
        _ = try budget.admit(now: 1)
        #expect(budget.inFlightCount == 2)
        let before = budget
        let result = Fixture.refusal { () throws(Refusal) -> PeerInboundTicket in try budget.admit(now: 1) }
        #expect(result == .inFlightFull)
        #expect(budget == before)
        let freed = budget.complete(first)
        #expect(freed)
        #expect(budget.inFlightCount == 1)
        let third = try budget.admit(now: 1)
        #expect(third.id == 3)
        #expect(budget.inFlightCount == 2)
    }

    @Test func admitInFlightRefusalKeepsTheOldWindowEvenWhenItWouldHaveRolled() throws {
        var budget = try Fixture.budget(commands: 1, ticks: 100, inFlight: 1)
        _ = try budget.admit(now: 1_000)
        let before = budget
        let result = Fixture.refusal { () throws(Refusal) -> PeerInboundTicket in try budget.admit(now: 1_100) }
        #expect(result == .inFlightFull)
        #expect(budget == before)
        #expect(budget.windowStart == 1_000)
        #expect(budget.admittedInWindow == 1)
        #expect(budget.lastTick == 1_000)
    }

    @Test func completeFreesExactlyOneSlotPerTicket() throws {
        var budget = try Fixture.budget(commands: 10, ticks: 100, inFlight: 3)
        let first = try budget.admit(now: 1)
        let second = try budget.admit(now: 1)
        let third = try budget.admit(now: 1)
        let freedSecond = budget.complete(second)
        #expect(freedSecond)
        #expect(budget.inFlightCount == 2)
        let freedFirst = budget.complete(first)
        #expect(freedFirst)
        #expect(budget.inFlightCount == 1)
        let freedThird = budget.complete(third)
        #expect(freedThird)
        #expect(budget.inFlightCount == 0)
    }

    @Test func completeTwiceReturnsFalseAndLeavesTheOtherTicketsInFlight() throws {
        var budget = try Fixture.budget(commands: 10, ticks: 100, inFlight: 4)
        let first = try budget.admit(now: 1)
        let second = try budget.admit(now: 1)
        _ = try budget.admit(now: 1)
        let freed = budget.complete(first)
        #expect(freed)
        let afterFirst = budget
        let again = budget.complete(first)
        #expect(!again)
        #expect(budget == afterFirst)
        #expect(budget.inFlightCount == 2)
        let freedSecond = budget.complete(second)
        #expect(freedSecond)
        #expect(budget.inFlightCount == 1)
    }

    @Test func completeOfATicketWhoseIdIsNotInFlightReturnsFalseAndChangesNothing() throws {
        var budget = try Fixture.budget(commands: 10, ticks: 100, inFlight: 4)
        _ = try budget.admit(now: 1)
        var other = try Fixture.budget(first: 500)
        let foreign = try other.admit(now: 1)
        #expect(foreign.id == 500)
        let before = budget
        let freed = budget.complete(foreign)
        #expect(!freed)
        #expect(budget == before)
        var empty = try Fixture.budget()
        let freedEmpty = empty.complete(foreign)
        #expect(!freedEmpty)
        #expect(empty.inFlightCount == 0)
    }

    @Test func completeRefusesATicketOfAnotherSessionWhoseIdCollidesWithAnInFlightId() throws {
        var budget = try Fixture.budget(commands: 10, ticks: 100, inFlight: 4)
        let own = try budget.admit(now: 1)
        var other = try Fixture.budget(commands: 10, ticks: 100, inFlight: 4, session: try Fixture.session(host: 2))
        let foreign = try other.admit(now: 1)
        #expect(foreign.id == own.id)
        #expect(foreign.session != own.session)
        let before = budget
        let freed = budget.complete(foreign)
        #expect(!freed)
        #expect(budget == before)
        #expect(budget.inFlightCount == 1)
        let freedOwn = budget.complete(own)
        #expect(freedOwn)
        #expect(budget.inFlightCount == 0)
    }

    @Test func completeTreatsTwoBudgetsOfOneSessionAsOneLineage() throws {
        var budget = try Fixture.budget(commands: 10, ticks: 100, inFlight: 4)
        let own = try budget.admit(now: 1)
        var sibling = try Fixture.budget(commands: 10, ticks: 100, inFlight: 4)
        let twin = try sibling.admit(now: 1)
        #expect(twin.id == own.id)
        #expect(twin == own)
        let freed = budget.complete(twin)
        #expect(freed)
        #expect(budget.inFlightCount == 0)
    }

    @Test func ticketIdsAreUniqueAndNeverReusedAfterComplete() throws {
        var budget = try Fixture.budget(commands: 10, ticks: 100, inFlight: 4)
        let first = try budget.admit(now: 1)
        let second = try budget.admit(now: 1)
        let freed = budget.complete(first)
        #expect(freed)
        let third = try budget.admit(now: 1)
        #expect([first.id, second.id, third.id] == [1, 2, 3])
        #expect(budget.inFlightCount == 2)
        let again = budget.complete(first)
        #expect(!again)
    }

    @Test func ticketIdCounterIssuesTheLastIdThenRefusesInsteadOfWrapping() throws {
        var budget = try Fixture.budget(commands: 10, ticks: 100, inFlight: 4, first: UInt64.max - 1)
        let first = try budget.admit(now: 1)
        let last = try budget.admit(now: 1)
        #expect(first.id == UInt64.max - 1)
        #expect(last.id == UInt64.max)
        let freedFirst = budget.complete(first)
        let freedLast = budget.complete(last)
        #expect(freedFirst)
        #expect(freedLast)
        let before = budget
        let result = Fixture.refusal { () throws(Refusal) -> PeerInboundTicket in try budget.admit(now: 7) }
        #expect(result == .overflow)
        #expect(budget == before)
    }

    // MARK: Refusal order (every fixture holds both defects; each alone is shown too)

    @Test func admitReportsTickRegressedBeforeOverBudget() throws {
        var budget = try Fixture.budget(commands: 2, ticks: 100)
        _ = try budget.admit(now: 10)
        _ = try budget.admit(now: 50)
        let before = budget
        let both = Fixture.refusal { () throws(Refusal) -> PeerInboundTicket in try budget.admit(now: 30) }
        #expect(both == .tickRegressed)
        let overBudgetAlone = Fixture.refusal { () throws(Refusal) -> PeerInboundTicket in try budget.admit(now: 60) }
        #expect(overBudgetAlone == .overBudget)
        #expect(budget == before)
    }

    @Test func admitReportsOverBudgetBeforeInFlightFull() throws {
        var budget = try Fixture.budget(commands: 2, ticks: 100, inFlight: 2)
        _ = try budget.admit(now: 10)
        _ = try budget.admit(now: 10)
        let before = budget
        let both = Fixture.refusal { () throws(Refusal) -> PeerInboundTicket in try budget.admit(now: 10) }
        #expect(both == .overBudget)
        #expect(budget == before)
        var inFlightAlone = try Fixture.budget(commands: 3, ticks: 100, inFlight: 2)
        _ = try inFlightAlone.admit(now: 10)
        _ = try inFlightAlone.admit(now: 10)
        let alone = Fixture.refusal { () throws(Refusal) -> PeerInboundTicket in try inFlightAlone.admit(now: 10) }
        #expect(alone == .inFlightFull)
    }

    @Test func admitReportsInFlightFullBeforeTicketIdOverflow() throws {
        var budget = try Fixture.budget(commands: 3, ticks: 100, inFlight: 1, first: UInt64.max)
        let issued = try budget.admit(now: 10)
        #expect(issued.id == UInt64.max)
        let before = budget
        let both = Fixture.refusal { () throws(Refusal) -> PeerInboundTicket in try budget.admit(now: 10) }
        #expect(both == .inFlightFull)
        #expect(budget == before)
        let freed = budget.complete(issued)
        #expect(freed)
        let overflowAlone = Fixture.refusal { () throws(Refusal) -> PeerInboundTicket in try budget.admit(now: 10) }
        #expect(overflowAlone == .overflow)
    }
}
