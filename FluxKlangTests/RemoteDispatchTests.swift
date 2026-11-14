import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// RR2 (#96): the remote mirror and the bound local-MIDI proposals. Topic files are `extension RemoteDispatchTests`
/// (+Mirror, +Dispatch, +Refusals, +Limits, +Order, +Sources). Every fixture is a plain value built here: a host
/// synced at sequence 5 and 6, a catalog of seven parameters, and four bindings on two MIDI controllers.
@Suite(.productionAccessAudit)
struct RemoteDispatchTests {
    static let hostA = HostID(validated: "host.rr2a")
    static let hostB = HostID(validated: "host.rr2b")
    static let connection = ConnectionID(validated: "conn.rr2")

    static let levelA = ParameterID(validated: "par.rr2.level-a")
    static let levelB = ParameterID(validated: "par.rr2.level-b")
    static let levelC = ParameterID(validated: "par.rr2.level-c")
    static let levelD = ParameterID(validated: "par.rr2.level-d")
    static let noValue = ParameterID(validated: "par.rr2.no-value")
    static let percent = ParameterID(validated: "par.rr2.percent")
    static let locked = ParameterID(validated: "par.rr2.locked")
    static let missing = ParameterID(validated: "par.rr2.missing")

    static let aJump = BindingID(validated: "bnd.a-jump")
    static let bCatch = BindingID(validated: "bnd.b-catch")
    static let cFull = BindingID(validated: "bnd.c-full")
    static let dRel = BindingID(validated: "bnd.d-rel")

    static let pad70 = ControlSourceID(validated: "midi.rr2-pad.1.cc.70")
    static let pad71 = ControlSourceID(validated: "midi.rr2-pad.1.cc.71")
    static let idle = LocalEngineContext(lease: nil, lifecycle: .stopped)

    /// The values of the first snapshot: `levelD` is replaced and `noValue` removed by the delta that follows.
    static let snapshotValues: [ParameterID: ParameterValue] = [
        levelA: normalized(0.25), levelB: normalized(0.75), levelC: normalized(1), levelD: normalized(0.9),
        noValue: normalized(0.1)
    ]

    /// The host values after the delta: what the standard mirror must hold.
    static let hostValues: [ParameterID: ParameterValue] = [
        levelA: normalized(0.25), levelB: normalized(0.75), levelC: normalized(1), levelD: normalized(0.5),
        percent: ParameterValue(value: 50, unit: .percent), locked: normalized(0.5)
    ]

    /// Non-default states for every standard binding, so a refusal that resets, drops or rewrites one shows.
    static let movedPickup: [BindingID: PickupState] = [
        aJump: .waiting(hardware: 0.4), bCatch: .engaged(hardware: 0.9), cFull: .unavailable,
        dRel: .engaged(hardware: nil)
    ]

    /// The table the standard call returns: the jump and full-scale bindings engaged at the input, the catch binding
    /// waiting at it, and the relative binding (another source) untouched.
    static let standardResultPickup: [BindingID: PickupState] = [
        aJump: .engaged(hardware: 1), bCatch: .waiting(hardware: 1), cFull: .engaged(hardware: 1),
        dRel: .engaged(hardware: nil)
    ]

    static func normalized(_ value: Double) -> ParameterValue { ParameterValue(value: value, unit: .normalized) }

    static func session(
        host: HostID = hostA, hostGeneration: Int = 4, connectionGeneration: Int = 9
    ) throws -> PeerSyncSession {
        let hostEpoch = try HostEpoch(host: host, generation: Generation(hostGeneration))
        let connectionEpoch = try ConnectionEpoch(
            connection: connection, host: host, generation: Generation(connectionGeneration)
        )
        return try #require(PeerSyncSession(hostEpoch: hostEpoch, connectionEpoch: connectionEpoch))
    }

    /// Five distinct, non-initial revisions, so a basis that is defaulted or crosses two components shows.
    static func snapshotRevisions() throws -> CommandRevisions {
        try CommandRevisions(
            patch: ContractRevision(3), capability: ContractRevision(4), permission: ContractRevision(5),
            parameter: ContractRevision(7), graph: ContractRevision(6)
        )
    }

