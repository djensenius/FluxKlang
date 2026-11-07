import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// Recipes for the principal suite: one host, one connection, one permission and a three parameter catalog.
extension OSCTransportFixture {
    typealias Grant = OSC.PrincipalGrant
    typealias PrincipalError = OSC.PrincipalRefusal

    static let hostID = HostID(validated: "host.osc")
    static let hostEpoch = HostEpoch(host: hostID, generation: generation(7))
    static let connectionEpoch = ConnectionEpoch(
        connection: ConnectionID(validated: "con.osc"), host: hostID, generation: generation(3)
    )
    static let fingerprint = PermissionFingerprint(rawValue: "perm.osc.1")
    static let fader = ParameterID(validated: "par.fader")
    static let pan = ParameterID(validated: "par.pan")
    static let hazard = ParameterID(validated: "par.hazard")
    static let cue = ActionID(validated: "act.cue")
    static let route = RouteID(validated: "rte.main")
    static let patch = PatchID(validated: "pat.main")
    static let draft = DraftID(validated: "drf.main")

    /// Every kind of scope, none of them the same as another.
    static let scopes: [CommandScope] = [
        .parameter(fader), .action(cue), .transport, .route(route), .patch(patch), .draft(draft), .safety
    ]
    static let lifecycles: [EngineLifecycle] = [
        .stopped, .preparing(.initial, over: .absent), .preparing(.initial, over: .running), .running,
        .degraded([]), .recovering, .heldByOther(ProjectID(validated: "prj.other"))
    ]
    static let liveGrants = [grant(.parameter(fader)), grant(.action(cue)), grant(.transport)]

    static func generation(_ value: Int) -> Generation {
        do { return try Generation(value) } catch { preconditionFailure("invalid generation \(value)") }
    }

    static func grant(_ scope: CommandScope, _ controlClass: ControlClass = .live) -> Grant {
        Grant(controlClass: controlClass, scope: scope)
    }

    /// `count` distinct, valid live grants over parameters `par.0`, `par.1` and so on.
    static func distinctGrants(_ count: Int) throws -> [Grant] {
        try (0..<count).map { grant(.parameter(try ParameterID("par.\($0)"))) }
    }

    static func principal(
        _ grants: [Grant]? = nil, host: HostEpoch = hostEpoch, connection: ConnectionEpoch = connectionEpoch,
        permission: PermissionFingerprint = fingerprint
    ) throws(PrincipalError) -> OSC.Principal {
        try OSC.Principal(
            hostEpoch: host, connectionEpoch: connection, permission: permission, grants: grants ?? liveGrants
        )
    }

    /// What is injected at construction and the one refusal it must produce.
    struct Construction {
        let expected: PrincipalError
        let grants: [Grant]
        let connection: ConnectionEpoch
        let permission: PermissionFingerprint

        init(
            _ expected: PrincipalError, _ grants: [Grant], _ connection: ConnectionEpoch,
            _ permission: PermissionFingerprint
        ) {
            self.expected = expected
            self.grants = grants
            self.connection = connection
            self.permission = permission
        }
    }

    static func descriptor(_ id: ParameterID, _ controlClass: ControlClass) throws -> ParameterDescriptor {
        try ParameterDescriptor(.init(
            id: id, unit: .normalized, lower: 0, upper: 1, defaultValue: 0.5, ceiling: nil, curve: .linear,
            ramp: .step, controlClass: controlClass, verification: .reported
        ))
    }

    /// `par.fader` and `par.pan` are live parameters; `par.hazard` is hazardous.
    static func catalog() throws -> ParameterCatalog {
        try ParameterCatalog([descriptor(fader, .live), descriptor(pan, .live), descriptor(hazard, .hazardous)])
    }

    static func value(_ number: Double = 0.4) -> ParameterValue { ParameterValue(value: number, unit: .normalized) }

    /// One operation of every kind; six of them are live operations.
    static func operations() -> [CommandOperation] {
        [
            .set(fader, value()), .ramp(fader, value(), milliseconds: 0), .trigger(cue), .start, .stop,
            .locate(ticks: 0), .bind(route), .recall(patch), .editDraft(draft), .propose(draft), .panic, .safeMute
        ]
    }

