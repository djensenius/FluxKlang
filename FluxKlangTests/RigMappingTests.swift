import Testing
@testable import FluxKlang

/// Shared builders for the rig mapping suites.
enum RigMappingFixture {
    static let host = HostID(validated: "host.rig")

    static func role(_ id: String, _ direction: PortDirection = .output, channels: Int? = 2,
                     signal: PortSignal = .audio) throws -> ProjectRole {
        try ProjectRole(id: RoleID(id), label: id, direction: direction, signal: signal, channels: channels)
    }

    static func device(_ id: String, inputs: Int = 0, outputs: Int = 0, presence: DevicePresence = .present,
                       kind: DeviceKind = .audioInterface, layout: Bool = true) throws -> DeviceDescriptor {
        try DeviceDescriptor(
            id: DeviceID(id), kind: kind,
            layout: layout ? ChannelLayout(inputs: inputs, outputs: outputs, sampleRate: 48_000) : nil,
            binding: .reported, identity: DeviceIdentity(.init(uid: "uid-\(id)", evidence: [.deviceUID])),
            presence: presence
        )
    }

    static func route(_ id: String, role: String, device: String, direction: RouteDirection = .output,
                      channels: [Int] = [0, 1], binding: RouteBinding) throws -> AudioRoute {
        var route = try AudioRoute(id: RouteID(id), role: RoleID(role), device: DeviceID(device),
                                   direction: direction, channels: channels, binding: binding)
        if binding == .confirmed {
            route.confirmedHost = host
            route.confirmedEpoch = .initial
            route.confirmedDeviceUID = "uid-\(device)"
            route.evidence = "human-confirmed-port-map"
        }
        return route
    }

    static func document(_ devices: [DeviceDescriptor], routes: [AudioRoute] = []) throws -> DeviceCapabilityDocument {
        try DeviceCapabilityDocument(revision: .initial, host: host, hostEpoch: .initial,
                                     devices: devices, routes: routes)
    }

    static func proposal(_ roles: [ProjectRole], _ devices: [DeviceDescriptor],
                         routes: [AudioRoute] = []) throws -> RigMappingProposal {
        try RigMappingProposal.make(roles: roles, devices: document(devices, routes: routes))
    }

    static func outcome(_ proposal: RigMappingProposal, _ role: String) -> RigRoleOutcome? {
        proposal.mappings.first { $0.role.rawValue == role }?.outcome
    }

    static func candidates(_ proposal: RigMappingProposal, _ role: String) -> RigRoleCandidates? {
        if case .awaitingChoice(let found) = outcome(proposal, role) { found } else { nil }
    }

    /// The document with the proposal's routes appended must pass the contract's role validation.
    static func expectValid(_ proposal: RigMappingProposal, over document: DeviceCapabilityDocument) throws {
        let combined = try DeviceCapabilityDocument(
            revision: .initial, host: host, hostEpoch: .initial, devices: document.devices,
            routes: document.routes + proposal.proposedRoutes
        )
        try combined.validate(roles: proposal.requirements)
        let layouts = Dictionary(uniqueKeysWithValues: document.devices.map { ($0.id, $0.layout) })
        for route in proposal.proposedRoutes {
            let requirement = try #require(proposal.requirements[route.role])
            try route.validate(layout: layouts[route.device] ?? nil, role: requirement)
            #expect(route.binding == .proposed)
            #expect(route.evidence == nil && route.confirmedHost == nil)
            #expect(route.confirmedEpoch == nil && route.confirmedDeviceUID == nil)
        }
    }
}

private typealias Fixture = RigMappingFixture

