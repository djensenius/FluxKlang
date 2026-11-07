import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

// MARK: - Hold table

extension ControlFeedbackTests {
    static func holdTable(holds: Int = 4, timeout: UInt64 = 50) throws -> ControlTouchHold {
        ControlTouchHold(policy: try policy(holds: holds, timeout: timeout))
    }

    @Test("A hold is live through its timeout and expired one tick later")
    func holdTimeoutBoundary() throws {
        var table = try Self.holdTable(timeout: 50)
        let started = try table.touch(Self.sourceA, now: 100)
        #expect(started)
        #expect(table.deadlines == [Self.sourceA: 150])
        #expect(table.isHeld(Self.sourceA, at: 100))
        #expect(table.isHeld(Self.sourceA, at: 150))
        #expect(!table.isHeld(Self.sourceA, at: 151))
        #expect(!table.isHeld(Self.sourceB, at: 100))
        #expect(table.capacity == 4 && table.timeoutTicks == 50)
    }

    @Test("A duplicate touch keeps the first deadline: the timeout is not renewed")
    func duplicateTouchKeepsTheFirstDeadline() throws {
        var table = try Self.holdTable(timeout: 50)
        _ = try table.touch(Self.sourceA, now: 100)
        let before = table
        let again = try table.touch(Self.sourceA, now: 120)
        #expect(!again)
        #expect(table == before)
        #expect(table.isHeld(Self.sourceA, at: 150))
        #expect(!table.isHeld(Self.sourceA, at: 151))
    }

    @Test("Touching again after the timeout starts a new hold")
    func touchAfterExpiryStartsANewHold() throws {
        var table = try Self.holdTable(timeout: 50)
        _ = try table.touch(Self.sourceA, now: 100)
        let fresh = try table.touch(Self.sourceA, now: 151)
        #expect(fresh)
        #expect(table.deadlines == [Self.sourceA: 201])
    }

    @Test("A table of N holds refuses the N+1st source and evicts none")
    func holdTableBoundary() throws {
        var table = try Self.holdTable(holds: 2, timeout: 50)
        _ = try table.touch(Self.sourceA, now: 100)
        _ = try table.touch(Self.sourceB, now: 101)
        let full = table
        #expect(throws: ControlFeedbackRefusal.holdTableFull(capacity: 2)) {
            try table.touch(Self.sourceC, now: 102)
        }
        #expect(table == full)
        #expect(table.isHeld(Self.sourceA, at: 102) && table.isHeld(Self.sourceB, at: 102))
        let again = try table.touch(Self.sourceA, now: 102)
        #expect(!again)
        #expect(table == full)
    }

    @Test("Expired holds free their slots: the table is still full at deadline N and has room at N+1")
    func expiredHoldsFreeTheirSlots() throws {
        var table = try Self.holdTable(holds: 2, timeout: 50)
        _ = try table.touch(Self.sourceA, now: 100)
        _ = try table.touch(Self.sourceB, now: 120)
        var atDeadline = table
        #expect(throws: ControlFeedbackRefusal.holdTableFull(capacity: 2)) {
            try atDeadline.touch(Self.sourceC, now: 150)
        }
        #expect(atDeadline == table)
        var pastDeadline = table
        let started = try pastDeadline.touch(Self.sourceC, now: 151)
        #expect(started)
        #expect(pastDeadline.deadlines == [Self.sourceB: 170, Self.sourceC: 201])
    }

    @Test("Release reports whether the hold was live: yes through its deadline, no one tick later")
    func releaseReportsLiveness() throws {
        let cases: [(tick: UInt64, live: Bool)] = [(150, true), (151, false)]
        for entry in cases {
            var table = try Self.holdTable(timeout: 50)
            _ = try table.touch(Self.sourceA, now: 100)
            let wasLive = table.release(Self.sourceA, at: entry.tick)
            #expect(wasLive == entry.live)
            #expect(table.deadlines.isEmpty)
            let again = table.release(Self.sourceA, at: entry.tick)
            #expect(!again)
        }
        var untouched = try Self.holdTable()
        let absent = untouched.release(Self.sourceB, at: 5)
        #expect(!absent)
        let fresh = try Self.holdTable()
        #expect(untouched == fresh)
    }

    @Test("A hold's deadline saturates at UInt64.max: the sum fits at N and overflows at N+1")
    func holdDeadlineSaturates() throws {
        let top = UInt64.max
        var table = try Self.holdTable(timeout: 50)
        _ = try table.touch(Self.sourceA, now: top - 51)
        _ = try table.touch(Self.sourceB, now: top - 50)
        _ = try table.touch(Self.sourceC, now: top - 49)
        #expect(table.deadlines == [Self.sourceA: top - 1, Self.sourceB: top, Self.sourceC: top])
        #expect(!table.isHeld(Self.sourceA, at: top))
        #expect(table.isHeld(Self.sourceB, at: top) && table.isHeld(Self.sourceC, at: top))
    }

    @Test("The live count ignores expired holds, which stay stored until the next successful touch")
    func liveCountIgnoresExpiredHolds() throws {
        var table = try Self.holdTable(timeout: 50)
        _ = try table.touch(Self.sourceA, now: 0)
        _ = try table.touch(Self.sourceB, now: 50)
        #expect(table.liveCount(at: 50) == 2)
        #expect(table.liveCount(at: 51) == 1)
        #expect(table.liveCount(at: 100) == 1)
        #expect(table.liveCount(at: 101) == 0)
        #expect(table.deadlines.count == 2)
    }
}

