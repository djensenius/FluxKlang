// swiftlint:disable identifier_name
import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension ControlLoopConvergenceTests {
    @Test func aHostCeilingBelowTheRequestSendsEachControlOneClampMessageAndTheReflectedEchoSendsNothingMore() throws {
        let a = try LoopHarness.binding("a", source: "x")
        let b = try LoopHarness.binding("b", source: "y")
        var world = try LoopHarness.world([a, b], writeLimit: 60.5)
        try world.connect()
        world.queue(a, try LoopHarness.raw(127))
        let outcome = try world.run()
        #expect(outcome == .converged(steps: 3))
        #expect(world.host.values[LoopHarness.level] == 60.5)
        let clamps = world.deliveries.filter { $0.message.reason == .clamp }
        #expect(clamps.map(\.message.binding.rawValue) == ["bnd.a", "bnd.b"])
        #expect(clamps.map(\.message.position) == [0.605, 0.605])
        #expect(world.deliveries.count == 4)
        #expect(world.results(of: a).count == 2)
        #expect(world.results(of: b).count == 2)
        #expect(world.inbound(of: a) == [.move, .echo])
        #expect(world.inbound(of: b) == [.echo])
        let hostStep = LoopHarness.step(of: 60.5 / 100)
        #expect(hostStep == 77)
        #expect(world.planner.shownStep(of: a.id) == hostStep)
        #expect(world.planner.shownStep(of: b.id) == hostStep)
    }

    @Test func aRelativeEncoderAtTheHostCeilingClampsOnceThenWritesNothingAndTurnsBackDown() throws {
        let a = try LoopHarness.binding("a", profile: LoopHarness.relative)
        var world = try LoopHarness.world([a], reaction: .quiet, writeLimit: 60, start: 58)
        try world.connect()
        let up = ControlInput.relative(delta: 5)
        world.queue(a, up)
        try world.run()
        #expect(world.host.values[LoopHarness.level] == 60)
        let afterClamp = world.deliveries.last
        #expect(afterClamp?.message.reason == .clamp)
        #expect(afterClamp?.message.position == 0.6)
        #expect(world.planner.shownStep(of: a.id) == 76)
        world.queue(a, ControlInput.relative(delta: 3))
        let before = world.planner
        try world.run()
        #expect(world.host.values[LoopHarness.level] == 60)
        #expect(world.deliveries.last == afterClamp)
        #expect(world.planner.shownStep(of: a.id) == before.shownStep(of: a.id))
        world.queue(a, ControlInput.relative(delta: -2))
        try world.run()
        #expect(world.host.values[LoopHarness.level] == 58)
    }
}
// swiftlint:enable identifier_name