@Suite("Rig mapping proposals")
struct RigMappingTests {
    @Test func singleMatchingBlockBecomesAProposedRouteInTheRoleDirection() throws {
        let roles = try [Fixture.role("role.mains", .output, channels: 2),
                         Fixture.role("role.mic", .input, channels: 1)]
        let devices = try [Fixture.device("dev.a", inputs: 1, outputs: 2)]
        let proposal = try Fixture.proposal(roles, devices)
        let routes = proposal.proposedRoutes
        #expect(routes.map(\.id.rawValue) == ["route.proposed.role.mains", "route.proposed.role.mic"])
        #expect(routes.map(\.direction) == [.output, .input])
        #expect(routes.map(\.channels) == [[0, 1], [0]])
        #expect(routes.allSatisfy { $0.binding == .proposed && $0.device.rawValue == "dev.a" })
        guard case .proposed(let route, let candidate) = Fixture.outcome(proposal, "role.mic") else {
            Issue.record("expected a proposed route")
            return
        }
        #expect(route.channels == candidate.channels && candidate.direction == .input)
        let mic = try RoleID("role.mic")
        #expect(proposal.requirements[mic] == RouteRoleRequirement(direction: .input, channelCount: 1))
        try Fixture.expectValid(proposal, over: Fixture.document(devices))
    }

    @Test func blocksMustMatchDirectionAndExactChannelCount() throws {
        let roles = try [Fixture.role("role.quad", .output, channels: 4), Fixture.role("role.in", .input, channels: 2),
                         Fixture.role("role.wide", .output, channels: 3)]
        // Plenty of inputs, but no output block of four; exactly one output block of three.
        let proposal = try Fixture.proposal(roles, [Fixture.device("dev.a", inputs: 8, outputs: 3)])
        #expect(Fixture.outcome(proposal, "role.quad") == .unmapped(.noCompatibleBlock))
        #expect(proposal.unmapped.map(\.rawValue) == ["role.quad"])
        #expect(Fixture.candidates(proposal, "role.in")?.candidates.count == 7)
        #expect(Fixture.candidates(proposal, "role.in")?.candidates.allSatisfy { $0.direction == .input } == true)
        #expect(proposal.proposedRoutes.map(\.channels) == [[0, 1, 2]])
    }

    @Test func missingStaleAndMIDIDevicesOfferNoCandidates() throws {
        let devices = try [
            Fixture.device("dev.old", outputs: 8, presence: .stale),
            Fixture.device("dev.gone", outputs: 8, presence: .missing),
            Fixture.device("dev.keys", outputs: 8, kind: .midiController),
            Fixture.device("dev.blank", kind: .consoleCompatibility, layout: false)
        ]
        let proposal = try Fixture.proposal([Fixture.role("role.mains")], devices)
        #expect(Fixture.outcome(proposal, "role.mains") == .unmapped(.noCompatibleBlock))
        #expect(proposal.absentDevices.map(\.rawValue) == ["dev.gone", "dev.old"])
        #expect(proposal.proposedRoutes.isEmpty)
    }

    @Test func staleAndDeviceMissingRoutesAreReportedNeverReused() throws {
        let devices = try [Fixture.device("dev.a", outputs: 2),
                           Fixture.device("dev.gone", outputs: 2, presence: .missing)]
        let routes = try [
            Fixture.route("route.z.stale", role: "role.mains", device: "dev.a", binding: .stale),
            Fixture.route("route.a.missing", role: "role.mains", device: "dev.gone", binding: .deviceMissing)
        ]
        let document = try Fixture.document(devices, routes: routes)
        let proposal = try RigMappingProposal.make(roles: [Fixture.role("role.mains")], devices: document)
        let expected = try [
            RigExistingRouteReport(route: RouteID("route.a.missing"), role: RoleID("role.mains"),
                                   device: DeviceID("dev.gone"), state: .deviceMissing),
            RigExistingRouteReport(route: RouteID("route.z.stale"), role: RoleID("role.mains"),
                                   device: DeviceID("dev.a"), state: .stale)
        ]
        #expect(proposal.existingRoutes == expected)
        let route = try #require(proposal.proposedRoutes.first)
        #expect(proposal.proposedRoutes.count == 1)
        #expect(route.id.rawValue == "route.proposed.role.mains")
        #expect(route.device.rawValue == "dev.a" && route.binding == .proposed)
        try Fixture.expectValid(proposal, over: document)
    }