// MARK: - Planner hold

extension ControlFeedbackTests {
    @Test("Touch holds the controller; release emits one message at the newest host position")
    func touchHoldsThenReleaseConverges() throws {
        var planner = try Self.planner()
        let binding = try Self.binding()
        _ = try Self.answer(&planner, binding, host: 20, now: 1)
        let started = try planner.touch(Self.sourceA, now: 2)
        #expect(started)
        let moves: [(tick: UInt64, value: Double)] = [(3, 30), (4, 40), (5, 50)]
        for move in moves {
            let held = try Self.answer(&planner, binding, host: move.value, now: move.tick)
            #expect(held == .suppressed(.hold))
        }
        #expect(try planner.due(at: 5).isEmpty)
        let truth = try Self.levelTruth(50)
        let released = try planner.release(Self.sourceA, bindings: [binding], truth: truth, now: 6)
        let expected = try Self.told(binding, 0.5, .release)
        #expect(released == [expected])
        #expect(try planner.due(at: 6).isEmpty)
        let settled = try Self.answer(&planner, binding, host: 50, now: 7)
        #expect(settled == .suppressed(.unchanged))
    }

    @Test("Release sends nothing when the controller already shows the host's position")
    func releaseIsSilentWhenNothingChanged() throws {
        var planner = try Self.planner()
        let binding = try Self.binding()
        _ = try Self.answer(&planner, binding, host: 20, now: 1)
        _ = try planner.touch(Self.sourceA, now: 2)
        let away = try Self.answer(&planner, binding, host: 70, now: 3)
        let back = try Self.answer(&planner, binding, host: 20, now: 4)
        #expect(away == .suppressed(.hold) && back == .suppressed(.hold))
        #expect(try planner.due(at: 4).isEmpty)
        let released = try planner.release(Self.sourceA, bindings: [binding], truth: Self.levelTruth(20), now: 5)
        #expect(released == [Self.withheld(binding, .unchanged)])
        #expect(!planner.holds.isHeld(Self.sourceA, at: 5))
    }

    @Test("Releasing after a gesture the host applied as asked sends nothing: an echo in the window, then unchanged")
    func releaseIsSilentForAnAppliedGesture() throws {
        let ticks: [(tick: UInt64, why: ControlFeedbackSuppression)] = [(4, .echo), (13, .unchanged)]
        for entry in ticks {
            var planner = try Self.planner(window: 10)
            let binding = try Self.binding()
            let truth = try Self.levelTruth(50)
            _ = try planner.touch(Self.sourceA, now: 1)
            let move = try planner.receive(.absolute(normalized: 0.5), for: binding, truth: truth, now: 2)
            #expect(move == .move)
            let held = try Self.answer(&planner, binding, host: 50, now: 3)
            #expect(held == .suppressed(.hold))
            let released = try planner.release(Self.sourceA, bindings: [binding], truth: truth, now: entry.tick)
            #expect(released == [Self.withheld(binding, entry.why)])
        }
    }

