import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// Refusal order. Each test holds BOTH defects of the pair it claims (and shows that each defect alone is
/// refused), so a swapped pair changes the answer.
/// Claimed in `propose`: role before grant, grant before raw input, raw input before mirror, mirror before
/// source, source before cap, cap before duplicates. Per binding: pickup entry before profile, profile before
/// the binding's own resolution. In `RemoteMirror.make`: value count before unknown parameter.
/// Not claimed: duplicates before evaluation (a refused call evaluates nothing observable) and the order inside
/// `ControlBinding.resolve`, which belongs to that dependency.
extension RemoteDispatchTests {
    private static let skewID = BindingID(validated: "bnd.zz-skew")
    private static let lateID = BindingID(validated: "bnd.zz-late")

    private static func noChannelUpdate() -> MIDI1StateUpdate {
        MIDI1StateUpdate(channel: nil, effect: .controller(70, value: 4))
    }

    private static func controlChange() -> MIDI1Semantic {
        .controlChange(channel: 1, controller: 70, value: 4)
    }

    private static func noteOn() -> MIDI1Semantic {
        .noteOn(channel: 1, note: 60, velocity: 100)
    }

    private static func input(_ semantic: MIDI1Semantic, _ update: MIDI1StateUpdate) throws -> RemoteMIDIInput {
        try RemoteMIDIInput(semantic: semantic, update: update, origin: ControlSourceOrigin("rr2-pad"))
    }

    /// 257 bindings: `bnd.000` ... `bnd.255` and a second `bnd.000`. Over the cap, with one repeated id.
    private static func overfullBindings() throws -> [ControlBinding] {
        var bindings = try manyBindings(256)
        try bindings.append(binding(BindingID("bnd.000"), target: levelB))
        return bindings
    }

    @Test func aLostHostIsReportedBeforeAnObserverGrant() throws {
        var call = try Self.movedCall()
        call.role = try Self.role(.hostLost, grant: .observer)
        #expect(RemoteRoleGuard.decide(role: call.role, capability: .peerUICommand) != .allowed)
        Self.expectRefused(call, .notRemoteController(.hostLost))
        call.role = try Self.role(.remoteController, grant: .observer)
        Self.expectRefused(call, .observerHasNoCommands)
    }

    @Test func anObserverGrantIsReportedBeforeARawNote() throws {
        var call = try Self.movedCall()
        call.role = try Self.role(.remoteController, grant: .observer)
        call.input = try Self.input(Self.noteOn(), call.input.update)
        Self.expectRefused(call, .observerHasNoCommands)
        call.role = try Self.role(.remoteController)
        Self.expectRefused(call, .rawInput(.refusedRawNote))
    }

    @Test func aRawNoteIsReportedBeforeAMissingOrForeignMirror() throws {
        var call = try Self.movedCall()
        call.input = try Self.input(Self.noteOn(), call.input.update)
        call.mirror = nil
        Self.expectRefused(call, .rawInput(.refusedRawNote))
        call.mirror = try Self.mirror(host: Self.hostB)
        Self.expectRefused(call, .rawInput(.refusedRawNote))
        call.input = try Self.controller(70, 4)
        Self.expectRefused(call, .staleSession)
    }

    @Test func aMissingOrForeignMirrorIsReportedBeforeAnUpdateWithoutASource() throws {
        var call = try Self.movedCall()
        call.input = try Self.input(Self.controlChange(), Self.noChannelUpdate())
        call.mirror = nil
        Self.expectRefused(call, .mirrorUnavailable)
        call.mirror = try Self.mirror(host: Self.hostB)
        Self.expectRefused(call, .staleSession)
        call.mirror = try Self.mirror()
        Self.expectRefused(call, .intake(.noChannel))
    }

    @Test func anUpdateWithoutASourceIsReportedBeforeTheBindingCap() throws {
        var call = try Self.movedCall()
        call.input = try Self.input(Self.controlChange(), Self.noChannelUpdate())
        call.bindings = try Self.overfullBindings()
        Self.expectRefused(call, .intake(.noChannel))
        call.input = try Self.controller(70, 4)
        Self.expectRefused(call, .tooManyBindings(257))
    }

