// swiftlint:disable identifier_name
import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// Closed-loop convergence (#86, I1): fake controllers and a fake host around the real `ControlFeedbackPlanner`.
@Suite(.productionAccessAudit) struct ControlLoopConvergenceTests {
    @Test func aMovedFaderIsEchoSuppressedAndItsSiblingIsToldOnceThenTheLoopIsQuiet() throws {
        let a = try LoopHarness.binding("a", source: "x")
        let b = try LoopHarness.binding("b", source: "y")
        var world = try LoopHarness.world([a, b])
        try world.connect()
        world.queue(a, try LoopHarness.raw(100))
        #expect(try world.run() == .converged(steps: 2))
        #expect(world.inbound(of: a) == [.move])
        #expect(world.inbound(of: b) == [.echo])
        #expect(world.results(of: b).count == 2)
        #expect(world.host.values[LoopHarness.level] == 100.0 * 100 / 127)
        let tail = world.deliveries.filter { $0.step > 1 }
        #expect(tail.map(\.message.binding.rawValue) == ["bnd.b"])
        #expect(world.planner.shownStep(of: a.id) == 100)
        #expect(world.planner.shownStep(of: b.id) == 100)
    }

    @Test func aQuietControllerStillConvergesAtTheStepBoundAndNotOneStepLater() throws {
        let a = try LoopHarness.binding("a")
        var world = try LoopHarness.world([a], reaction: .quiet)
        for index in 0..<LoopHarness.stepBound { world.queue(a, try LoopHarness.alternating(index)) }
        #expect(try world.run() == .converged(steps: LoopHarness.stepBound))
        var longer = try LoopHarness.world([a], reaction: .quiet)
        for index in 0...LoopHarness.stepBound { longer.queue(a, try LoopHarness.alternating(index)) }
        #expect(try longer.run() == .didNotConverge(step: LoopHarness.stepBound + 1))
    }

    @Test func aDivergentControllerOnARatchetingHostIsCaughtAsDidNotConvergeAtStepSixtyFive() throws {
        let a = try LoopHarness.binding("a")
        var world = try LoopHarness.world([a], reaction: .divergent)
        world.host.ratchet = true
        world.queue(a, try LoopHarness.raw(10))
        #expect(try world.run() == .didNotConverge(step: LoopHarness.stepBound + 1))
        #expect(world.step == LoopHarness.stepBound)
        #expect(try !world.isQuiescent())
    }

    @Test func aReflectingControllerAnsweringInsideTheEchoWindowIsAnEchoAndOutsideItIsAMove() throws {
        let a = try LoopHarness.binding("a")
        let window = try LoopHarness.policy().windowTicks
        for late in [UInt64(0), 1] {
            var world = try LoopHarness.world([a], reaction: .quiet)
            try world.connect()
            world.tick = window + late
            world.queue(a, try LoopHarness.raw(0))
            try world.run()
            let expected: ControlFeedbackInbound = late == 0 ? .echo : .move
            #expect(world.inbound(of: a) == [expected])
        }
    }

    @Test func aHostWriteCausedByAMoveIsEchoSuppressedUntilTheWindowEndsAndDueOneTickAfterIt() throws {
        let a = try LoopHarness.binding("a")
        var world = try LoopHarness.world([a], reaction: .quiet)
        try world.connect()
        let window = world.planner.policy.windowTicks
        let move = world.tick
        var truth = try world.host.truth()
        #expect(try world.planner.receive(LoopHarness.raw(100), for: a, truth: truth, now: move) == .move)
        world.host.values[LoopHarness.level] = 50
        truth = try world.host.truth()
        _ = try world.planner.plan([a], truth: truth, reason: .scene, now: move + 1)
        world.host.values[LoopHarness.level] = 100.0 * 100 / 127
        truth = try world.host.truth()
        for late in [UInt64(0), 1] {
            var planner = world.planner
            let at = move + window + late
            let outcome = try #require(planner.plan([a], truth: truth, reason: .scene, now: at).first)
            if late == 0 {
                #expect(outcome.result == .suppressed(.echo))
                #expect(try planner.due(at: move + window).isEmpty)
                #expect(try planner.due(at: move + window + 1) == [a.id])
            } else {
                guard case .message(let message) = outcome.result else { Issue.record("not a message"); return }
                #expect(message.reason == .scene)
            }
        }
    }
}
// swiftlint:enable identifier_name