    @Test func confirmedOrProposedRoutesLeaveTheRoleAlone() throws {
        let devices = try [Fixture.device("dev.a", outputs: 2)]
        let routes = try [
            Fixture.route("route.b", role: "role.mains", device: "dev.a", binding: .proposed),
            Fixture.route("route.a", role: "role.mains", device: "dev.a", binding: .confirmed),
            Fixture.route("route.c", role: "role.side", device: "dev.a", binding: .stale)
        ]
        let roles = try [Fixture.role("role.mains"), Fixture.role("role.side")]
        let document = try Fixture.document(devices, routes: routes)
        let proposal = try RigMappingProposal.make(roles: roles, devices: document)
        let routed = try [RouteID("route.a"), RouteID("route.b")]
        #expect(Fixture.outcome(proposal, "role.mains") == .alreadyRouted(routed))
        #expect(proposal.proposedRoutes.map(\.role.rawValue) == ["role.side"])
        try Fixture.expectValid(proposal, over: document)
    }

    @Test func severalCandidatesAreNeverAutoPicked() throws {
        let proposal = try Fixture.proposal([Fixture.role("role.mains")], [Fixture.device("dev.a", outputs: 3)])
        #expect(proposal.proposedRoutes.isEmpty)
        #expect(proposal.awaitingChoice.map(\.rawValue) == ["role.mains"])
        #expect(proposal.unmapped.isEmpty)
        #expect(Fixture.candidates(proposal, "role.mains")?.candidates.map(\.channels) == [[0, 1], [1, 2]])
    }

