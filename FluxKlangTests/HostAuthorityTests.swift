import Foundation
import Testing
@testable import FluxKlang

struct HostAuthorityTests {}

private let host = HostID(validated: "host.authority")
private let hostEpoch = HostEpoch(host: host, generation: .initial)
private let permission = PermissionFingerprint(rawValue: "permissions.current")
private let graphID = GraphID(validated: "graph.main")
private let required = CapabilityID(validated: "cap.audio")
private let advisory = CapabilityID(validated: "cap.meter")
private let digest = ActivationDigest(rawValue: "sha256:activation")

private func nextEpoch() throws -> HostEpoch {
    HostEpoch(host: host, generation: try Generation.initial.next())
}

private func device(capabilities: [CapabilityID], presence: DevicePresence = .present) throws -> DeviceDescriptor {
    try DeviceDescriptor(
        id: DeviceID(validated: "dev.interface"), kind: .audioInterface,
        layout: ChannelLayout(inputs: 2, outputs: 2, sampleRate: 48_000), binding: .reported,
        identity: DeviceIdentity(.init(uid: "physical-interface-1", evidence: [.deviceUID])),
        presence: presence, capabilities: capabilities
    )
}

private func capabilities(_ ids: [CapabilityID] = [required, advisory], presence: DevicePresence = .present,
                          host documentHost: HostID = host,
                          epoch: Generation = .initial) throws -> DeviceCapabilityDocument {
    try DeviceCapabilityDocument(revision: .initial, host: documentHost, hostEpoch: epoch,
                                 devices: [device(capabilities: ids, presence: presence)], routes: [])
}

private func candidate(requiresReview: Bool = false) -> GraphDocument {
    GraphDocument(
        id: graphID, revision: .initial,
        capabilities: [CapabilityDefinition(id: required, label: "Audio"),
                       CapabilityDefinition(id: advisory, label: "Meter")],
        nodes: [GraphNode(id: NodeID(validated: "node.fx"), kind: .plugin, label: "FX",
                          requiredCapabilities: [required], advisoryCapabilities: [advisory])],
        requiresReview: requiresReview
    )
}

private func request(epoch: HostEpoch = hostEpoch, permission requested: PermissionFingerprint = permission,
                     base: ContractRevision = .initial, digest requestedDigest: ActivationDigest = digest,
                     origin: CommandOrigin = .human) -> ActivationRequest {
    ActivationRequest(draft: DraftID(validated: "draft.main"), graph: graphID, baseRevision: base,
                      hostEpoch: epoch, permission: requested, digest: requestedDigest, origin: origin)
}

private func context(permission current: PermissionFingerprint? = permission,
                     capabilities document: DeviceCapabilityDocument? = nil) throws -> ActivationContext {
    ActivationContext(hostEpoch: hostEpoch, activeRevision: .initial, permission: current,
                      capabilities: try document ?? capabilities())
}

private func rejection(_ result: Result<ValidatedActivation, ActivationRejection>) -> ActivationRejection? {
    if case .failure(let reason) = result { return reason }
    return nil
}

extension HostAuthorityTests {
    struct Validation {
        @Test func currentRequestValidates() throws {
            let current = request()
            let checked = try context()
            let result = ActivationValidator.validate(current, candidate: candidate(), in: checked)
            let validated = try result.get()
            #expect(validated.request == current)
            #expect(validated.graph == candidate())
            #expect(validated.missingAdvisory.isEmpty)
            // H3 compares this against the live context to detect staleness.
            #expect(validated.context == checked)
        }

