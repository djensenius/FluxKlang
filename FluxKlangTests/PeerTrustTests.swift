import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// Shared fixtures for the peer trust suites (#94).
enum PeerTrustTestSupport {
    static let hostID = HostID(validated: "host.a")
    static let hostEpoch = HostEpoch(host: hostID, generation: generation(7))
    static let connection = ConnectionID(validated: "con.remote-c")
    static let fxGain = ParameterID(validated: "par.fx.gain")
    static let outGain = ParameterID(validated: "par.out.gain")

    static func generation(_ value: Int) -> Generation {
        do { return try Generation(value) } catch { preconditionFailure("invalid generation \(value)") }
    }

    static func identity(_ seed: UInt8) -> PeerIdentityFingerprint {
        guard let identity = PeerIdentityFingerprint((0..<32).map { seed &+ UInt8($0) }) else {
            preconditionFailure("invalid identity")
        }
        return identity
    }

    static func nonce(_ seed: UInt8) -> PeerNonce {
        guard let nonce = PeerNonce((0..<32).map { seed &* 3 &+ UInt8($0) }) else { preconditionFailure("bad nonce") }
        return nonce
    }

    static func capabilities(_ names: [String]) -> PeerCapabilitySet {
        guard let set = PeerCapabilitySet(names.compactMap(PeerCapability.init)) else { preconditionFailure("bad set") }
        return set
    }

    static func session(version: UInt16 = 1, capabilities names: [String] = ["control", "status"],
                        host: Int = 7, connection: Int = 4) -> PeerNegotiatedSession {
        PeerNegotiatedSession(protocolVersion: version, hostEpoch: generation(host),
                              connectionEpoch: generation(connection), capabilities: capabilities(names))
    }

    static func live(_ parameter: ParameterID) -> PeerCommandGrant {
        PeerCommandGrant(controlClass: .live, scope: .parameter(parameter))
    }

    static func remote(_ parameters: [ParameterID] = [fxGain],
                       reads: Set<PeerReadGrant> = [.statusRead]) throws -> PeerGrantSet {
        try PeerGrantSet(role: .remoteController, commands: Set(parameters.map(live)), reads: reads)
    }

    static func observer() throws -> PeerGrantSet {
        try PeerGrantSet(role: .observer, commands: [], reads: [.statusRead])
    }

    static func store(trusting identity: PeerIdentityFingerprint = identity(1), grants: PeerGrantSet? = nil,
                      floor: UInt16 = 1) throws -> PeerTrustStore {
        var store = PeerTrustStore()
        try store.pair(identity, label: "Remote C", grants: grants ?? remote(), protocolFloor: floor)
        return store
    }

    static func catalog() throws -> ParameterCatalog {
        try ParameterCatalog([fxGain, outGain].map { id in
            try ParameterDescriptor(.init(
                id: id, unit: .normalized, lower: 0, upper: 1, defaultValue: 0.5, ceiling: nil, curve: .linear,
                ramp: .step, controlClass: .live, verification: .reported
            ))
        })
    }

    static func intent(_ operation: CommandOperation, commandClass: CommandClass = .live,
                       on session: PeerAuthorizedSession,
                       permission: PermissionFingerprint? = nil) throws -> CommandIntent {
        try CommandIntent(.init(
            id: CommandID(validated: "cmd.peer"), commandClass: commandClass, origin: .controller,
            hostEpoch: session.hostEpoch, connectionEpoch: session.connectionEpoch, revisions: CommandRevisions(),
            operation: operation, permission: permission ?? session.permission
        ))
    }

    static func set(_ parameter: ParameterID, _ value: Double = 0.4) -> CommandOperation {
        .set(parameter, ParameterValue(value: value, unit: .normalized))
    }

    static func admit(_ intent: CommandIntent, from session: PeerAuthorizedSession, trust: PeerTrustStore,
                      lifecycle: EngineLifecycle = .running) throws -> HostCommandDecision {
        PeerGrantGate.admit(intent, from: session, trust: trust, host: PeerGrantGate.HostState(
            revisions: CommandRevisions(), catalog: try catalog(), lifecycle: lifecycle
        ))
    }
}

private typealias Support = PeerTrustTestSupport

@Suite("PeerTrustTests")
struct PeerTrustTests {
    private let peer = Support.identity(1)

