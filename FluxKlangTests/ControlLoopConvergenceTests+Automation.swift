import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// What a run of the automation scenario ends in, compared between the two binding orders.
private struct LoopHarnessAutomationRun: Equatable {
    var held: [ControlFeedbackResult]
    var sibling: [ControlFeedbackResult]
    var deliveries: [LoopHarness.Delivery]
    var shown: [Int?]
    var host: Double?
    var outcome: LoopHarness.Outcome
}

extension ControlLoopConvergenceTests {
    @Test func anAutomationValueDoesNotOverrideAHeldControlAndReleaseSendsTheHostValueInEitherBindingOrder() throws {
        let forward = try automationRun(reversed: false, hostFollows: true)
        let reversed = try automationRun(reversed: true, hostFollows: true)
        #expect(forward == reversed)
        let automated = try #require(LoopHarness.step(of: 0.5))
        #expect(forward.held.count == 3)
        #expect(forward.held[1] == .suppressed(.hold))
        #expect(forward.sibling.count == 2)
        #expect(forward.deliveries.map(\.message.binding.rawValue) == ["bnd.a", "bnd.b", "bnd.a", "bnd.b"])
        #expect(forward.deliveries.map(\.message.reason) == [.refresh, .refresh, .release, .automation])
        #expect(forward.deliveries.map(\.message.position) == [0, 0, 0.5, 0.5])
        #expect(Set(forward.deliveries.map(\.step)).count == 2)
        #expect(forward.shown == [automated, automated])
        #expect(forward.host == 50)
        #expect(forward.outcome == .converged(steps: 0))
    }

    @Test func releaseAnswersAtHostTruthSoAnAutomationValueTheHostNeverTookIsNotSentToTheReleasedControl() throws {
        let forward = try automationRun(reversed: false, hostFollows: false)
        let reversed = try automationRun(reversed: true, hostFollows: false)
        #expect(forward == reversed)
        let automated = try #require(LoopHarness.step(of: 0.5))
        let first = try #require(forward.deliveries.first)
        #expect(forward.held == [.message(first.message), .suppressed(.hold), .suppressed(.unchanged)])
        #expect(forward.deliveries.map(\.message.reason) == [.refresh, .refresh, .automation])
        #expect(forward.shown == [0, automated])
        #expect(forward.host == 0)
        #expect(forward.outcome == .converged(steps: 0))
    }

    /// Connects two controls on separate sources, holds `x`, answers an automation value of 50 and releases `x`.
    private func automationRun(reversed: Bool, hostFollows: Bool) throws -> LoopHarnessAutomationRun {
        let held = try LoopHarness.binding("a", source: "x")
        let sibling = try LoopHarness.binding("b", source: "y")
        var world = try LoopHarness.world(reversed ? [sibling, held] : [held, sibling], reaction: .quiet)
        try world.connect()
        #expect(try world.planner.touch(held.source, now: world.tick))
        world.automation = 50
        if hostFollows { world.hostChanged(to: 50, because: .automation) } else { world.owed = .automation }
        try world.stepOnce()
        let released = try world.planner.release(held.source, bindings: world.bindings, truth: world.host.truth(),
                                                 now: world.tick)
        for outcome in released { try world.record(outcome) }
        let outcome = try world.run()
        return LoopHarnessAutomationRun(
            held: world.results(of: held), sibling: world.results(of: sibling), deliveries: world.deliveries,
            shown: [world.planner.shownStep(of: held.id), world.planner.shownStep(of: sibling.id)],
            host: world.host.values[LoopHarness.level], outcome: outcome
        )
    }
}