    @Test func theBindingCapIsReportedBeforeARepeatedBindingId() throws {
        var call = try Self.movedCall()
        call.bindings = try Self.overfullBindings()
        #expect(call.bindings.count == 257)
        #expect(Set(call.bindings.map(\.id)).count == 256)
        Self.expectRefused(call, .tooManyBindings(257))
        call.bindings.remove(at: 100)
        Self.expectRefused(call, .duplicateBinding(try BindingID("bnd.000")))
    }

    @Test func aMissingPickupEntryIsReportedBeforeAProfileThatDoesNotFit() throws {
        var call = try Self.call()
        call.bindings.append(try Self.binding(Self.skewID, target: Self.levelA, profile: .absolute(resolution: 1024)))
        let result = call.run()
        #expect(result.refusals == [.pickupStateMissing(Self.skewID)])
        #expect(result.pickup[Self.skewID] == nil)
        call.pickup[Self.skewID] = .waiting(hardware: 0.4)
        let fitted = call.run()
        #expect(fitted.refusals == [.bindingIntake(Self.skewID, .widthMismatch(messageBits: 7, profileBits: 14))])
    }

    @Test func aProfileThatDoesNotFitIsReportedBeforeAMissingTarget() throws {
        var call = try Self.call()
        call.bindings.append(try Self.binding(
            Self.lateID, target: Self.missing, profile: .absolute(resolution: 1024)
        ))
        call.pickup[Self.lateID] = .waiting(hardware: 0.4)
        let result = call.run()
        #expect(result.refusals == [.bindingIntake(Self.lateID, .widthMismatch(messageBits: 7, profileBits: 14))])
        #expect(result.pickup[Self.lateID] == .waiting(hardware: 0.4))
        call.bindings[call.bindings.count - 1] = try Self.binding(Self.lateID, target: Self.missing)
        #expect(call.run().refusals == [.binding(Self.lateID, .targetMissing(Self.missing))])
    }

    @Test func theValueCountIsReportedBeforeAnUnknownParameter() throws {
        let first = try ParameterID("par.rr2.aa-unknown")
        var values = try Self.bulkValues(4096)
        values[first] = Self.normalized(0.1)
        values[Self.missing] = Self.normalized(0.2)
        let limits = try #require(PeerSyncLimits(maximumSnapshotValues: 4098, maximumDeltaChanges: 1))
        let receiver = try Self.snapshotReceiver(Self.session(), values: values, limits: limits)
        #expect(receiver.state?.values.count == 4098)
        let refusal = Self.refusal(making: receiver, catalog: try Self.bulkCatalog(4096))
        #expect(refusal == .tooManyValues(4098))
    }

    @Test func removingTheDefectsOneAtATimeMakesEachCheckFireInTurn() throws {
        var call = try Self.movedCall()
        call.role = try Self.role(.hostLost, grant: .observer)
        call.input = try Self.input(Self.noteOn(), Self.noChannelUpdate())
        call.mirror = nil
        call.bindings = try Self.overfullBindings()
        Self.expectRefused(call, .notRemoteController(.hostLost))
        call.role = try Self.role(.remoteController, grant: .observer)
        Self.expectRefused(call, .observerHasNoCommands)
        call.role = try Self.role(.remoteController)
        Self.expectRefused(call, .rawInput(.refusedRawNote))
        call.input = try Self.input(Self.controlChange(), Self.noChannelUpdate())
        Self.expectRefused(call, .mirrorUnavailable)
        call.mirror = try Self.mirror()
        Self.expectRefused(call, .intake(.noChannel))
        call.input = try Self.controller(70, 4)
        Self.expectRefused(call, .tooManyBindings(257))
        call.bindings.remove(at: 100)
        Self.expectRefused(call, .duplicateBinding(try BindingID("bnd.000")))
        call.bindings.removeLast()
        call.pickup = Self.movedTable(call.bindings)
        let evaluated = call.run()
        #expect(evaluated.refusals.isEmpty)
        #expect(evaluated.proposals.count == 255)
    }
}