    static func intent(
        _ operation: CommandOperation, commandClass: ControlClass = .live, origin: CommandOrigin = .controller,
        host: HostEpoch = hostEpoch, connection: ConnectionEpoch? = connectionEpoch,
        revisions: CommandRevisions = CommandRevisions(), permission: PermissionFingerprint = fingerprint
    ) throws -> CommandIntent {
        try CommandIntent(.init(
            id: CommandID(validated: "cmd.osc"), commandClass: commandClass, origin: origin, hostEpoch: host,
            connectionEpoch: connection, revisions: revisions, operation: operation, permission: permission
        ))
    }

    static func revisions(bumping field: WritableKeyPath<CommandRevisions, ContractRevision>) throws
        -> CommandRevisions {
        var revisions = CommandRevisions()
        revisions[keyPath: field] = try ContractRevision.initial.next()
        return revisions
    }

    static func admit(
        _ principal: OSC.Principal, _ intent: CommandIntent, revisions: CommandRevisions = CommandRevisions(),
        lifecycle: EngineLifecycle = .running, ceiling: Double? = nil
    ) throws -> HostCommandDecision {
        principal.admit(intent, revisions: revisions, catalog: try catalog(), lifecycle: lifecycle, ceiling: ceiling)
    }

    /// The context the principal must hand the host gate, written out by hand.
    static func gateContext(revisions: CommandRevisions = CommandRevisions(), ceiling: Double? = nil) throws
        -> AdmissionContext {
        AdmissionContext(
            hostEpoch: hostEpoch, connectionEpoch: connectionEpoch, revisions: revisions, permission: fingerprint,
            allowedScopes: [.parameter(fader), .action(cue), .transport], allowedClasses: [.live],
            catalog: try catalog(), ceiling: ceiling
        )
    }
}

/// The live-only principal OSC intake acts as (#89, O2b): construction bounds, exact grants and admission.
extension OSCTransportTests {
    // MARK: Principal: construction

    @Test("The principal is live-only: exactly the live class, controller origin and at most 256 grants")
    func principalConstantsArePinned() {
        #expect(OSC.Principal.allowedClasses == [.live])
        #expect(OSC.Principal.origin == .controller)
        #expect(OSC.Principal.maximumGrants == 256)
    }

    @Test("A principal keeps what was injected and nothing that names a peer, address or session")
    func principalHoldsOnlyWhatWasInjected() throws {
        let principal = try Fixture.principal()
        #expect(principal.hostEpoch == Fixture.hostEpoch)
        #expect(principal.connectionEpoch == Fixture.connectionEpoch)
        #expect(principal.permission == Fixture.fingerprint)
        #expect(principal.grants == Set(Fixture.liveGrants))
        let labels = Mirror(reflecting: principal).children.compactMap(\.label)
        #expect(labels == ["hostEpoch", "connectionEpoch", "permission", "grants"])
    }

    @Test("Parameter, action and transport scopes are grantable; route, patch, draft and safety are not")
    func grantableScopesAreExact() throws {
        let grantable: [CommandScope] = [.parameter(Fixture.fader), .action(Fixture.cue), .transport]
        for scope in grantable {
            #expect(try Fixture.principal([Fixture.grant(scope)]).grants == [Fixture.grant(scope)])
        }
        let refused: [CommandScope] = [.route(Fixture.route), .patch(Fixture.patch), .draft(Fixture.draft), .safety]
        for scope in refused {
            let error = Fixture.PrincipalError.scopeNotGrantable(scope)
            #expect(throws: error) { try Fixture.principal([Fixture.grant(scope)]) }
        }
    }

    @Test("Only the live class is accepted, and a grant's class is refused before its scope is looked at")
    func nonLiveClassesAreRefusedBeforeScopes() {
        for controlClass in ControlClass.allCases where controlClass != .live {
            for scope in Fixture.scopes {
                let grant = Fixture.grant(scope, controlClass)
                let error = Fixture.PrincipalError.classNotAllowed(controlClass)
                #expect(throws: error, "\(controlClass) \(scope)") { try Fixture.principal([grant]) }
            }
        }
    }

