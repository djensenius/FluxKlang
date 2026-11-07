import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// The OSC side of the fake loop: an intake pipeline that starts disabled, a route table for `par.level`, and the
/// datagram BYTES a remote would send. No socket exists: the bytes are handed to the pipeline as values.
struct LoopHarnessOSC {
    typealias OSC = OpenSoundControl

    static let address = "/fk/v1/param/level"
    let peer = OSC.PeerKey(rawValue: 1)
    let mapper: OSC.ControlMapper
    var pipeline = OSC.IntakePipeline()
    var outbox: [[UInt8]] = []
    /// A remote that answers every feedback message with a datagram carrying the position it was shown.
    var reflects = false
    var admittedSteps: [Int] = []
    var refusals: [OSC.IntakeRefusal] = []
    var mapperRefusals: [OSC.NamespaceRefusal] = []

    init(catalog: ParameterCatalog) throws {
        let table = try OSC.RouteTable(
            parameters: [OSC.ParameterRoute(name: "level", id: LoopHarness.level)], actions: [], transport: [],
            catalog: catalog
        )
        mapper = OSC.ControlMapper(table: table)
    }

    /// Turns the endpoint on with `packets` datagrams per 10-tick window and an allow-list of `addresses`.
    mutating func enable(packets: Int = 8, addresses: [String] = [LoopHarnessOSC.address]) throws {
        let list = try OSC.AllowList(addresses.map { try OSC.AddressPattern($0) })
        let budget = try OSC.IntakeBudget(windowTicks: 10, maximumPackets: packets, maximumBytes: 1_024,
                                          maximumMalformed: 2, cooldownTicks: 20)
        try pipeline.enable(OSC.EndpointPolicy(transport: .datagram, allowList: list, budget: budget,
                                               maximumPeers: 4, idleTicks: 10, maximumPacketBytes: 1_024,
                                               maximumBundleDepth: 8))
    }

    /// The bytes of one `/fk/v1/...` write of `percent` to `address`.
    static func datagram(percent: Double, to address: String = LoopHarnessOSC.address) throws -> [UInt8] {
        let message = OSC.Message(address: try OSC.AddressPattern(address), arguments: [.float32(Float(percent))])
        return try OSC.Encoder().encode(message)
    }

    /// A reflecting remote queues its answer; it is read at a LATER step, never in the step of the message.
    mutating func remoteSaw(_ message: ControlFeedbackMessage) throws {
        guard reflects else { return }
        outbox.append(try Self.datagram(percent: message.position * 100))
    }
}

extension LoopHarnessWorld {
    /// Offers one datagram to the pipeline at the current tick; an admitted write becomes a host write.
    mutating func ingestOSC(_ bytes: [UInt8]) throws {
        switch osc.pipeline.receive(datagram: bytes, from: osc.peer, now: tick) {
        case .failure(let refusal):
            osc.refusals.append(refusal)
        case .success(let batches):
            for message in batches.flatMap({ $0 }) {
                do throws(OpenSoundControl.NamespaceRefusal) {
                    guard case .set(let id, let value) = try osc.mapper.map(message) else { continue }
                    host.values[id] = value.value
                    owed = .scene
                    osc.admittedSteps.append(step)
                } catch {
                    osc.mapperRefusals.append(error)
                }
            }
        }
    }
}

extension ControlLoopConvergenceTests {
    private func oscWorld(packets: Int = 8, enabled: Bool = true) throws -> LoopHarnessWorld {
        var world = try LoopHarness.world([LoopHarness.binding("a"), LoopHarness.binding("b")], reaction: .quiet)
        try world.connect()
        if enabled { try world.osc.enable(packets: packets) }
        return world
    }

    @Test func aDefaultOSCEndpointRefusesEveryDatagramAndTheLoopNeverSeesIt() throws {
        var world = try oscWorld(enabled: false)
        world.osc.outbox = [try LoopHarnessOSC.datagram(percent: 70)]
        let before = world
        try world.stepOnce()
        #expect(world.osc.refusals == [.endpointDisabled])
        #expect(world.osc.admittedSteps.isEmpty)
        #expect(world.osc.pipeline == OpenSoundControl.IntakePipeline())
        #expect(world.planner == before.planner)
        #expect(world.host == before.host)
        #expect(world.trace == before.trace)
        #expect(try world.isQuiescent())
    }

