import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension ControlLoopConvergenceTests {
    private func numbered(_ count: Int) throws -> [ControlBinding] {
        try (0..<count).map { try LoopHarness.binding(String(format: "n%02d", $0)) }
    }

    @Test func theBindingTableAdmitsNControlsAndTheNPlusFirstGetsTableFullInEitherInputOrder() throws {
        let capacity = 4
        let policy = try LoopHarness.policy(bindings: capacity)
        let all = try numbered(capacity + 1)
        var finals: [ControlFeedbackPlanner] = []
        for order in [all, Array(all.reversed())] {
            var world = try LoopHarness.world(order, reaction: .quiet, policy: policy)
            try world.connect()
            let full = world.results(of: all[capacity])
            #expect(full == [.tableFull(capacity: capacity)])
            #expect(world.deliveries.map(\.message.binding.rawValue) == all.dropLast().map(\.id.rawValue))
            #expect(world.planner.trackedCount == capacity)
            finals.append(world.planner)
        }
        #expect(finals[0] == finals[1])
    }

    @Test func aTableFullRefusalLeavesTheCompletePlannerEqualToItsValueBeforeTheCall() throws {
        let policy = try LoopHarness.policy(bindings: 2)
        let all = try numbered(3)
        var planner = ControlFeedbackPlanner(policy: policy)
        let world = try LoopHarness.world(all, policy: policy)
        let truth = try world.host.truth()
        _ = try planner.plan(Array(all.prefix(2)), truth: truth, reason: .refresh, now: 0)
        let before = planner
        let outcomes = try planner.plan([all[2]], truth: truth, reason: .refresh, now: 0)
        #expect(outcomes.map(\.result) == [.tableFull(capacity: 2)])
        #expect(planner == before)
    }

    @Test func fourThousandNinetySixBindingsAreAcceptedAndOneMoreIsRefusedWithoutTouchingThePlanner() throws {
        let limit = ControlFeedbackPolicy.maximumCapacity
        let policy = try LoopHarness.policy(bindings: limit)
        let all = try (0...limit).map { try LoopHarness.binding(String(format: "m%04d", $0)) }
        let truth = try LoopHarness.world([all[0]]).host.truth()
        var planner = ControlFeedbackPlanner(policy: policy)
        #expect(try planner.plan(Array(all.prefix(limit)), truth: truth, reason: .refresh, now: 0).count == limit)
        var fresh = ControlFeedbackPlanner(policy: policy)
        let before = fresh
        #expect(throws: ControlFeedbackRefusal.tooManyBindings(limit + 1)) {
            try fresh.plan(all, truth: truth, reason: .refresh, now: 0)
        }
        #expect(fresh == before)
    }

    @Test func aDuplicateBindingIsRefusedNamingTheSmallestOneAndTheBatchChangesNothing() throws {
        let all = try numbered(3)
        let world = try LoopHarness.world(all)
        let truth = try world.host.truth()
        var planner = ControlFeedbackPlanner(policy: try LoopHarness.policy())
        let before = planner
        let batch = [all[2], all[1], all[2], all[1]]
        #expect(throws: ControlFeedbackRefusal.duplicateBinding(all[1].id)) {
            try planner.plan(batch, truth: truth, reason: .refresh, now: 0)
        }
        #expect(planner == before)
    }

    @Test func theSameScenarioWithBindingsInEitherOrderEndsInTheSameStateAndMessages() throws {
        let all = try numbered(3)
        var results: [LoopHarnessWorld] = []
        for order in [all, Array(all.reversed())] {
            var world = try LoopHarness.world(order)
            try world.connect()
            world.queue(all[1], try LoopHarness.raw(100))
            try world.run()
            results.append(world)
        }
        #expect(results[0].planner == results[1].planner)
        #expect(results[0].host == results[1].host)
        #expect(results[0].shown == results[1].shown)
        #expect(results[0].deliveries == results[1].deliveries)
    }

    @Test func theOutcomesOfAPlanComeBackInInputOrderWhileTheBindingsAreAnsweredInIdOrder() throws {
        let all = try numbered(3)
        let batch = [all[2], all[0], all[1]]
        var world = try LoopHarness.world(batch, reaction: .quiet)
        try world.connect()
        let outcomes = try world.planner.plan(batch, truth: world.host.truth(), reason: .scene, now: world.tick)
        #expect(outcomes.map(\.binding) == batch.map(\.id))
        #expect(world.deliveries.map(\.message.binding) == all.map(\.id))
    }

    @Test func aMIDIControllerChangeOfOneHundredIsShownBackAtGridStepOneHundred() throws {
        let sample = try MIDIControlIntake.resolve(
            MIDI1StateUpdate(channel: 1, effect: .controller(70, value: 100)), origin: ControlSourceOrigin("lcxl-1"),
            profile: LoopHarness.absolute
        )
        let source = try ControlSourceID(sample.source.rawValue)
        let binding = try ControlBinding(.init(
            id: BindingID("bnd.midi"), source: source, target: LoopHarness.level, unit: .percent,
            profile: LoopHarness.absolute, step: nil, lower: nil, upper: nil, pickup: .jump
        ))
        var world = try LoopHarness.world([binding])
        try world.connect()
        world.queue(binding, sample.input)
        let outcome = try world.run()
        #expect(outcome == .converged(steps: 1))
        #expect(world.planner.shownStep(of: binding.id) == 100)
        #expect(world.inbound(of: binding) == [.move])
    }
}
