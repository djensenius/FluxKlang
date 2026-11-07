import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

// Refusal order with both-defects fixtures, and two loop-free feedback scripts (12 messages in total).
extension TouchOSCInteropTests {
    // MARK: Intake order

    /// A message whose address is `address` and whose only argument has the unknown type tag `q`.
    private static func unknownTagPacket(_ address: String) -> [UInt8] {
        var bytes = Array(address.utf8) + [0]
        while bytes.count % 4 != 0 { bytes.append(0) }
        return bytes + [0x2C, 0x71, 0, 0]
    }

    private static func isMalformed(_ delivery: TouchOSCDelivery) -> Bool {
        if case .intake(.malformed) = delivery { return true }
        return false
    }

    @Test("A disabled endpoint refuses a malformed packet endpointDisabled; the enabled one calls it malformed")
    func disabledIsCheckedBeforeMalformed() throws {
        var disabled = OSC.IntakePipeline()
        let refused = disabled.receive(datagram: Fixture.garbage, from: Fixture.alpha, now: 0)
        #expect(refused == .failure(.endpointDisabled))
        var enabled = try Fixture.pipeline()
        #expect(Self.isMalformed(try Fixture.datagram(&enabled, Fixture.garbage)))
    }

    @Test("An exhausted packet budget refuses a malformed packet packetBudgetExceeded and changes nothing")
    func packetBudgetIsCheckedBeforeMalformed() throws {
        var pipeline = try Fixture.pipeline(packets: 1)
        #expect(try Fixture.datagram(&pipeline, try Fixture.encode("/fk/v1/transport/start")) == .mapped([.start]))
        let before = pipeline
        let refused = try Fixture.datagram(&pipeline, Fixture.garbage)
        #expect(refused == .intake(.packetBudgetExceeded(limit: 1, retryAfterTicks: 10)))
        #expect(pipeline == before)
        var later = pipeline
        #expect(Self.isMalformed(try Fixture.datagram(&later, Fixture.garbage, now: 10)))
    }

    @Test("A packet with an unknown type tag and an unlisted address is malformed, not notAdmitted")
    func malformedIsCheckedBeforeTheAllowList() throws {
        var pipeline = try Fixture.pipeline()
        let both = Self.unknownTagPacket("/fk/v1/hazard/other")
        #expect(Self.isMalformed(try Fixture.datagram(&pipeline, both)))
        let addressOnly = try Fixture.encode("/fk/v1/hazard/other", [.int32(1)])
        let delivery = try Fixture.datagram(&pipeline, addressOnly, now: 1)
        #expect(delivery == .intake(.notAdmitted(.disallowedAddress("/fk/v1/hazard/other"))))
    }

    @Test("The two-defect packet is a malformed strike that quarantines the peer; an unlisted address is not")
    func aMalformedStrikeIsChargedAndAnUnlistedAddressIsNot() throws {
        let both = Self.unknownTagPacket("/fk/v1/hazard/other")
        var struck = try Fixture.pipeline()
        for tick in UInt64(0)...2 {
            #expect(Self.isMalformed(try Fixture.datagram(&struck, both, now: tick)))
        }
        #expect(try Fixture.datagram(&struck, both, now: 3) == .intake(.peerQuarantined(retryAfterTicks: 19)))
        let unlisted = try Fixture.encode("/fk/v1/hazard/other", [.int32(1)])
        var uncharged = try Fixture.pipeline()
        for tick in UInt64(0)...3 {
            let delivery = try Fixture.datagram(&uncharged, unlisted, now: tick)
            #expect(delivery == .intake(.notAdmitted(.disallowedAddress("/fk/v1/hazard/other"))))
        }
    }