    @Test func anEnabledOSCEndpointTurnsAParameterWriteIntoOneSceneMessagePerControl() throws {
        var world = try oscWorld()
        let start = world.step
        world.osc.outbox = [try LoopHarnessOSC.datagram(percent: 70)]
        #expect(try world.run() == .converged(steps: 1))
        let deliveries = world.deliveries.filter { $0.step > start }
        #expect(deliveries.map(\.message.reason) == [.scene, .scene])
        #expect(deliveries.map(\.message.binding.rawValue) == ["bnd.a", "bnd.b"])
        #expect(world.planner.shownStep(of: try BindingID("bnd.a")) == 89)
        #expect(world.planner.shownStep(of: try BindingID("bnd.b")) == 89)
        #expect(world.osc.admittedSteps == [start + 1])
    }

    @Test func aFeedbackMessageNeverReentersAsAnOSCInputInTheStepThatSentIt() throws {
        var world = try oscWorld()
        world.osc.reflects = true
        let start = world.step
        world.osc.outbox = [try LoopHarnessOSC.datagram(percent: 70)]
        #expect(try world.run() == .converged(steps: 3))
        #expect(world.deliveries.filter { $0.step > start }.map(\.step) == [start + 1, start + 1])
        #expect(world.osc.admittedSteps == [start + 1, start + 2, start + 3])
        let results = world.results(of: try LoopHarness.binding("a"))
        #expect(results.suffix(2) == [.suppressed(.unchanged), .suppressed(.unchanged)])
    }

    @Test func theOSCPacketBudgetAdmitsNDatagramsRefusesTheNextAndRecoversAfterTheWindow() throws {
        var world = try oscWorld(packets: 2)
        let limit = try #require(world.osc.pipeline.endpoint.policy?.budget.maximumPackets)
        world.osc.outbox = try (1...(limit + 1)).map { try LoopHarnessOSC.datagram(percent: Double($0) * 10) }
        for _ in 0..<limit { try world.stepOnce() }
        let admitted = world.osc.pipeline
        try world.stepOnce()
        #expect(world.osc.refusals == [.packetBudgetExceeded(limit: limit, retryAfterTicks: 8)])
        #expect(world.osc.pipeline == admitted)
        #expect(world.host.values[LoopHarness.level] == 20)
        world.tick += 6
        world.osc.outbox = [try LoopHarnessOSC.datagram(percent: 30)]
        try world.stepOnce()
        #expect(world.osc.refusals.count == 2)
        #expect(world.osc.refusals.last == .packetBudgetExceeded(limit: limit, retryAfterTicks: 1))
        world.osc.outbox = [try LoopHarnessOSC.datagram(percent: 30)]
        try world.run()
        #expect(world.host.values[LoopHarness.level] == 30)
        #expect(world.osc.admittedSteps.count == limit + 1)
    }

    @Test func anAddressOutsideTheRouteTableIsRefusedByTheMapperAndChangesNothing() throws {
        var world = try oscWorld()
        world.osc.pipeline.disable()
        try world.osc.enable(addresses: [LoopHarnessOSC.address, "/fk/v1/param/missing"])
        world.osc.outbox = [try LoopHarnessOSC.datagram(percent: 70, to: "/fk/v1/param/missing")]
        let before = world
        try world.stepOnce()
        #expect(world.osc.mapperRefusals == [.unknownRoute(segmentCount: 4)])
        #expect(world.host == before.host)
        #expect(world.planner == before.planner)
        #expect(try world.isQuiescent())
    }

    @Test func enablingAnEnabledOSCEndpointAgainIsRefusedAndLeavesThePipelineAsItWas() throws {
        var world = try oscWorld()
        let before = world.osc.pipeline
        #expect(throws: OpenSoundControl.EndpointRefusal.alreadyEnabled) { try world.osc.enable(packets: 3) }
        #expect(world.osc.pipeline == before)
    }

    @Test func disablingTheOSCEndpointRestoresTheDefaultRefusal() throws {
        var world = try oscWorld()
        world.osc.pipeline.disable()
        world.osc.outbox = [try LoopHarnessOSC.datagram(percent: 70)]
        try world.run()
        #expect(world.osc.refusals == [.endpointDisabled])
        #expect(world.osc.pipeline == OpenSoundControl.IntakePipeline())
        #expect(world.host.values[LoopHarness.level] == 0)
    }
}
