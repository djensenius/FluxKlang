import Testing
@testable import FluxKlang

private let required = CapabilitySnapshotFixture.requiredCapability
private let advisory = CapabilitySnapshotFixture.advisoryCapability
private let graphNode = NodeID(validated: "fx.node")

/// One node that needs the required capability and would like the advisory one.
private func graph() -> GraphDocument {
    GraphDocument(
        id: GraphID(validated: "fx.graph"),
        capabilities: [
            CapabilityDefinition(id: required, label: "Required"),
            CapabilityDefinition(id: advisory, label: "Advisory")
        ],
        nodes: [GraphNode(
            id: graphNode, kind: .plugin, label: "Processor",
            requiredCapabilities: [required], advisoryCapabilities: [advisory]
        )]
    )
}

/// The same intent formed again at `host`, as a caller does after observing a new epoch.
private func reformed(_ intent: CommandIntent, at host: HostEpoch) throws -> CommandIntent {
    try CommandIntent(.init(
        id: intent.id, commandClass: intent.commandClass, origin: intent.origin, hostEpoch: host,
        connectionEpoch: intent.connectionEpoch, revisions: intent.revisions, operation: intent.operation,
        permission: intent.permission
    ))
}

extension ContractFixtureTests {
    struct Capabilities {
        @Test func availableSnapshotSatisfiesRequirements() throws {
            let snapshot = try CapabilitySnapshotFixture.make(.available)
            let assessment = try snapshot.document.assess(snapshot.requirements)
            #expect(assessment.requirementsSatisfied)
            #expect(assessment.missingRequired.isEmpty && assessment.missingAdvisory.isEmpty)
            #expect(snapshot.document.hostEpoch == snapshot.currentHostEpoch)
            #expect(Set(snapshot.requirements.map(\.capability)) == [required, advisory])
            try graph().validateForPreparation(supportedCapabilities: snapshot.supportedCapabilities)
        }

        @Test func missingSnapshotSeparatesRequiredFromAdvisory() throws {
            let snapshot = try CapabilitySnapshotFixture.make(.missing)
            let document = snapshot.document
            let assessment = try document.assess(snapshot.requirements)
            #expect(!assessment.requirementsSatisfied)
            #expect(assessment.missingRequired == [required] && assessment.missingAdvisory == [advisory])
            // A missing device still lists what it advertised; only presence makes it unavailable.
            #expect(document.devices.contains { $0.presence == .missing && $0.capabilities.contains(required) })

            let advisoryOnly = snapshot.requirements.filter { $0.level == .advisory }
            let degraded = try document.assess(advisoryOnly)
            #expect(degraded.requirementsSatisfied && degraded.missingAdvisory == [advisory])
            let requiredOnly = snapshot.requirements.filter { $0.level == .required }
            let blocked = try document.assess(requiredOnly)
            #expect(!blocked.requirementsSatisfied && blocked.missingAdvisory.isEmpty)
        }

        @Test func staleSnapshotIsDetectableByHostEpochAndPresence() throws {
            let stale = try CapabilitySnapshotFixture.make(.stale)
            #expect(stale.document.hostEpoch != stale.currentHostEpoch)
            #expect(try stale.document.hostEpoch.next() == stale.currentHostEpoch)
            #expect(stale.document.devices.allSatisfy { $0.presence == .stale })
            let assessment = try stale.document.assess(stale.requirements)
            #expect(assessment.missingRequired == [required] && assessment.missingAdvisory == [advisory])
            #expect(stale.supportedCapabilities.isEmpty)

            for state in ContractFixtureState.allCases where state != .stale {
                let snapshot = try CapabilitySnapshotFixture.make(state)
                #expect(snapshot.document.hostEpoch == snapshot.currentHostEpoch, "\(state)")
                #expect(snapshot.document.devices.allSatisfy { $0.presence != .stale }, "\(state)")
            }
        }

        @Test(arguments: ContractFixtureState.allCases)
        func missingCapabilityRejectsGraphPreparation(state: ContractFixtureState) throws {
            let snapshot = try CapabilitySnapshotFixture.make(state)
            let supported = snapshot.supportedCapabilities
            switch state {
            case .available, .pressured:
                try graph().validateForPreparation(supportedCapabilities: supported)
            case .missing, .stale, .failed:
                #expect(throws: GraphValidationError.unsupportedRequiredCapability(node: graphNode, required)) {
                    try graph().validateForPreparation(supportedCapabilities: supported)
                }
            }
            // Losing only the advisory capability never blocks preparation.
            try graph().validateForPreparation(supportedCapabilities: [required])
        }