    static func deltaRevisions() throws -> CommandRevisions {
        var revisions = try snapshotRevisions()
        revisions.parameter = try ContractRevision(8)
        return revisions
    }

    /// A receiver synced at sequence 5 by `values`.
    static func snapshotReceiver(
        _ session: PeerSyncSession, values: [ParameterID: ParameterValue] = snapshotValues,
        limits: PeerSyncLimits = .standard
    ) throws -> PeerSyncReceiver {
        var receiver = PeerSyncReceiver(session: session, limits: limits)
        let snapshot = try PeerSyncSnapshot(
            session: session, sequence: PeerSequence(5), revisions: snapshotRevisions(), values: values
        )
        let event = receiver.receive(snapshot)
        try #require(event == .applied(snapshot.sequence))
        return receiver
    }

    /// The standard world: the snapshot at 5, then a delta at 6 that replaces, adds and removes values.
    static func syncedReceiver(_ session: PeerSyncSession) throws -> PeerSyncReceiver {
        var receiver = try snapshotReceiver(session)
        let delta = try PeerSyncDelta(
            session: session, sequence: PeerSequence(6), revisions: deltaRevisions(),
            updates: [
                levelD: normalized(0.5), percent: ParameterValue(value: 50, unit: .percent), locked: normalized(0.5)
            ],
            removals: [noValue]
        )
        let event = receiver.receive(delta)
        try #require(event == .applied(delta.sequence))
        return receiver
    }

    static func descriptor(
        _ id: ParameterID, unit: ParameterUnit = .normalized, upper: Double = 1, controlClass: ControlClass = .live
    ) throws -> ParameterDescriptor {
        try ParameterDescriptor(.init(
            id: id, unit: unit, lower: 0, upper: upper, defaultValue: 0, ceiling: nil, curve: .linear, ramp: .step,
            controlClass: controlClass, verification: .unverified
        ))
    }

    static func catalog() throws -> ParameterCatalog {
        try ParameterCatalog([
            descriptor(levelA), descriptor(levelB), descriptor(levelC), descriptor(levelD), descriptor(noValue),
            descriptor(percent, unit: .percent, upper: 100), descriptor(locked, controlClass: .hazardous)
        ])
    }

    static func mirror(host: HostID = hostA, hostGeneration: Int = 4) throws -> RemoteMirror {
        let receiver = try syncedReceiver(session(host: host, hostGeneration: hostGeneration))
        return try RemoteMirror.make(receiver: receiver, catalog: catalog())
    }

    /// Reaches `kind` only through legal events from `standalone`.
    static func role(
        _ kind: RemoteRoleKind, host: HostID = hostA, grant: PeerRole = .remoteController
    ) throws -> RemoteRole {
        var role = RemoteRole()
        guard kind != .standalone else { return role }
        try role.advance(.enterRemote(RemoteSession(host: host, grant: grant), releasing: nil), local: idle)
        if kind == .hostLost { try role.advance(.hostLost(host), local: idle) }
        return role
    }

    /// Five positions 0, 0.25, 0.5, 0.75 and 1, so every decoded position is exact in binary.
    static let quarters = EncoderProfile.absolute(resolution: 5)

    /// An absolute binding in the normalized unit.
    static func binding(
        _ id: BindingID, target: ParameterID, source: ControlSourceID = pad70, profile: EncoderProfile = quarters,
        pickup: PickupMode = .jump
    ) throws -> ControlBinding {
        try ControlBinding(.init(
            id: id, source: source, target: target, unit: .normalized, profile: profile, pickup: pickup
        ))
    }

    /// A relative binding: a two's complement 7-bit encoder moving a quarter per detent.
    static func relative(
        _ id: BindingID, target: ParameterID, source: ControlSourceID = pad71
    ) throws -> ControlBinding {
        try ControlBinding(.init(
            id: id, source: source, target: target, unit: .normalized, profile: .twosComplement(width: .seven),
            step: 0.25
        ))
    }

    /// Controller 70 drives a jump, a catch and a full-scale jump binding; controller 71 drives the relative one.
    static func standardBindings() throws -> [ControlBinding] {
        try [
            binding(aJump, target: levelA), binding(bCatch, target: levelB, pickup: .catch),
            binding(cFull, target: levelC), relative(dRel, target: levelD)
        ]
    }