    @Test func callerChoiceProducesOneProposedRoute() throws {
        let devices = try [Fixture.device("dev.a", outputs: 3), Fixture.device("dev.b", outputs: 2)]
        let roles = try [Fixture.role("role.mains"), Fixture.role("role.mono", channels: 1)]
        let routes = try [Fixture.route("route.taken", role: "role.mains", device: "dev.b", binding: .stale)]
        let document = try Fixture.document(devices, routes: routes)
        let proposal = try RigMappingProposal.make(roles: roles, devices: document)
        let offered = try #require(Fixture.candidates(proposal, "role.mains")?.candidates)
        #expect(offered.map(\.device.rawValue) == ["dev.a", "dev.a", "dev.b"])
        let chosen = try proposal.choosing(offered[1], id: RouteID("route.user"))
        #expect(proposal.proposedRoutes.isEmpty)
        let route = try #require(chosen.proposedRoutes.first)
        #expect(chosen.proposedRoutes.count == 1 && route.id.rawValue == "route.user")
        #expect(route.channels == [1, 2] && route.device.rawValue == "dev.a" && route.binding == .proposed)
        #expect(Fixture.outcome(chosen, "role.mains") == .proposed(route, from: offered[1]))
        #expect(chosen.awaitingChoice.map(\.rawValue) == ["role.mono"])
        try Fixture.expectValid(chosen, over: document)

        #expect(throws: RigMappingRefusal.candidateNotOffered(offered[0])) {
            try chosen.choosing(offered[0], id: RouteID("route.again"))
        }
        let mono = try #require(Fixture.candidates(chosen, "role.mono")?.candidates.first)
        for taken in try [RouteID("route.taken"), RouteID("route.user")] {
            #expect(throws: RigMappingRefusal.routeIDInUse(taken)) { try chosen.choosing(mono, id: taken) }
        }
        let both = try chosen.choosing(mono, id: RouteID("route.mono"))
        #expect(both.proposedRoutes.map(\.id.rawValue) == ["route.user", "route.mono"])
        try Fixture.expectValid(both, over: document)
    }

    @Test func choicesFromAnotherProposalAreRefused() throws {
        let proposal = try Fixture.proposal([Fixture.role("role.mains")], [Fixture.device("dev.a", outputs: 3)])
        let wider = try Fixture.proposal([Fixture.role("role.mains"), Fixture.role("role.other")],
                                         [Fixture.device("dev.a", outputs: 3), Fixture.device("dev.z", outputs: 2)])
        let foreign = try #require(Fixture.candidates(wider, "role.mains")?.candidates.last)
        #expect(foreign.device.rawValue == "dev.z")
        #expect(throws: RigMappingRefusal.candidateNotOffered(foreign)) {
            try proposal.choosing(foreign, id: RouteID("route.user"))
        }
        let other = try #require(Fixture.candidates(wider, "role.other")?.candidates.first)
        let otherID = try RoleID("role.other")
        #expect(throws: RigMappingRefusal.unknownRole(otherID)) {
            try proposal.choosing(other, id: RouteID("route.user"))
        }
    }

    @Test func nonAudioRolesAreSkippedExplicitly() throws {
        let roles = try [
            Fixture.role("role.midi", .input, channels: nil, signal: .midi),
            Fixture.role("role.ctl", .output, channels: 2, signal: .control),
            Fixture.role("role.clock", .output, channels: nil, signal: .clock)
        ]
        let proposal = try Fixture.proposal(roles, [Fixture.device("dev.a", inputs: 8, outputs: 8)])
        #expect(proposal.skipped.map(\.rawValue) == ["role.clock", "role.ctl", "role.midi"])
        #expect(Fixture.outcome(proposal, "role.ctl") == .skipped(.control))
        #expect(Fixture.outcome(proposal, "role.midi") == .skipped(.midi))
        #expect(proposal.requirements.isEmpty && proposal.proposedRoutes.isEmpty && proposal.unmapped.isEmpty)
    }

    @Test func audioRolesWithoutAValidChannelCountAreUnmapped() throws {
        let roles = try [Fixture.role("role.legacy", channels: nil), Fixture.role("role.huge", channels: 65),
                         Fixture.role("role.none", channels: 0)]
        let proposal = try Fixture.proposal(roles, [Fixture.device("dev.a", outputs: 128)])
        #expect(Fixture.outcome(proposal, "role.legacy") == .unmapped(.unconfirmedChannelCount))
        #expect(Fixture.outcome(proposal, "role.huge") == .unmapped(.invalidChannelCount(65)))
        #expect(Fixture.outcome(proposal, "role.none") == .unmapped(.invalidChannelCount(0)))
        #expect(proposal.unmapped.map(\.rawValue) == ["role.huge", "role.legacy", "role.none"])
        #expect(proposal.requirements.isEmpty)
    }

    @Test func malformedInputsAreRefused() throws {
        let devices = try [Fixture.device("dev.a", outputs: 2)]
        let mainsID = try RoleID("role.mains")
        #expect(throws: RigMappingRefusal.duplicateRole(mainsID)) {
            try Fixture.proposal([Fixture.role("role.mains"), Fixture.role("role.mains", channels: 1)], devices)
        }
        let many = try (0...RigMappingLimits.roles).map { try Fixture.role("role.\($0)") }
        #expect(throws: RigMappingRefusal.tooManyRoles(count: many.count, maximum: 4_096)) {
            try Fixture.proposal(many, devices)
        }
        let atLimit = try Fixture.proposal(Array(many.dropLast()), devices)
        #expect(atLimit.mappings.count == 4_096)
        var document = try Fixture.document(devices)
        document.routes = try [Fixture.route("route.x", role: "role.mains", device: "dev.nowhere", binding: .proposed)]
        let mains = try [Fixture.role("role.mains")]
        do {
            _ = try RigMappingProposal.make(roles: mains, devices: document)
            Issue.record("expected invalidDevices")
        } catch {
            guard case .invalidDevices = error else {
                Issue.record("unexpected refusal \(error)")
                return
            }
        }
    }
}