        @Test func staleHostEpochIsRejectedFirst() throws {
            // Every later check also fails, so the epoch must win.
            let everythingWrong = ActivationRequest(
                draft: DraftID(validated: "draft.main"), graph: GraphID(validated: "graph.other"),
                baseRevision: try ContractRevision(9), hostEpoch: try nextEpoch(),
                permission: PermissionFingerprint(rawValue: "permissions.old"),
                digest: ActivationDigest(rawValue: ""), origin: .assistant
            )
            let stale = try capabilities([], host: HostID(validated: "host.other"))
            let current = try context(permission: nil, capabilities: stale)
            let result = ActivationValidator.validate(everythingWrong, candidate: candidate(requiresReview: true),
                                                      in: current)
            #expect(rejection(result) == .staleHostEpoch)
            #expect(rejection(ActivationValidator.validate(request(epoch: HostEpoch(
                host: HostID(validated: "host.other"), generation: .initial
            )), candidate: candidate(), in: try context())) == .staleHostEpoch)
        }

        @Test func checksFollowCommandAdmissionOrder() throws {
            let other = PermissionFingerprint(rawValue: "permissions.old")
            let wrongBase = try ContractRevision(3)
            let empty = ActivationDigest(rawValue: "")
            let current = try context()
            #expect(rejection(ActivationValidator.validate(
                request(permission: other, base: wrongBase, digest: empty, origin: .controller),
                candidate: candidate(requiresReview: true), in: current
            )) == .permissionChanged)
            #expect(rejection(ActivationValidator.validate(
                request(base: wrongBase, digest: empty, origin: .controller),
                candidate: candidate(requiresReview: true), in: current
            )) == .originCannotActivate(.controller))
            #expect(rejection(ActivationValidator.validate(
                request(base: wrongBase, digest: empty), candidate: candidate(requiresReview: true), in: current
            )) == .invalidDigest)
            #expect(rejection(ActivationValidator.validate(
                request(base: wrongBase), candidate: candidate(requiresReview: true), in: current
            )) == .staleBase(expected: .initial, found: wrongBase))
            #expect(rejection(ActivationValidator.validate(
                request(), candidate: candidate(requiresReview: true), in: current
            )) == .invalidGraph(.reviewRequired))
        }

        @Test func staleBaseReportsExpectedAndFound() throws {
            let found = try ContractRevision.initial.next()
            let result = ActivationValidator.validate(request(base: found), candidate: candidate(), in: try context())
            #expect(rejection(result) == .staleBase(expected: .initial, found: found))
        }

        @Test func graphOtherThanRequestedIsMismatched() throws {
            var other = candidate()
            other.id = GraphID(validated: "graph.other")
            #expect(rejection(ActivationValidator.validate(request(), candidate: other, in: try context()))
                == .graphMismatch)
        }

        @Test func missingOrChangedPermissionIsRejected() throws {
            #expect(rejection(ActivationValidator.validate(
                request(), candidate: candidate(), in: try context(permission: nil)
            )) == .permissionDenied)
            #expect(rejection(ActivationValidator.validate(
                request(permission: PermissionFingerprint(rawValue: "permissions.old")),
                candidate: candidate(), in: try context()
            )) == .permissionChanged)
        }

        @Test(arguments: [CommandOrigin.assistant, .controller])
        func assistantAndControllerOriginsCannotActivate(origin: CommandOrigin) throws {
            // Current epoch, permission, base and graph: only the origin is wrong.
            let result = ActivationValidator.validate(request(origin: origin), candidate: candidate(),
                                                      in: try context())
            #expect(rejection(result) == .originCannotActivate(origin))
        }

        @Test func localHumanOriginGainsNoPrivilegeWithoutCurrentPermission() throws {
            let human = request(origin: .human)
            #expect(rejection(ActivationValidator.validate(
                human, candidate: candidate(), in: try context(permission: nil)
            )) == .permissionDenied)
            #expect(rejection(ActivationValidator.validate(
                request(permission: PermissionFingerprint(rawValue: "permissions.old"), origin: .human),
                candidate: candidate(), in: try context()
            )) == .permissionChanged)
            #expect(rejection(ActivationValidator.validate(
                request(epoch: try nextEpoch(), origin: .human), candidate: candidate(), in: try context()
            )) == .staleHostEpoch)
        }

        @Test func invalidGraphReturnsValidationError() throws {
            var dangling = candidate()
            dangling.nodes[0].requiredCapabilities.append(CapabilityID(validated: "cap.undefined"))
            #expect(rejection(ActivationValidator.validate(request(), candidate: dangling, in: try context()))
                == .invalidGraph(.undefinedCapability(node: NodeID(validated: "node.fx"),
                                                      CapabilityID(validated: "cap.undefined"))))
            // A required capability the host never advertises is not supported for preparation.
            let unsupported = try context(capabilities: capabilities([advisory]))
            #expect(rejection(ActivationValidator.validate(request(), candidate: candidate(), in: unsupported))
                == .invalidGraph(.unsupportedRequiredCapability(node: NodeID(validated: "node.fx"), required)))
        }

        @Test func missingRequiredCapabilityRejectsButAdvisoryDoesNot() throws {
            // Advertised by the host, but the only device providing it is not present.
            let absent = try context(capabilities: capabilities(presence: .missing))
            #expect(rejection(ActivationValidator.validate(request(), candidate: candidate(), in: absent))
                == .missingCapabilities([required]))
            let degraded = try context(capabilities: capabilities([required]))
            let validated = try ActivationValidator.validate(request(), candidate: candidate(), in: degraded).get()
            #expect(validated.missingAdvisory == [advisory])
        }

        @Test func capabilityDocumentFromOtherHostEpochIsStale() throws {
            let oldEpoch = try context(capabilities: capabilities(epoch: try Generation.initial.next()))
            #expect(rejection(ActivationValidator.validate(request(), candidate: candidate(), in: oldEpoch))
                == .staleCapabilities)
            let otherHost = try context(capabilities: capabilities(host: HostID(validated: "host.other")))
            #expect(rejection(ActivationValidator.validate(request(), candidate: candidate(), in: otherHost))
                == .staleCapabilities)
        }

        @Test func invalidCapabilityDocumentIsRejected() throws {
            var document = try capabilities()
            document.devices[0].binding = .measured
            let result = ActivationValidator.validate(request(), candidate: candidate(),
                                                      in: try context(capabilities: document))
            #expect(rejection(result) == .invalidCapabilities)
        }

        @Test(arguments: ["", String(repeating: "a", count: 257), String(repeating: "é", count: 129)])
        func emptyOrOversizedDigestIsRejected(raw: String) throws {
            let result = ActivationValidator.validate(request(digest: ActivationDigest(rawValue: raw)),
                                                      candidate: candidate(), in: try context())
            #expect(rejection(result) == .invalidDigest)
        }

        @Test func digestAtByteLimitIsAccepted() throws {
            let edge = ActivationDigest(rawValue: String(repeating: "a", count: 256))
            #expect(edge.isValid)
            #expect(ActivationDigest(rawValue: "a").isValid)
            let result = ActivationValidator.validate(request(digest: edge), candidate: candidate(), in: try context())
            #expect(rejection(result) == nil)
        }

        @Test func staleCapabilityDocumentIsRejectedBeforeItIsUsed() throws {
            let next = try Generation.initial.next()
            // Stale and lacking the required capability: staleness wins over graph support.
            let lacking = try context(capabilities: capabilities([advisory], epoch: next))
            #expect(rejection(ActivationValidator.validate(request(), candidate: candidate(), in: lacking))
                == .staleCapabilities)
            // Stale and internally invalid: staleness wins over document validation.
            var invalid = try capabilities(host: HostID(validated: "host.other"))
            invalid.devices.append(invalid.devices[0])
            #expect(rejection(ActivationValidator.validate(
                request(), candidate: candidate(), in: try context(capabilities: invalid)
            )) == .staleCapabilities)
        }

        @Test func candidateRevisionMustEqualBase() throws {
            var drifted = candidate()
            drifted.revision = try ContractRevision.initial.next()
            #expect(rejection(ActivationValidator.validate(request(), candidate: drifted, in: try context()))
                == .staleBase(expected: .initial, found: drifted.revision))
        }

        @Test func capabilityRequiredOnOneNodeAndAdvisoryOnAnotherIsRequired() throws {
            var shared = candidate()
            shared.nodes.append(GraphNode(id: NodeID(validated: "node.meter"), kind: .plugin, label: "Meter",
                                          advisoryCapabilities: [required]))
            let validated = try ActivationValidator.validate(request(), candidate: shared, in: try context()).get()
            #expect(validated.missingAdvisory.isEmpty)
            let absent = try context(capabilities: capabilities(presence: .missing))
            #expect(rejection(ActivationValidator.validate(request(), candidate: shared, in: absent))
                == .missingCapabilities([required]))
        }

        @Test func capabilityDocumentIsFullyValidatedBeforeAssessment() throws {
            var duplicated = try capabilities()
            duplicated.devices.append(duplicated.devices[0])
            #expect(rejection(ActivationValidator.validate(
                request(), candidate: candidate(), in: try context(capabilities: duplicated)
            )) == .invalidCapabilities)
        }

        @Test(arguments: ["", String(repeating: "p", count: 257)])
        func malformedContextFingerprintIsNotGranted(raw: String) throws {
            let malformed = PermissionFingerprint(rawValue: raw)
            #expect(rejection(ActivationValidator.validate(
                request(permission: malformed), candidate: candidate(), in: try context(permission: malformed)
            )) == .permissionDenied)
        }

        @Test(arguments: ["", String(repeating: "p", count: 257)])
        func malformedRequestFingerprintIsRejected(raw: String) throws {
            #expect(rejection(ActivationValidator.validate(
                request(permission: PermissionFingerprint(rawValue: raw)), candidate: candidate(), in: try context()
            )) == .permissionChanged)
        }

        @Test func oversizedCanonicallyEqualRequestFingerprintIsRejected() throws {
            let composed = PermissionFingerprint(rawValue: String(repeating: "\u{E9}", count: 128))
            let decomposed = PermissionFingerprint(rawValue: String(repeating: "e\u{301}", count: 128))
            #expect(composed.rawValue.utf8.count == 256)
            #expect(decomposed.rawValue.utf8.count == 384)
            let result = ActivationValidator.validate(request(permission: decomposed), candidate: candidate(),
                                                      in: try context(permission: composed))
            #expect(rejection(result) == .permissionChanged)
            #expect((try? result.get()) == nil)
        }

        @Test func canonicallyEquivalentButByteDifferentFingerprintIsChanged() throws {
            let composed = PermissionFingerprint(rawValue: "permissions.caf\u{E9}")
            let decomposed = PermissionFingerprint(rawValue: "permissions.cafe\u{301}")
            #expect(decomposed.rawValue.utf8.count <= 256)
            #expect(rejection(ActivationValidator.validate(
                request(permission: decomposed), candidate: candidate(), in: try context(permission: composed)
            )) == .permissionChanged)
        }

        @Test func graphOverDocumentByteLimitIsRefused() throws {
            var unlabeled = candidate()
            unlabeled.label = ""
            // The empty label already encodes as `"label":""`, so each character adds one byte.
            let room = ProjectGraphLimits.documentBytes - (try unlabeled.encoded().count)
            var atLimit = unlabeled
            atLimit.label = String(repeating: "a", count: room)
            #expect(try atLimit.encoded().count == ProjectGraphLimits.documentBytes)
            #expect(rejection(ActivationValidator.validate(request(), candidate: atLimit, in: try context())) == nil)
            var oversized = unlabeled
            oversized.label = String(repeating: "a", count: room + 1)
            let result = ActivationValidator.validate(request(), candidate: oversized, in: try context())
            #expect(rejection(result) == .invalidGraph(.bounds(.exceeded(
                path: "$bytes", maximum: ProjectGraphLimits.documentBytes
            ))))
            #expect((try? result.get()) == nil)
        }

        @Test func capabilityDocumentOverByteLimitIsRefused() throws {
            var document = try capabilities()
            document.extensions = ["blob": .string(String(repeating: "a", count: DeviceCapabilityLimits.documentBytes))]
            let result = ActivationValidator.validate(request(), candidate: candidate(),
                                                      in: try context(capabilities: document))
            #expect(rejection(result) == .invalidCapabilities)
            #expect((try? result.get()) == nil)
        }

        @Test func unencodableGraphIsRefused() throws {
            var graph = candidate()
            graph.extensions = ["gain": .double(.infinity)]
            let result = ActivationValidator.validate(request(), candidate: graph, in: try context())
            #expect(rejection(result) == .unencodableGraph)
        }

        @Test func unencodableCapabilityDocumentIsRefused() throws {
            var document = try capabilities()
            document.extensions = ["gain": .double(.nan)]
            #expect(rejection(ActivationValidator.validate(
                request(), candidate: candidate(), in: try context(capabilities: document)
            )) == .invalidCapabilities)
        }
    }
}