    @Test("Releasing after a gesture the host clamped sends one correction at the applied position")
    func releaseCorrectsAClampedGesture() throws {
        var planner = try Self.planner(window: 10)
        let binding = try Self.binding()
        let truth = try Self.levelTruth(40)
        _ = try planner.touch(Self.sourceA, now: 1)
        _ = try planner.receive(.absolute(normalized: 0.5), for: binding, truth: truth, now: 2)
        let held = try Self.answer(&planner, binding, host: 40, now: 3)
        #expect(held == .suppressed(.hold))
        let released = try planner.release(Self.sourceA, bindings: [binding], truth: truth, now: 4)
        let expected = try Self.told(binding, 0.4, .release)
        #expect(released == [expected])
        #expect(planner.shownStep(of: binding.id) == 51)
        let repeated = try Self.answer(&planner, binding, host: 40, now: 5)
        #expect(repeated == .suppressed(.unchanged))
    }

    @Test("A move the host refused during a touch is corrected once on release")
    func moveRefusedDuringATouchIsCorrectedOnRelease() throws {
        var planner = try Self.planner()
        let binding = try Self.binding()
        let down = try Self.levelTruth(nil)
        let truth = try Self.levelTruth(60)
        _ = try Self.answer(&planner, binding, host: 60, now: 1)
        _ = try planner.touch(Self.sourceA, now: 2)
        let refusal = try planner.receive(.absolute(normalized: 0.4), for: binding, truth: down, now: 3)
        #expect(refusal == .refused(.valueUnavailable(Self.level)))
        #expect(planner.shownStep(of: binding.id) == nil)
        #expect(try planner.due(at: 3).isEmpty)
        let released = try planner.release(Self.sourceA, bindings: [binding], truth: truth, now: 4)
        let expected = try Self.told(binding, 0.6, .release)
        #expect(released == [expected])
        #expect(planner.shownStep(of: binding.id) == 76)
        #expect(try planner.due(at: 4).isEmpty)
        let settled = try Self.answer(&planner, binding, host: 60, .refresh, now: 5)
        #expect(settled == .suppressed(.unchanged))
    }

    @Test("Release answers a binding the planner has not seen yet")
    func releaseAnswersUntrackedBindings() throws {
        var planner = try Self.planner()
        let binding = try Self.binding()
        _ = try planner.touch(Self.sourceA, now: 1)
        let released = try planner.release(Self.sourceA, bindings: [binding], truth: Self.levelTruth(50), now: 2)
        let expected = try Self.told(binding, 0.5, .release)
        #expect(released == [expected])
        #expect(planner.isTracked(binding.id))
    }

    @Test("A duplicate touch changes nothing but the clock and keeps the first timeout")
    func duplicateTouchIsIdempotent() throws {
        var planner = try Self.planner(timeout: 50)
        let first = try planner.touch(Self.sourceA, now: 10)
        let before = planner
        let second = try planner.touch(Self.sourceA, now: 20)
        #expect(first && !second)
        let expected = try Self.advanced(before, to: 20)
        #expect(planner == expected)
        #expect(planner.holds.deadlines == [Self.sourceA: 60])
    }

    @Test("A duplicate release and a release without touch change nothing but the clock")
    func duplicateAndOrphanReleaseAreIdempotent() throws {
        var planner = try Self.planner()
        let binding = try Self.binding()
        let truth = try Self.levelTruth(50)
        _ = try Self.answer(&planner, binding, host: 20, now: 1)
        let untouched = planner
        let orphan = try planner.release(Self.sourceA, bindings: [binding], truth: truth, now: 2)
        #expect(orphan.isEmpty)
        let expected = try Self.advanced(untouched, to: 2)
        #expect(planner == expected)
        _ = try planner.touch(Self.sourceA, now: 3)
        _ = try Self.answer(&planner, binding, host: 50, now: 4)
        let first = try planner.release(Self.sourceA, bindings: [binding], truth: truth, now: 5)
        let expectedFirst = try Self.told(binding, 0.5, .release)
        #expect(first == [expectedFirst])
        let settled = planner
        let second = try planner.release(Self.sourceA, bindings: [binding], truth: truth, now: 5)
        #expect(second.isEmpty)
        #expect(planner == settled)
    }