    @Test("1 through 256 grants are accepted; none and 257 are refused")
    func grantCountBounds() throws {
        #expect(throws: Fixture.PrincipalError.noGrants) { try Fixture.principal([]) }
        for count in [1, 2, 255, 256] {
            #expect(try Fixture.principal(Fixture.distinctGrants(count)).grants.count == count)
        }
        let over = try Fixture.distinctGrants(257)
        let error = Fixture.PrincipalError.tooManyGrants(count: 257, limit: 256)
        #expect(throws: error) { try Fixture.principal(over) }
    }

    @Test("A fingerprint of 1 through 256 UTF-8 bytes is accepted; 0 and 257 are malformed")
    func permissionLengthBounds() throws {
        for count in [1, 256] {
            let permission = PermissionFingerprint(rawValue: String(repeating: "p", count: count))
            #expect(try Fixture.principal(permission: permission).permission == permission)
        }
        for count in [0, 257] {
            let permission = PermissionFingerprint(rawValue: String(repeating: "p", count: count))
            #expect(throws: Fixture.PrincipalError.malformedPermission) {
                try Fixture.principal(permission: permission)
            }
        }
        // Bytes, not characters: 128 two-byte characters fit, 129 do not.
        let fits = PermissionFingerprint(rawValue: String(repeating: "\u{E9}", count: 128))
        #expect(try Fixture.principal(permission: fits).permission == fits)
        let wide = PermissionFingerprint(rawValue: String(repeating: "\u{E9}", count: 129))
        #expect(throws: Fixture.PrincipalError.malformedPermission) { try Fixture.principal(permission: wide) }
    }

    @Test("A connection epoch must belong to the host epoch's host; its generation is independent")
    func connectionEpochMustMatchTheHost() throws {
        let current = Fixture.connectionEpoch
        let foreign = ConnectionEpoch(
            connection: current.connection, host: HostID(validated: "host.other"), generation: current.generation
        )
        #expect(throws: Fixture.PrincipalError.connectionEpochForOtherHost) {
            try Fixture.principal(connection: foreign)
        }
        let later = ConnectionEpoch(
            connection: current.connection, host: Fixture.hostID, generation: Fixture.generation(900)
        )
        #expect(try Fixture.principal(connection: later).connectionEpoch == later)
    }

    @Test("Construction refuses in a fixed order: permission, host, count, then each grant in array order")
    func constructionRefusalOrder() throws {
        let foreign = ConnectionEpoch(
            connection: Fixture.connectionEpoch.connection, host: HostID(validated: "host.other"),
            generation: Fixture.connectionEpoch.generation
        )
        let empty = PermissionFingerprint(rawValue: "")
        let live = Fixture.grant(.parameter(Fixture.fader))
        let routed = Fixture.grant(.route(Fixture.route))
        let structuralRoute = Fixture.grant(.route(Fixture.route), .structural)
        let tooMany = [Fixture.Grant](repeating: routed, count: 257)
        let home = Fixture.connectionEpoch
        let valid = Fixture.fingerprint
        let refusals: [Fixture.Construction] = [
            .init(.malformedPermission, [], foreign, empty),
            .init(.connectionEpochForOtherHost, [], foreign, valid),
            .init(.noGrants, [], home, valid),
            .init(.tooManyGrants(count: 257, limit: 256), tooMany, home, valid),
            .init(.duplicateGrant(live), [live, live, routed], home, valid),
            .init(.scopeNotGrantable(routed.scope), [live, routed, live], home, valid),
            .init(.classNotAllowed(.structural), [structuralRoute, live, live], home, valid)
        ]
        for (index, refusal) in refusals.enumerated() {
            #expect(throws: refusal.expected, "case \(index)") {
                try Fixture.principal(refusal.grants, connection: refusal.connection, permission: refusal.permission)
            }
        }
    }

    @Test("A duplicate grant is refused, and the order of distinct grants never matters")
    func duplicatesAreRefusedAndOrderIsIrrelevant() throws {
        let grants = Fixture.liveGrants
        let duplicated = Fixture.PrincipalError.duplicateGrant(grants[1])
        #expect(throws: duplicated) { try Fixture.principal(grants + [grants[1]]) }
        let forward = try Fixture.principal(grants)
        let backward = try Fixture.principal(Array(grants.reversed()))
        #expect(forward == backward && forward.hashValue == backward.hashValue)
        let other = try Fixture.principal(grants, permission: PermissionFingerprint(rawValue: "perm.osc.2"))
        #expect(forward != other)
    }

    @Test("permits is an exact (class, scope) pair, never class-only, scope-only, prefix or group")
    func permitsIsAnExactPair() throws {
        let principal = try Fixture.principal()
        let permitted: [(ControlClass, CommandScope)] = [
            (.live, .parameter(Fixture.fader)), (.live, .action(Fixture.cue)), (.live, .transport)
        ]
        let scopes = Fixture.scopes + [.parameter(Fixture.pan), .action(try ActionID("act.cue2"))]
        for controlClass in ControlClass.allCases {
            for scope in scopes {
                let expected = permitted.contains { $0.0 == controlClass && $0.1 == scope }
                #expect(principal.permits(controlClass, scope) == expected, "\(controlClass) \(scope)")
            }
        }
    }

    // MARK: Principal: admission

    @Test("Of every operation under every class, only the six live operations under live are admitted")
    func onlyLiveOperationsUnderLiveAreAdmitted() throws {
        let principal = try Fixture.principal()
        let live: [CommandOperation] = Array(Fixture.operations().prefix(6))
        #expect(live.count == 6 && live.last == .locate(ticks: 0))
        var admitted = 0
        for operation in Fixture.operations() {
            for controlClass in ControlClass.allCases {
                let decision = try Fixture.admit(principal, Fixture.intent(operation, commandClass: controlClass))
                if controlClass == .live && live.contains(operation) {
                    admitted += 1
                    #expect(decision == .admitted, "\(operation)")
                } else {
                    #expect(decision == .refused(.rejected(.scopeDenied)), "\(controlClass) \(operation)")
                }
            }
        }
        #expect(admitted == 6)
    }

    @Test("Structural, hazardous, safety and proposal commands are refused whatever the lifecycle")
    func nonLiveCommandsAreNeverAdmitted() throws {
        let principal = try Fixture.principal(Fixture.liveGrants + [Fixture.grant(.parameter(Fixture.hazard))])
        let hazardous = CommandOperation.set(Fixture.hazard, Fixture.value())
        let commands: [(CommandOperation, ControlClass)] = [
            (.bind(Fixture.route), .structural), (.recall(Fixture.patch), .structural),
            (.editDraft(Fixture.draft), .structural), (.propose(Fixture.draft), .proposal),
            (.panic, .safety), (.safeMute, .safety), (hazardous, .hazardous), (hazardous, .structural)
        ]
        for lifecycle in Fixture.lifecycles {
            for (operation, controlClass) in commands {
                let intent = try Fixture.intent(operation, commandClass: controlClass)
                let decision = try Fixture.admit(principal, intent, lifecycle: lifecycle)
                #expect(decision == .refused(.rejected(.scopeDenied)), "\(controlClass) \(operation) \(lifecycle)")
            }
        }
    }

    @Test("A permissive host gate admits panic and safe mute in every lifecycle; the principal still refuses them")
    func panicAndSafeMuteAreRefusedWhereTheGateWouldAdmit() throws {
        let principal = try Fixture.principal()
        let permissive = AdmissionContext(
            hostEpoch: Fixture.hostEpoch, connectionEpoch: Fixture.connectionEpoch, revisions: CommandRevisions(),
            permission: Fixture.fingerprint, allowedScopes: [.safety], allowedClasses: [.safety],
            catalog: try Fixture.catalog(), ceiling: nil
        )
        for operation in [CommandOperation.panic, .safeMute] {
            let intent = try Fixture.intent(operation, commandClass: .safety)
            for lifecycle in Fixture.lifecycles {
                #expect(HostCommandGate.admit(intent, admission: permissive, lifecycle: lifecycle) == .admitted)
                #expect(try Fixture.admit(principal, intent, lifecycle: lifecycle) == .refused(.rejected(.scopeDenied)))
            }
        }
    }

    @Test("Any origin but controller is permissionDenied, checked before the pair and before the gate")
    func onlyControllerOriginIsAccepted() throws {
        let principal = try Fixture.principal()
        let denied = HostCommandDecision.refused(.rejected(.permissionDenied))
        for origin in [CommandOrigin.human, .assistant] {
            for operation in Fixture.operations() {
                for controlClass in ControlClass.allCases {
                    let intent = try Fixture.intent(operation, commandClass: controlClass, origin: origin)
                    #expect(try Fixture.admit(principal, intent) == denied, "\(origin) \(controlClass) \(operation)")
                }
            }
            let stale = HostEpoch(host: Fixture.hostID, generation: Fixture.generation(8))
            #expect(try Fixture.admit(principal, Fixture.intent(.start, origin: origin, host: stale)) == denied)
        }
        #expect(try Fixture.admit(principal, Fixture.intent(.start)) == .admitted)
    }

    @Test("The pair is checked before the gate: a granted scope under another class is scopeDenied")
    func pairIsCheckedBeforeTheGate() throws {
        let principal = try Fixture.principal()
        for controlClass in ControlClass.allCases where controlClass != .live {
            let intent = try Fixture.intent(.set(Fixture.fader, Fixture.value()), commandClass: controlClass)
            #expect(try Fixture.admit(principal, intent) == .refused(.rejected(.scopeDenied)), "\(controlClass)")
            // The gate alone, with the same context, would have reported the class.
            let raw = HostCommandGate.admit(intent, admission: try Fixture.gateContext(), lifecycle: .running)
            #expect(raw == .refused(.rejected(.permissionDenied)), "\(controlClass)")
        }
    }

    @Test("Stale epochs, a changed permission or revision and the lifecycle reach the gate unchanged")
    func gateRefusalsPassThroughUnchanged() throws {
        let principal = try Fixture.principal()
        let staleHost = HostEpoch(host: Fixture.hostID, generation: Fixture.generation(8))
        let current = Fixture.connectionEpoch
        let staleConnection = ConnectionEpoch(
            connection: current.connection, host: current.host, generation: Fixture.generation(4)
        )
        let changed = PermissionFingerprint(rawValue: "perm.osc.2")
        let cases: [(CommandIntent, HostCommandDecision)] = [
            (try Fixture.intent(.start, host: staleHost), .refused(.stale(.hostEpoch))),
            (try Fixture.intent(.start, connection: staleConnection), .refused(.stale(.connectionEpoch))),
            (try Fixture.intent(.start, connection: nil), .refused(.stale(.connectionEpoch))),
            (try Fixture.intent(.start, permission: changed), .refused(.rejected(.permissionChanged)))
        ]
        for (intent, expected) in cases {
            #expect(try Fixture.admit(principal, intent) == expected)
            let raw = HostCommandGate.admit(intent, admission: try Fixture.gateContext(), lifecycle: .running)
            #expect(raw == expected)
        }
        let fields: [WritableKeyPath<CommandRevisions, ContractRevision>] = [
            \.patch, \.capability, \.permission, \.parameter, \.graph
        ]
        for field in fields {
            let bumped = try Fixture.revisions(bumping: field)
            let revisionChanged = HostCommandDecision.refused(.rejected(.revisionChanged))
            #expect(try Fixture.admit(principal, Fixture.intent(.start, revisions: bumped)) == revisionChanged)
            #expect(try Fixture.admit(principal, Fixture.intent(.start), revisions: bumped) == revisionChanged)
            // The same decision the host gate reaches on a context written out by hand.
            let intent = try Fixture.intent(.start, revisions: bumped)
            let context = try Fixture.gateContext(revisions: bumped)
            #expect(HostCommandGate.admit(intent, admission: context, lifecycle: .running) == .admitted)
            #expect(try Fixture.admit(principal, intent, revisions: bumped) == .admitted)
        }
    }

    @Test("While recovering or held by another project live commands are unavailable; every other lifecycle admits")
    func lifecycleDecidesAvailability() throws {
        let principal = try Fixture.principal()
        let unavailable: Set<EngineLifecycle> = [.recovering, .heldByOther(ProjectID(validated: "prj.other"))]
        for operation in Fixture.operations().prefix(6) {
            let intent = try Fixture.intent(operation)
            for lifecycle in Fixture.lifecycles {
                let expected: HostCommandDecision = unavailable.contains(lifecycle)
                    ? .unavailable(lifecycle) : .admitted
                let decision = try Fixture.admit(principal, intent, lifecycle: lifecycle)
                #expect(decision == expected, "\(operation) \(lifecycle)")
            }
        }
    }

    @Test("Parameter checks keep their own reasons: unknown parameter, class mismatch, unit, range, ramp and ceiling")
    func parameterChecksPassThrough() throws {
        let ghost = ParameterID(validated: "par.ghost")
        let grants = Fixture.liveGrants + [Fixture.grant(.parameter(Fixture.hazard)), Fixture.grant(.parameter(ghost))]
        let principal = try Fixture.principal(grants)
        func decide(_ operation: CommandOperation, ceiling: Double? = nil) throws -> HostCommandDecision {
            try Fixture.admit(principal, Fixture.intent(operation), ceiling: ceiling)
        }
        let value = Fixture.value()
        #expect(try decide(.set(ghost, value)) == .refused(.rejected(.unknownParameter(ghost))))
        #expect(try decide(.set(Fixture.hazard, value)) == .refused(.rejected(.classMismatch)))
        let percent = ParameterValue(value: 0.5, unit: .percent)
        let unit = CommandRejection.invalidValue(.unitMismatch(expected: .normalized, found: .percent))
        #expect(try decide(.set(Fixture.fader, percent)) == .refused(.rejected(unit)))
        let range = CommandRejection.invalidValue(.outOfRange(1.5, lower: 0, upper: 1))
        #expect(try decide(.set(Fixture.fader, Fixture.value(1.5))) == .refused(.rejected(range)))
        let ramp = CommandRejection.invalidValue(.invalidRamp)
        #expect(try decide(.ramp(Fixture.fader, value, milliseconds: 0)) == .admitted)
        #expect(try decide(.ramp(Fixture.fader, value, milliseconds: 1)) == .refused(.rejected(ramp)))
        // A ceiling of 0.5 admits 0.5 and refuses 0.75.
        let ceiling = CommandRejection.invalidValue(.aboveCeiling(0.75, ceiling: 0.5))
        #expect(try decide(.set(Fixture.fader, Fixture.value(0.5)), ceiling: 0.5) == .admitted)
        #expect(try decide(.set(Fixture.fader, Fixture.value(0.75)), ceiling: 0.5) == .refused(.rejected(ceiling)))
        #expect(try decide(.set(Fixture.fader, Fixture.value(0.75))) == .admitted)
    }

    @Test("The admission context carries exactly the injected identity, the granted scopes and the live class")
    func admissionContextIsExact() throws {
        let principal = try Fixture.principal()
        let revisions = try Fixture.revisions(bumping: \.parameter)
        let context = principal.admissionContext(revisions: revisions, catalog: try Fixture.catalog(), ceiling: 0.5)
        #expect(context.hostEpoch == Fixture.hostEpoch && context.connectionEpoch == Fixture.connectionEpoch)
        #expect(context.permission == Fixture.fingerprint && context.revisions == revisions)
        #expect(context.allowedScopes == [.parameter(Fixture.fader), .action(Fixture.cue), .transport])
        #expect(context.allowedClasses == [.live] && context.ceiling == 0.5)
        #expect(context.catalog.parameters.map(\.id) == [Fixture.fader, Fixture.pan, Fixture.hazard])
        #expect(principal.admissionContext(revisions: revisions, catalog: try Fixture.catalog()).ceiling == nil)
    }
}