    @Test("An allow-listed hazard address passes intake and the mapper refuses the hazard family by name")
    func theAllowListIsCheckedBeforeTheNamespaceMapper() throws {
        var pipeline = try Fixture.pipeline()
        let listed = try Fixture.datagram(&pipeline, try Fixture.encode("/fk/v1/hazard/panic"))
        #expect(listed == .namespace(.message(index: 0, refusal: .refusedFamily(.hazard))))
        let unlisted = try Fixture.datagram(&pipeline, try Fixture.encode("/fk/v1/hazard/other"), now: 1)
        #expect(unlisted == .intake(.notAdmitted(.disallowedAddress("/fk/v1/hazard/other"))))
    }

    // MARK: Mapper order

    @Test("An over-long address that also holds a wildcard is addressTooLong, not wildcardAddress")
    func addressLengthIsCheckedBeforeTheWildcard() throws {
        let both = "/fk/v1/param/*" + String(repeating: "a", count: 243)
        #expect(both.utf8.count == 257)
        #expect(try Fixture.refusal(both) == .addressTooLong(byteCount: 257, limit: 256))
        #expect(try Fixture.refusal("/fk/v1/param/*") == .wildcardAddress)
    }

    @Test("A wildcard address with seven segments is wildcardAddress, not tooManySegments")
    func theWildcardIsCheckedBeforeTheSegmentCount() throws {
        #expect(try Fixture.refusal("/fk/v1/param/*/a/b/c") == .wildcardAddress)
        #expect(try Fixture.refusal("/fk/v1/param/x/a/b/c") == .tooManySegments(count: 7, limit: 6))
    }

    @Test("Seven segments with one 33-byte segment are tooManySegments, not segmentTooLong")
    func theSegmentCountIsCheckedBeforeTheSegmentLength() throws {
        let both = Fixture.longSegment(33) + "/x/y/z"
        #expect(try Fixture.refusal(both) == .tooManySegments(count: 7, limit: 6))
        #expect(try Fixture.refusal(Fixture.longSegment(33)) == .segmentTooLong(index: 3, byteCount: 33, limit: 32))
    }

    @Test("A 33-byte segment outside the namespace is segmentTooLong, not outsideNamespace")
    func theSegmentLengthIsCheckedBeforeTheNamespace() throws {
        let both = "/other/v1/param/" + String(repeating: "a", count: 33)
        #expect(try Fixture.refusal(both) == .segmentTooLong(index: 3, byteCount: 33, limit: 32))
        #expect(try Fixture.refusal("/other/v1/param/a") == .outsideNamespace(segmentCount: 4))
    }

    @Test("An upper-case segment outside the namespace is outsideNamespace, not invalidSegment")
    func theNamespaceIsCheckedBeforeSegmentBytes() throws {
        #expect(try Fixture.refusal("/other/v1/Param") == .outsideNamespace(segmentCount: 3))
        #expect(try Fixture.refusal("/fk/v1/Param") == .invalidSegment(index: 2, byteOffset: 0))
    }

    @Test("A bad segment byte after a hazard family is invalidSegment, not refusedFamily")
    func segmentBytesAreCheckedBeforeTheRefusedFamily() throws {
        #expect(try Fixture.refusal("/fk/v1/hazard/B") == .invalidSegment(index: 3, byteOffset: 0))
        #expect(try Fixture.refusal("/fk/v1/hazard/b") == .refusedFamily(.hazard))
    }

    @Test("A refused family with an unsupported argument is refusedFamily, not an argument refusal")
    func theRefusedFamilyIsCheckedBeforeArguments() throws {
        #expect(try Fixture.refusal("/fk/v1/route/x", [.string("s"), .int32(1)]) == .refusedFamily(.route))
        let unsupported = try Fixture.refusal("/fk/v1/param/fader", [.string("s")])
        #expect(unsupported == .unsupportedArgument(index: 0, typeTag: 0x73))
    }

    @Test("An unknown route with the wrong arguments is unknownRoute, not an argument refusal")
    func theRouteIsCheckedBeforeArguments() throws {
        #expect(try Fixture.refusal("/fk/v1/param/nope", [.string("s")]) == .unknownRoute(segmentCount: 4))
        #expect(try Fixture.refusal("/fk/v1/param/fader") == .wrongArgumentCount(minimum: 1, maximum: 1, got: 0))
    }