    @Test("A hold suppresses through timeout N and lets a message out at N+1")
    func plannerHoldTimeoutBoundary() throws {
        let cases: [(tick: UInt64, held: Bool)] = [(150, true), (151, false)]
        for entry in cases {
            var planner = try Self.planner(timeout: 50)
            let binding = try Self.binding()
            _ = try Self.answer(&planner, binding, host: 20, now: 90)
            _ = try planner.touch(Self.sourceA, now: 100)
            let result = try Self.answer(&planner, binding, host: 70, .refresh, now: entry.tick)
            if entry.held {
                #expect(result == .suppressed(.hold))
                #expect(try planner.due(at: entry.tick).isEmpty)
            } else {
                let expected = try Self.message(0.7, .refresh)
                #expect(result == .message(expected))
            }
        }
    }

    @Test("A hold that timed out leaves its correction to due; releasing it afterwards sends nothing")
    func releaseAfterExpiryLeavesTheCorrectionToDue() throws {
        var planner = try Self.planner(timeout: 50)
        let binding = try Self.binding()
        let truth = try Self.levelTruth(70)
        _ = try Self.answer(&planner, binding, host: 20, now: 90)
        _ = try planner.touch(Self.sourceA, now: 100)
        let held = try Self.answer(&planner, binding, host: 70, now: 120)
        #expect(held == .suppressed(.hold))
        #expect(try planner.due(at: 150).isEmpty)
        #expect(try planner.due(at: 151) == [binding.id])
        let late = try planner.release(Self.sourceA, bindings: [binding], truth: truth, now: 152)
        #expect(late.isEmpty)
        #expect(try planner.due(at: 152) == [binding.id])
        let corrected = try Self.answer(&planner, binding, host: 70, .refresh, now: 152)
        let expected = try Self.message(0.7, .refresh)
        #expect(corrected == .message(expected))
        #expect(try planner.due(at: 152).isEmpty)
    }

    @Test("A controller move while a correction is owed settles it: due lists nothing once the hold times out")
    func receivedMoveSettlesTheDebt() throws {
        var planner = try Self.planner(window: 10, timeout: 20)
        let binding = try Self.binding()
        let truth = try Self.levelTruth(70)
        _ = try Self.answer(&planner, binding, host: 20, now: 0)
        _ = try planner.touch(Self.sourceA, now: 1)
        let held = try Self.answer(&planner, binding, host: 70, now: 2)
        #expect(held == .suppressed(.hold))
        let moved = try planner.receive(.absolute(normalized: 0.7), for: binding, truth: truth, now: 3)
        #expect(moved == .move)
        // The hold ran out at tick 21 unreleased; the controller already shows what the host wants, so nothing is owed.
        #expect(try planner.due(at: 22).isEmpty)
        let settled = try Self.answer(&planner, binding, host: 70, .refresh, now: 22)
        #expect(settled == .suppressed(.unchanged))
    }

    @Test("A hold silences only its own source, and release answers only that source's bindings")
    func holdAffectsOnlyItsOwnSource() throws {
        var planner = try Self.planner()
        let held = try Self.binding("a")
        let free = try Self.binding("b")
        let truth = try Self.levelTruth(60)
        _ = try planner.plan([held, free], truth: Self.levelTruth(20), reason: .scene, now: 1)
        _ = try planner.touch(Self.sourceA, now: 2)
        let during = try planner.plan([held, free], truth: truth, reason: .scene, now: 3)
        let freeTold = try Self.told(free, 0.6, .scene)
        #expect(during == [Self.withheld(held, .hold), freeTold])
        let released = try planner.release(Self.sourceA, bindings: [free, held], truth: truth, now: 4)
        let heldTold = try Self.told(held, 0.6, .release)
        #expect(released == [heldTold])
    }

