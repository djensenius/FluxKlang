// swiftlint:disable identifier_name
import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension ControlLoopConvergenceTests {
    @Test func aHeldFaderIsKeptSilentWhileItsSiblingIsToldAndReleaseSendsExactlyOneReleaseMessage() throws {
        let a = try LoopHarness.binding("a", source: "x")
        let b = try LoopHarness.binding("b", source: "y")
        var world = try LoopHarness.world([a, b], reaction: .quiet)
        try world.connect()
        #expect(try world.planner.touch(a.source, now: world.tick))
        world.hostChanged(to: 40, because: .scene)
        try world.stepOnce()
        #expect(try world.planner.due(at: world.tick).isEmpty)
        #expect(try !world.isQuiescent())
        #expect(world.results(of: a).last == .suppressed(.hold))
        #expect(world.results(of: b).last.map { if case .message = $0 { true } else { false } } == true)
        #expect(world.planner.shownStep(of: a.id) == 0)
        #expect(world.planner.shownStep(of: b.id) == 51)
        let released = try world.planner.release(a.source, bindings: world.bindings, truth: world.host.truth(),
                                                 now: world.tick)
        let messages = released.compactMap { outcome -> ControlFeedbackMessage? in
            if case .message(let message) = outcome.result { message } else { nil }
        }
        #expect(messages.map(\.binding) == [a.id])
        #expect(messages.map(\.reason) == [.release])
        #expect(messages.map(\.position) == [0.4])
    }

    @Test func aHoldSuppressesAtTheTimeoutTickAndLetsTheCorrectionThroughOneTickLater() throws {
        let a = try LoopHarness.binding("a", source: "x")
        var world = try LoopHarness.world([a], reaction: .quiet)
        try world.connect()
        let timeout = world.planner.policy.holdTimeoutTicks
        #expect(try world.planner.touch(a.source, now: world.tick))
        let start = world.tick
        world.host.values[LoopHarness.level] = 40
        for late in [UInt64(0), 1] {
            var planner = world.planner
            let outcomes = try planner.plan(world.bindings, truth: world.host.truth(), reason: .scene,
                                            now: start + timeout + late)
            let result = try #require(outcomes.first?.result)
            if late == 0 {
                #expect(result == .suppressed(.hold))
            } else {
                guard case .message(let message) = result else { Issue.record("not a message: \(result)"); return }
                #expect(message.reason == .scene)
            }
        }
    }

    @Test func reconnectingWithoutForgettingTellsNobodyAndForgettingFirstTellsEveryControlOnce() throws {
        let a = try LoopHarness.binding("a", source: "x")
        let b = try LoopHarness.binding("b", source: "y")
        var world = try LoopHarness.world([a, b], reaction: .quiet, start: 30)
        try world.connect()
        #expect(world.deliveries.map(\.message.reason) == [.refresh, .refresh])
        #expect(try world.connect() == .converged(steps: 1))
        #expect(world.deliveries.count == 2)
        #expect(world.results(of: a).last == .suppressed(.unchanged))
        for binding in world.bindings { world.planner.forget(binding.id) }
        try world.connect()
        #expect(world.deliveries.map(\.message.binding.rawValue) == ["bnd.a", "bnd.b", "bnd.a", "bnd.b"])
        #expect(world.planner.shownStep(of: b.id) == 38)
    }

    @Test func aFifthTouchBeyondTheHoldCapacityIsRefusedAndAHeldSourceIsNotRenewed() throws {
        let capacity = try LoopHarness.policy().holdCapacity
        var planner = ControlFeedbackPlanner(policy: try LoopHarness.policy())
        let sources = try (0...capacity).map { try ControlSourceID("ctl.s\($0)") }
        for source in sources.prefix(capacity) { #expect(try planner.touch(source, now: 0)) }
        #expect(try !planner.touch(sources[0], now: 1))
        let before = planner
        #expect(throws: ControlFeedbackRefusal.holdTableFull(capacity: capacity)) {
            try planner.touch(sources[capacity], now: 1)
        }
        #expect(planner == before)
    }

    @Test func theEmitBudgetSendsNMessagesCoalescesTheNextAndSendsTheNewestValueOnceTheWindowSlides() throws {
        let a = try LoopHarness.binding("a")
        let budget = ControlFeedbackPolicy.maximumEmitBudget
        let policy = try LoopHarness.policy(window: 20, budget: budget)
        var world = try LoopHarness.world([a], reaction: .quiet, policy: policy)
        for index in 1...(budget + 1) {
            world.automation = Double(index) * 10
            world.owed = .automation
            try world.stepOnce()
        }
        let results = world.results(of: a)
        #expect(results.dropLast().allSatisfy { if case .message = $0 { true } else { false } })
        #expect(results.last == .suppressed(.coalesced))
        #expect(world.deliveries.count == budget)
        let outcome = try world.run()
        #expect(outcome == .converged(steps: 20 - budget + 1))
        #expect(world.results(of: a).filter { $0 == .suppressed(.coalesced) }.count == 1)
        let last = try #require(world.deliveries.last)
        #expect(last.message.position == Double(budget + 1) * 10 / 100)
        #expect(world.deliveries.count == budget + 1)
        #expect(world.tick == 22)
    }
}
// swiftlint:enable identifier_name