    private func bound(_ store: PeerTrustStore, session: PeerNegotiatedSession = Support.session())
        throws -> PeerAuthorizedSession {
        try store.bind(peer, session: session, connection: Support.connection, host: Support.hostEpoch)
    }

    // MARK: Binding

    @Test("A trusted identity binds to the negotiated connection with its exact grants")
    func bindsTrustedIdentity() throws {
        let store = try Support.store(trusting: peer)
        #expect(store.availability(for: peer) == .available)
        let session = try bound(store)
        #expect(session.role == .remoteController)
        #expect(session.commands == [Support.live(Support.fxGain)])
        #expect(session.readsStatus)
        #expect(session.connectionEpoch == ConnectionEpoch(connection: Support.connection, host: Support.hostID,
                                                           generation: Support.generation(4)))
        #expect(session.permission == store.record(for: peer)?.permissionFingerprint)
        let intent = try Support.intent(Support.set(Support.fxGain), on: session)
        #expect(try Support.admit(intent, from: session, trust: store) == .admitted)
    }

    @Test("Unknown and wrong identities are denied and cannot bind")
    func wrongIdentityRejects() throws {
        let store = try Support.store(trusting: peer)
        let stranger = Support.identity(2)
        #expect(store.availability(for: stranger) == .denied)
        #expect(throws: PeerTrustError.unknownIdentity) {
            try store.bind(stranger, session: Support.session(), connection: Support.connection,
                           host: Support.hostEpoch)
        }
        #expect(PeerIdentityFingerprint(Array(repeating: 1, count: 31)) == nil)
        #expect(PeerIdentityFingerprint(Array(repeating: 1, count: 33)) == nil)
    }

    @Test("A session from another host epoch does not bind")
    func hostEpochMismatchRejects() throws {
        let store = try Support.store(trusting: peer)
        #expect(throws: PeerTrustError.hostEpochMismatch) { try bound(store, session: Support.session(host: 8)) }
    }

    // MARK: Grants

    @Test("Grants match exact scopes only: no prefix, sibling or unknown scope")
    func exactScopeOnly() throws {
        let store = try Support.store(trusting: peer)
        let session = try bound(store)
        let prefix = ParameterID(validated: "par.fx")
        let longer = ParameterID(validated: "par.fx.gain2")
        let unknown = ParameterID(validated: "par.unknown")
        for parameter in [prefix, longer, unknown, Support.outGain] {
            #expect(!session.permits(.live, .parameter(parameter)))
            let intent = try Support.intent(Support.set(parameter), on: session)
            #expect(try Support.admit(intent, from: session, trust: store) == .refused(.rejected(.scopeDenied)))
        }
        let trigger = try Support.intent(.trigger(ActionID(validated: "act.fx")), on: session)
        #expect(try Support.admit(trigger, from: session, trust: store) == .refused(.rejected(.scopeDenied)))
    }

    @Test("A mismatched (class, scope) pair is refused by the exact gate before admission")
    func mismatchedPairRefusedFirst() throws {
        let store = try Support.store(trusting: peer)
        let session = try bound(store)
        #expect(!session.permits(.structural, .parameter(Support.fxGain)))
        let intent = try Support.intent(Support.set(Support.fxGain), commandClass: .structural, on: session)
        #expect(try Support.admit(intent, from: session, trust: store) == .refused(.rejected(.scopeDenied)))
    }

    @Test("Panic and Safe Mute are never granted and never admitted for a peer")
    func safetyNeverGranted() throws {
        for grant in [PeerCommandGrant(controlClass: .safety, scope: .safety),
                      PeerCommandGrant(controlClass: .live, scope: .safety),
                      PeerCommandGrant(controlClass: .safety, scope: .parameter(Support.fxGain))] {
            for role in PeerRole.allCases {
                #expect(throws: PeerTrustError.safetyNotGrantable) {
                    try PeerGrantSet(role: role, commands: [grant, Support.live(Support.fxGain)], reads: [.statusRead])
                }
            }
        }
        let store = try Support.store(trusting: peer)
        let session = try bound(store)
        for operation in [CommandOperation.panic, .safeMute] {
            let intent = try Support.intent(operation, commandClass: .safety, on: session)
            #expect(try Support.admit(intent, from: session, trust: store) == .refused(.rejected(.scopeDenied)))
        }
    }

    @Test("Grants cannot exceed the role ceiling, and empty grants grant nothing")
    func roleCeiling() throws {
        let route = PeerCommandGrant(controlClass: .live, scope: .route(RouteID(validated: "rte.fx")))
        let structural = PeerCommandGrant(controlClass: .structural, scope: .parameter(Support.fxGain))
        let transport = PeerCommandGrant(controlClass: .live, scope: .transport)
        for grant in [route, structural, transport] {
            #expect(throws: PeerTrustError.grantOutsideRole(.remoteController)) {
                try PeerGrantSet(role: .remoteController, commands: [grant], reads: [])
            }
        }
        #expect(throws: PeerTrustError.grantOutsideRole(.observer)) {
            try PeerGrantSet(role: .observer, commands: [Support.live(Support.fxGain)], reads: [.statusRead])
        }
        #expect(throws: PeerTrustError.noCommandGrants) {
            try PeerGrantSet(role: .remoteController, commands: [], reads: [.statusRead])
        }
        #expect(throws: PeerTrustError.observerRequiresStatusRead) {
            try PeerGrantSet(role: .observer, commands: [], reads: [])
        }
        let many = Set(try (0...PeerGrantSet.maximumCommandGrants).map {
            Support.live(try ParameterID("par.p\($0)"))
        })
        #expect(throws: PeerTrustError.tooManyGrants(65)) {
            try PeerGrantSet(role: .remoteController, commands: many, reads: [])
        }
        let full = try PeerGrantSet(role: .remoteController, commands: Set(many.prefix(64)), reads: [])
        #expect(full.commands.count == 64)
    }

    @Test("An observer binds with status only and every command is refused")
    func observerHasNoCommands() throws {
        let store = try Support.store(trusting: peer, grants: Support.observer())
        let session = try bound(store)
        #expect(session.commands.isEmpty && session.readsStatus)
        let intent = try Support.intent(Support.set(Support.fxGain), on: session)
        #expect(try Support.admit(intent, from: session, trust: store) == .refused(.rejected(.scopeDenied)))
    }

    @Test("The gate keeps HostCommandGate's lifecycle refusal")
    func lifecycleStillApplies() throws {
        let store = try Support.store(trusting: peer)
        let session = try bound(store)
        let intent = try Support.intent(Support.set(Support.fxGain), on: session)
        let decision = try Support.admit(intent, from: session, trust: store, lifecycle: .recovering)
        #expect(decision == .unavailable(.recovering))
    }

    // MARK: Downgrade

    @Test("A session below the paired protocol version is a downgrade")
    func versionDowngradeRejects() throws {
        let store = try Support.store(trusting: peer, floor: 2)
        #expect(throws: PeerTrustError.versionDowngrade(floor: 2, negotiated: 1)) {
            try bound(store, session: Support.session(version: 1))
        }
        #expect(try bound(store, session: Support.session(version: 2)).commands.count == 1)
        #expect(try bound(store, session: Support.session(version: 3)).commands.count == 1)
    }

    @Test("Negotiated capabilities only narrow grants")
    func capabilitiesOnlyNarrow() throws {
        let store = try Support.store(trusting: peer)
        let noControl = try bound(store, session: Support.session(capabilities: ["status", "telemetry"]))
        #expect(noControl.commands.isEmpty && noControl.readsStatus)
        let intent = try Support.intent(Support.set(Support.fxGain), on: noControl)
        #expect(try Support.admit(intent, from: noControl, trust: store) == .refused(.rejected(.scopeDenied)))
        let noStatus = try bound(store, session: Support.session(capabilities: ["control", "telemetry"]))
        #expect(!noStatus.readsStatus && noStatus.commands.count == 1)
        let extra = try bound(store, session: Support.session(capabilities: ["control", "status", "telemetry",
                                                                             "x-all"]))
        #expect(extra.commands == [Support.live(Support.fxGain)])
        let observer = try Support.store(trusting: peer, grants: Support.observer())
        #expect(try bound(observer, session: Support.session(capabilities: ["control", "status"])).commands.isEmpty)
        let noReads = try Support.store(trusting: peer, grants: Support.remote(reads: []))
        #expect(!(try bound(noReads)).readsStatus)
    }
}