    @Test("A hold wins over a live echo and a spent emit budget")
    func holdOutranksEchoAndBudget() throws {
        var planner = try Self.planner(window: 10, budget: 1)
        let binding = try Self.binding()
        let truth = try Self.levelTruth(50)
        _ = try Self.answer(&planner, binding, host: 20, now: 1)
        _ = try planner.receive(.absolute(normalized: 0.5), for: binding, truth: truth, now: 2)
        _ = try planner.touch(Self.sourceA, now: 3)
        let overEcho = try Self.answer(&planner, binding, host: 50, now: 4)
        let overBudget = try Self.answer(&planner, binding, host: 90, now: 5)
        #expect(overEcho == .suppressed(.hold))
        #expect(overBudget == .suppressed(.hold))
    }

    @Test("Release obeys the emit budget: a spent budget coalesces and due lists it once a slot frees")
    func releaseObeysTheEmitBudget() throws {
        var planner = try Self.planner(window: 10, budget: 1)
        let binding = try Self.binding()
        let truth = try Self.levelTruth(70)
        _ = try Self.answer(&planner, binding, host: 20, now: 0)
        _ = try planner.touch(Self.sourceA, now: 1)
        _ = try Self.answer(&planner, binding, host: 70, now: 2)
        let released = try planner.release(Self.sourceA, bindings: [binding], truth: truth, now: 3)
        #expect(released == [Self.withheld(binding, .coalesced)])
        #expect(try planner.due(at: 10).isEmpty)
        #expect(try planner.due(at: 11) == [binding.id])
        let sent = try planner.plan([binding], truth: truth, reason: .refresh, now: 11)
        let expected = try Self.told(binding, 0.7, .refresh)
        #expect(sent == [expected])
    }

    @Test("The hold table refuses the N+1st source, evicts no hold and frees a slot on release")
    func plannerHoldTableBoundary() throws {
        var planner = try Self.planner(holds: 2)
        let bindings = try ["a", "b", "c"].map { try Self.binding($0) }
        _ = try planner.plan(bindings, truth: Self.levelTruth(20), reason: .scene, now: 1)
        _ = try planner.touch(Self.sourceA, now: 2)
        _ = try planner.touch(Self.sourceB, now: 2)
        let before = planner
        #expect(throws: ControlFeedbackRefusal.holdTableFull(capacity: 2)) {
            try planner.touch(Self.sourceC, now: 3)
        }
        #expect(planner == before)
        let truth = try Self.levelTruth(80)
        let during = try planner.plan(bindings, truth: truth, reason: .scene, now: 3)
        let thirdTold = try Self.told(bindings[2], 0.8, .scene)
        #expect(during == [Self.withheld(bindings[0], .hold), Self.withheld(bindings[1], .hold), thirdTold])
        _ = try planner.release(Self.sourceA, bindings: bindings, truth: truth, now: 4)
        let started = try planner.touch(Self.sourceC, now: 4)
        #expect(started)
        #expect(planner.holds.isHeld(Self.sourceB, at: 4))
    }

    @Test("Due lists the ready bindings ascending by ID, skips held sources and honours the retry tick")
    func dueListsReadyBindingsAscending() throws {
        var planner = try Self.planner(window: 10, budget: 1)
        let bindings = try ["c", "a", "b"].map { try Self.binding($0) }
        for (tick, binding) in bindings.enumerated() {
            _ = try Self.answer(&planner, binding, host: 20, now: UInt64(tick))
        }
        // Each binding spent its single slot at ticks 0, 1 and 2, so its retry ticks are 11 (c), 12 (a) and 13 (b).
        let spent = try planner.plan(bindings, truth: Self.levelTruth(70), reason: .scene, now: 3)
        let coalesced = ControlFeedbackResult.suppressed(.coalesced)
        #expect(spent.map(\.result) == [coalesced, coalesced, coalesced])
        let ids = try ["a", "b", "c"].map { try BindingID("bnd.\($0)") }
        #expect(try planner.due(at: 10).isEmpty)
        #expect(try planner.due(at: 11) == [ids[2]])
        #expect(try planner.due(at: 12) == [ids[0], ids[2]])
        #expect(try planner.due(at: 13) == ids)
        _ = try planner.touch(Self.sourceC, now: 13)
        #expect(try planner.due(at: 13) == [ids[0], ids[1]])
    }
}