    /// Every binding in its own initial state, as a caller that has never dispatched holds them.
    static func fresh(_ bindings: [ControlBinding]) -> [BindingID: PickupState] {
        Dictionary(uniqueKeysWithValues: bindings.map { ($0.id, $0.initialPickupState) })
    }

    /// Controller `number` at `value` on `channel` from the origin `origin`, as the performance state reports it.
    static func controller(
        _ number: UInt8, _ value: UInt8, channel: UInt8 = 1, origin: String = "rr2-pad",
        dialect: ControlIntakeDialect = .pairedFourteenBit
    ) throws -> RemoteMIDIInput {
        try RemoteMIDIInput(
            semantic: .controlChange(channel: channel, controller: number, value: value),
            update: MIDI1StateUpdate(channel: channel, effect: .controller(number, value: value)),
            origin: ControlSourceOrigin(origin), dialect: dialect
        )
    }

    /// The messages fed in order to a fresh performance state; the input is the last message and its update.
    static func message(
        _ messages: MIDI1Semantic..., origin: String = "rr2-pad",
        dialect: ControlIntakeDialect = .pairedFourteenBit
    ) throws -> RemoteMIDIInput {
        var state = MIDI1PerformanceState()
        var last: (MIDI1Semantic, MIDI1StateUpdate)?
        for semantic in messages { last = try (semantic, state.apply(semantic)) }
        let (semantic, update) = try #require(last)
        return try RemoteMIDIInput(
            semantic: semantic, update: update, origin: ControlSourceOrigin(origin), dialect: dialect
        )
    }

    /// One dispatch call as plain values; tests change a field and run it.
    struct Call {
        var role: RemoteRole
        var mirror: RemoteMirror?
        var input: RemoteMIDIInput
        var bindings: [ControlBinding]
        var pickup: [BindingID: PickupState]

        func run() -> RemoteDispatchResult {
            RemoteControlDispatch.propose(
                role: role, mirror: mirror, input: input, bindings: bindings, pickup: pickup
            )
        }
    }

    /// A call that proposes: a remote controller of host A, the standard mirror and bindings in their initial
    /// states, and controller 70 at its top position.
    static func call() throws -> Call {
        let bindings = try standardBindings()
        return try Call(
            role: role(.remoteController), mirror: mirror(), input: controller(70, 4), bindings: bindings,
            pickup: fresh(bindings)
        )
    }

    /// The standard call with every pickup state off its default, as a refusal test needs it.
    static func movedCall() throws -> Call {
        var moved = try call()
        moved.pickup = movedPickup
        return moved
    }

    /// What a proposal asks for, without its basis and session, which only the proposal-field test compares.
    struct Proposed: Equatable {
        let binding: BindingID
        let target: ParameterID
        let operation: CommandOperation
    }

    static func proposed(_ result: RemoteDispatchResult) -> [Proposed] {
        result.proposals.map { Proposed(binding: $0.binding, target: $0.target, operation: $0.operation) }
    }

    static func set(_ binding: BindingID, _ target: ParameterID, _ value: Double) -> Proposed {
        Proposed(binding: binding, target: target, operation: .set(target, normalized(value)))
    }

    /// Nothing proposed, held or refused, and the pickup table exactly `pickup`.
    static func expectIdle(
        _ result: RemoteDispatchResult, pickup: [BindingID: PickupState],
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(result.proposals.isEmpty, sourceLocation: sourceLocation)
        #expect(result.held.isEmpty, sourceLocation: sourceLocation)
        #expect(result.refusals.isEmpty, sourceLocation: sourceLocation)
        #expect(result.pickup == pickup, sourceLocation: sourceLocation)
    }

    /// A refused call: exactly this refusal, nothing proposed or held, and the pickup table exactly as it came in.
    static func expectRefused(
        _ call: Call, _ refusal: RemoteDispatchRefusal, sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let result = call.run()
        #expect(result.refusals == [refusal], sourceLocation: sourceLocation)
        #expect(result.proposals.isEmpty, sourceLocation: sourceLocation)
        #expect(result.held.isEmpty, sourceLocation: sourceLocation)
        #expect(result.pickup == call.pickup, sourceLocation: sourceLocation)
    }
}