    @Test("Two arguments of which one has the wrong type are a count refusal, not a type refusal")
    func theArgumentCountIsCheckedBeforeTheirTypes() throws {
        let refusal = try Fixture.refusal("/fk/v1/param/fader", [.string("s"), .int32(1)])
        #expect(refusal == .wrongArgumentCount(minimum: 1, maximum: 1, got: 2))
    }

    @Test("A ramp with a NaN value and a text duration is an unsupported argument, not nonFiniteValue")
    func rampTypesAreCheckedBeforeFiniteness() throws {
        let nan = Float.nan
        #expect(try Fixture.refusal("/fk/v1/param/fader/ramp", [.float32(nan), .string("s")])
            == .unsupportedArgument(index: 1, typeTag: 0x73))
        #expect(try Fixture.refusal("/fk/v1/param/fader/ramp", [.float32(nan), .int32(1)]) == .nonFiniteValue(index: 0))
    }

    @Test("A ramp with a NaN value and a 60,001 ms duration is nonFiniteValue, not out of range")
    func rampFinitenessIsCheckedBeforeTheRange() throws {
        let args: [OSC.Argument] = [.float32(.nan), .int32(60_001)]
        #expect(try Fixture.refusal("/fk/v1/param/fader/ramp", args) == .nonFiniteValue(index: 0))
        #expect(try Fixture.refusal("/fk/v1/param/fader/ramp", [.float32(0), .int32(60_001)])
            == .rampMillisecondsOutOfRange(60_001))
    }

    // MARK: Scripts

    /// The parameter, ceiling-capped at 50, that both scripts drive from a client.
    private static let level = ParameterID(validated: "par.level")

    private static func levelCatalog() throws -> ParameterCatalog {
        try ParameterCatalog([ParameterDescriptor(.init(
            id: level, unit: .percent, lower: 0, upper: 100, defaultValue: 0, ceiling: 50, curve: .linear,
            ramp: .step, controlClass: .live, verification: .unverified
        ))])
    }

    private static func levelBinding() throws -> ControlBinding {
        try ControlBinding(.init(
            id: BindingID("bnd.a"), source: ControlSourceID("ctl.a"), target: level, unit: .percent,
            profile: .absolute(resolution: 128), step: nil, lower: nil, upper: nil, pickup: .jump
        ))
    }

    private static func planner(budget: Int) throws -> ControlFeedbackPlanner {
        ControlFeedbackPlanner(policy: try ControlFeedbackPolicy(
            bindingCapacity: 16, holdCapacity: 4, windowTicks: 10, holdTimeoutTicks: 100, emitBudget: budget
        ))
    }

    private static func levelTruth(_ value: Double) throws -> ControlHostTruth {
        try ControlHostTruth(
            catalog: levelCatalog(), values: [level: ParameterValue(value: value, unit: .percent)]
        )
    }

    private static func plan(
        _ planner: inout ControlFeedbackPlanner, _ binding: ControlBinding, host: Double,
        _ reason: ControlFeedbackReason, now: UInt64
    ) throws -> ControlFeedbackResult {
        let outcomes = try planner.plan([binding], truth: levelTruth(host), reason: reason, now: now)
        return try #require(outcomes.first).result
    }

    @Test("Script: an OSC request of 90 reaches the host as a set, is above the ceiling, and sits at the top position")
    func anOscRequestAboveTheCeilingIsASetAndConvertsToThePositionOfTheCeiling() throws {
        let route = try OSC.RouteTable(
            parameters: [OSC.ParameterRoute(name: "level", id: Self.level)], actions: [], transport: [],
            catalog: Self.levelCatalog()
        )
        let mapper = OSC.ControlMapper(table: route)
        let operation = try mapper.map(try Fixture.message("/fk/v1/param/level", [.float32(90)]))
        guard case .set(_, let requested) = operation else {
            throw TouchOSCInteropFixture.FixtureError.badExample("")
        }
        #expect(requested == ParameterValue(value: 90, unit: .percent))
        let descriptor = try #require(Self.levelCatalog()[Self.level])
        #expect(throws: ParameterValueError.aboveCeiling(90, ceiling: 50)) { try descriptor.check(requested) }
        let range = try Self.levelBinding().validate(against: descriptor)
        #expect(range == 0...50)
        let position = try ControlBinding.position(of: requested.value, over: range, curve: descriptor.curve)
        #expect(position == 1)
        #expect(try ControlBinding.value(at: position, over: range, curve: descriptor.curve) == 50)
    }

    @Test("Script: a control shown at 45 while the host holds 50 gets position 1; its echo is ignored, refresh quiet")
    func plannerCorrectionToTheCeilingIsDerivedEchoedAndRefreshIsQuiet() throws {
        let descriptor = try #require(Self.levelCatalog()[Self.level])
        let binding = try Self.levelBinding()
        let range = try binding.validate(against: descriptor)
        let shown = 0.9
        #expect(try ControlBinding.value(at: shown, over: range, curve: descriptor.curve) == 45)
        var planner = try Self.planner(budget: 3)
        let truth = try Self.levelTruth(50)
        #expect(try planner.receive(.absolute(normalized: shown), for: binding, truth: truth, now: 0) == .move)
        let clamp = try Self.plan(&planner, binding, host: 50, .clamp, now: 1)
        let corrected = try ControlBinding.position(of: 50, over: range, curve: descriptor.curve)
        let expected = try ControlFeedbackMessage(
            binding: binding.id, source: binding.source, position: corrected, reason: .clamp
        )
        #expect(clamp == .message(expected))
        #expect(expected.position == 1)
        let echoed = try ControlBinding.value(at: expected.position, over: range, curve: descriptor.curve)
        #expect(echoed == 50)
        let echo = try planner.receive(.absolute(normalized: expected.position), for: binding, truth: truth, now: 2)
        #expect(echo == .echo)
        #expect(try Self.plan(&planner, binding, host: 50, .refresh, now: 3) == .suppressed(.unchanged))
        planner.forget(binding.id)
        let resent = try Self.plan(&planner, binding, host: 50, .refresh, now: 4)
        #expect(resent == .message(try ControlFeedbackMessage(
            binding: binding.id, source: binding.source, position: expected.position, reason: .refresh
        )))
        #expect(try Self.plan(&planner, binding, host: 50, .refresh, now: 5) == .suppressed(.unchanged))
    }

    @Test("Script: per binding, eight corrections in one window are sent, the ninth is coalesced, due(at:) is polled")
    func refreshBudgetScriptCoalescesTheNinthCorrection() throws {
        // The budget is per binding (this script has one). `due(at:)` only lists bindings ready at the tick it is
        // given: 10 (empty) and 11 (ready) are the values of this fixture's policy, not a rule a host may assume.
        let binding = try Self.levelBinding()
        var planner = try Self.planner(budget: 8)
        var sent = 0
        for tick in UInt64(0)..<8 {
            let result = try Self.plan(&planner, binding, host: Double(tick) * 5, .scene, now: tick)
            if case .message = result { sent += 1 }
        }
        #expect(sent == 8)
        let ninth = try Self.plan(&planner, binding, host: 45, .scene, now: 8)
        #expect(ninth == .suppressed(.coalesced))
        let retry: UInt64 = 11
        #expect(try planner.due(at: 10).isEmpty)
        #expect(try planner.due(at: retry) == [binding.id])
        let late = try Self.plan(&planner, binding, host: 45, .scene, now: retry)
        #expect(late == .message(try ControlFeedbackMessage(
            binding: binding.id, source: binding.source, position: 0.9, reason: .scene
        )))
    }
}