        @Test(arguments: ControlClass.allCases)
        func staleContextRefusesWithStaleHostEpoch(controlClass: ControlClass) throws {
            let context = try AdmissionContextFixture.context(.stale, controlClass: controlClass)
            let intent = try AdmissionContextFixture.intent(.stale, controlClass: controlClass)
            #expect(CommandAdmission.admit(intent, in: context) == .refused(.stale(.hostEpoch)))

            // Re-forming the intent at the current epoch is admitted; admission never consults capabilities.
            let current = try reformed(intent, at: context.hostEpoch)
            #expect(CommandAdmission.admit(current, in: context) == .admitted)
            for state in ContractFixtureState.allCases where state != .stale {
                let context = try AdmissionContextFixture.context(state, controlClass: controlClass)
                let intent = try AdmissionContextFixture.intent(state, controlClass: controlClass)
                #expect(CommandAdmission.admit(intent, in: context) == .admitted, "\(state)")
            }
        }

        @Test(arguments: ControlClass.allCases)
        func deniedPermissionRefusesEveryClass(controlClass: ControlClass) throws {
            let other = PermissionFingerprint(rawValue: "fx.permission.other")
            for state in ContractFixtureState.allCases where state != .stale {
                let denied = try AdmissionContextFixture.context(state, controlClass: controlClass, permission: nil)
                let intent = try AdmissionContextFixture.intent(state, controlClass: controlClass)
                #expect(CommandAdmission.admit(intent, in: denied) == .refused(.rejected(.permissionDenied)))
                let changed = try AdmissionContextFixture.context(state, controlClass: controlClass, permission: other)
                #expect(CommandAdmission.admit(intent, in: changed) == .refused(.rejected(.permissionChanged)))
            }
            // Staleness is checked before permission.
            let stale = try AdmissionContextFixture.context(.stale, controlClass: controlClass, permission: nil)
            let intent = try AdmissionContextFixture.intent(.stale, controlClass: controlClass)
            #expect(CommandAdmission.admit(intent, in: stale) == .refused(.stale(.hostEpoch)))
        }

        @Test(arguments: ContractFixtureState.allCases)
        func snapshotsStayWithinDeviceCapabilityLimits(state: ContractFixtureState) throws {
            let snapshot = try CapabilitySnapshotFixture.make(state)
            #expect(try CapabilitySnapshotFixture.make(state) == snapshot)
            let document = snapshot.document
            try document.validate()
            #expect(document.devices.count <= DeviceCapabilityLimits.devices)
            #expect(document.routes.count <= DeviceCapabilityLimits.routes)
            #expect(document.devices.allSatisfy {
                $0.capabilities.count <= DeviceCapabilityLimits.capabilitiesPerDevice
            })
            let data = try document.encoded()
            #expect(try DeviceCapabilityDocument.decode(from: data) == document)

            guard state == .pressured else { return }
            // Pressured sits exactly at the per-device bound; one more advertisement is refused.
            let limit = DeviceCapabilityLimits.capabilitiesPerDevice
            var over = document
            let index = try #require(over.devices.firstIndex { $0.capabilities.count == limit })
            over.devices[index].capabilities.append(CapabilityID(validated: "fx.capability.over"))
            let path = "$.devices[\(over.devices[index].id)].capabilities"
            #expect(throws: DeviceCapabilityLimitError.exceeded(path: path, maximum: limit)) {
                try over.validate()
            }
            #expect(throws: DeviceCapabilityLimitError.exceeded(path: path, maximum: limit)) {
                try over.encoded()
            }
        }

        @Test(arguments: ContractFixtureState.allCases)
        func supportedCapabilitiesAgreeWithAssessment(state: ContractFixtureState) throws {
            let snapshot = try CapabilitySnapshotFixture.make(state)
            let requiredCapabilities = Set(snapshot.requirements.filter { $0.level == .required }.map(\.capability))
            let assessment = try snapshot.document.assess(snapshot.requirements)
            #expect(assessment.missingRequired == requiredCapabilities.subtracting(snapshot.supportedCapabilities))
        }

        @Test func failedSnapshotIsPresentButAdvertisesNothing() throws {
            let failed = try CapabilitySnapshotFixture.make(.failed)
            #expect(failed.document.hostEpoch == failed.currentHostEpoch)
            #expect(failed.document.devices.allSatisfy {
                $0.presence == .present && $0.binding == .unverified && $0.capabilities.isEmpty
            })
            let assessment = try failed.document.assess(failed.requirements)
            #expect(assessment.missingRequired == [required] && assessment.missingAdvisory == [advisory])
        }
    }
}
