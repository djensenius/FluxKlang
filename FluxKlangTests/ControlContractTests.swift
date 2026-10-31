import Foundation
import Testing
@testable import FluxKlang

struct ControlContractTests {}

private let host = HostID(validated: "host.test")
private let device = DeviceID(validated: "dev.test")
private let role = RoleID(validated: "role.mains")
private let capability = CapabilityID(validated: "cap.audio")

private func interface() throws -> DeviceDescriptor {
    try DeviceDescriptor(
        id: device, kind: .audioInterface,
        layout: ChannelLayout(inputs: 2, outputs: 4, sampleRate: 48_000), binding: .measured,
        identity: DeviceIdentity(.init(uid: "physical-device-123", evidence: [.deviceUID, .channelLayout])),
        evidence: "confirmed-readback", capabilities: [capability]
    )
}

private func route(channels: [Int] = [0, 1]) -> AudioRoute {
    var route = AudioRoute(id: RouteID(validated: "route.mains"), role: role, device: device,
                           direction: .output, channels: channels, binding: .confirmed)
    route.confirmedHost = host
    route.confirmedEpoch = .initial
    route.confirmedDeviceUID = "physical-device-123"
    route.evidence = "human-confirmed-port-map"
    return route
}

private func document() throws -> DeviceCapabilityDocument {
    try DeviceCapabilityDocument(revision: .initial, host: host, hostEpoch: .initial,
                                 devices: [interface()], routes: [route()])
}

private let roles = [role: RouteRoleRequirement(direction: .output, channelCount: 2)]

extension ControlContractTests {
    struct Devices {
        @Test func identityRequiresPerDeviceEvidence() throws {
            #expect(throws: ControlValidationError.self) {
                try DeviceIdentity(.init(uid: "same-model", evidence: [.modelUID]))
            }
            #expect(throws: ControlValidationError.self) {
                try DeviceIdentity(.init(uid: " ", evidence: [.deviceUID]))
            }
            var measured = try interface()
            measured.evidence = nil
            #expect(throws: ControlValidationError.self) { try measured.validate() }
        }

        @Test func measuredAndRequestedRatesNeverBecomeEachOther() throws {
            var descriptor = try interface()
            descriptor.requestedRate = 96_000
            #expect(descriptor.layout?.sampleRate == 48_000 && descriptor.actualRate == nil)
            descriptor.actualRate = try MeasuredRate(.init(hertz: 48_001, evidence: "loopback-measurement"))
            #expect(descriptor.actualRate?.hertz == 48_001 && descriptor.requestedRate == 96_000)
            descriptor.presence = .stale
            #expect(throws: ControlValidationError.self) { try descriptor.validate() }
            #expect(throws: ControlValidationError.self) {
                try MeasuredRate(.init(hertz: .nan, evidence: "measurement"))
            }
        }

        @Test func onlyCurrentHostLocalEvidenceConfirmsRoutes() throws {
            var value = try document()
            try value.validate(roles: roles)
            value.routes[0].confirmedEpoch = try Generation.initial.next()
            #expect(throws: ControlValidationError.self) { try value.validate(roles: roles) }
            value.routes[0] = route()
            value.routes[0].confirmedHost = HostID(validated: "host.other")
            #expect(throws: ControlValidationError.self) { try value.validate(roles: roles) }
            value.routes[0] = route()
            value.routes[0].confirmedDeviceUID = "same-model-different-unit"
            #expect(throws: ControlValidationError.self) { try value.validate(roles: roles) }
            value.routes[0] = route()
            value.devices[0].presence = .missing
            value.devices[0].binding = .reported
            #expect(throws: ControlValidationError.self) { try value.validate(roles: roles) }
        }

        @Test func channelAndCompatibleRoleEditsRequireFreshConfirmation() throws {
            let otherRole = RoleID(validated: "role.monitors")
            var compatibleRoles = roles
            compatibleRoles[otherRole] = RouteRoleRequirement(direction: .output, channelCount: 2)
            let edits: [(inout AudioRoute) -> Void] = [
                { $0.channels = [2, 3] },
                { $0.role = otherRole }
            ]
            for edit in edits {
                var value = try document()
                value.routes[0].unknownFields["futureRoute"] = .bool(true)
                edit(&value.routes[0])
                try value.validate(roles: compatibleRoles)
                #expect(value.routes[0].binding == .proposed)
                #expect(value.routes[0].confirmedHost == nil && value.routes[0].confirmedEpoch == nil)
                #expect(value.routes[0].confirmedDeviceUID == nil && value.routes[0].evidence == nil)
                #expect(value.routes[0].unknownFields["futureRoute"] == .bool(true))
                let decoded = try DeviceCapabilityDocument.decode(from: ContractCoding.makeEncoder().encode(value))
                #expect(decoded == value)
                value.routes[0].binding = .confirmed
                #expect(throws: ControlValidationError.self) {
                    try ContractCoding.makeEncoder().encode(value)
                }
                value.routes[0].confirmedHost = host
                value.routes[0].confirmedEpoch = .initial
                value.routes[0].confirmedDeviceUID = "physical-device-123"
                value.routes[0].evidence = "fresh-review-of-edited-route"
                try value.validate(roles: compatibleRoles)
                #expect(try DeviceCapabilityDocument.decode(from: ContractCoding.makeEncoder().encode(value)) == value)
            }
        }

        @Test func constructionAndEncodingRejectIntrinsicErrorsAfterMutation() throws {
            let edits: [(inout DeviceCapabilityDocument) -> Void] = [
                { $0.routes[0].channels = [-1, 0] },
                { $0.routes[0].channels = [3, 4] },
                { $0.routes[0].channels = [1, 1] },
                { $0.routes[0].channels = [] },
                { $0.routes[0].evidence = nil },
                { $0.routes[0].confirmedHost = nil },
                { $0.routes[0].confirmedEpoch = nil },
                { $0.routes[0].confirmedDeviceUID = nil },
                { $0.devices.append($0.devices[0]) },
                { $0.routes.append($0.routes[0]) },
                { $0.routes[0].device = DeviceID(validated: "dev.unknown") },
                { $0.devices[0].layout = nil }
            ]
            for edit in edits {
                var value = try document()
                edit(&value)
                #expect(throws: (any Error).self) {
                    try ContractCoding.makeEncoder().encode(value)
                }
                #expect(throws: (any Error).self) {
                    try DeviceCapabilityDocument(revision: value.revision, host: value.host,
                                                 hostEpoch: value.hostEpoch,
                                                 devices: value.devices, routes: value.routes)
                }
            }
        }

        @Test func decodingRejectsIntrinsicErrorsWithoutARoleCatalog() throws {
            let data = try ContractCoding.makeEncoder().encode(document())
            let original = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let devices = try #require(original["devices"] as? [[String: Any]])
            let originalRoutes = try #require(original["routes"] as? [[String: Any]])
            var invalidRoutes: [[String: Any]] = []
            for channels in [[-1, 0], [3, 4], [1, 1], []] {
                var invalid = originalRoutes[0]
                invalid["channels"] = channels
                invalidRoutes.append(invalid)
            }
            for key in ["confirmedHost", "confirmedEpoch", "confirmedDeviceUID", "evidence"] {
                var invalid = originalRoutes[0]
                invalid.removeValue(forKey: key)
                invalidRoutes.append(invalid)
            }
            var invalidDevice = originalRoutes[0]
            invalidDevice["device"] = "dev.unknown"
            invalidRoutes.append(invalidDevice)
            var malformed = invalidRoutes.map { invalid in
                var object = original
                object["routes"] = [invalid]
                return object
            }
            var duplicateDevices = original
            duplicateDevices["devices"] = devices + devices
            malformed.append(duplicateDevices)
            var duplicateRoutes = original
            duplicateRoutes["routes"] = originalRoutes + originalRoutes
            malformed.append(duplicateRoutes)
            for object in malformed {
                #expect(throws: (any Error).self) {
                    try DeviceCapabilityDocument.decode(from: JSONSerialization.data(withJSONObject: object))
                }
            }
        }

        @Test func roleChecksStayContextualAndBindingStatesRoundTripExplicitly() throws {
            for binding in RouteBinding.allCases {
                var value = try document()
                value.routes[0].binding = binding
                value.routes[0].unknownFields["futureRoute"] = .object(["metadata": .bool(true)])
                let decoded = try DeviceCapabilityDocument.decode(from: ContractCoding.makeEncoder().encode(value))
                #expect(decoded == value && decoded.routes[0].binding == binding)
                var unchanged = decoded.routes[0]
                unchanged.channels = value.routes[0].channels
                unchanged.role = value.routes[0].role
                #expect(unchanged == decoded.routes[0])
                unchanged.channels.swapAt(0, 1)
                #expect(unchanged.binding == (binding == .confirmed ? .proposed : binding))
                #expect(unchanged.confirmedHost == nil && unchanged.evidence == nil)
                #expect(unchanged.unknownFields == decoded.routes[0].unknownFields)
                #expect(throws: RouteValidationError.unknownRole(value.routes[0].id, role)) {
                    try decoded.validate(roles: [:])
                }
                #expect(throws: RouteValidationError.self) {
                    try decoded.validate(roles: [role: .init(direction: .input, channelCount: 2)])
                }
                #expect(throws: RouteValidationError.self) {
                    try decoded.validate(roles: [role: .init(direction: .output, channelCount: 1)])
                }
                try decoded.validate(roles: roles)
            }
        }

        @Test func proposedAndConfirmedRoutesRespectCountsDirectionAndBounds() throws {
            let layout = try interface().layout
            let requirement = try #require(roles[role])
            for channels in [[-1, 0], [3, 4], [0], [1, 1]] {
                var invalid = route(channels: channels)
                invalid.binding = .proposed
                #expect(throws: RouteValidationError.self) { try invalid.validate(layout: layout, role: requirement) }
            }
            var wrongDirection = route()
            wrongDirection.direction = .input
            #expect(throws: RouteValidationError.self) {
                try wrongDirection.validate(layout: layout, role: requirement)
            }
            #expect(throws: ChannelLayoutError.self) {
                try ChannelLayout(inputs: -1, outputs: 2, sampleRate: 48_000)
            }
        }

        @Test func capabilityRequirementsAndAdvisoriesDiffer() throws {
            var value = try document()
            let missing = CapabilityID(validated: "cap.missing")
            let assessment = try value.assess([
                CapabilityRequirement(capability: capability, level: .required),
                CapabilityRequirement(capability: missing, level: .advisory)
            ])
            #expect(assessment.requirementsSatisfied && assessment.missingAdvisory == [missing])
            value.devices[0].presence = .missing
            value.devices[0].binding = .reported
            #expect(try !value.assess([.init(capability: capability, level: .required)]).requirementsSatisfied)
            #expect(throws: DuplicateIDError.self) {
                try value.assess([.init(capability: missing, level: .required),
                                  .init(capability: missing, level: .advisory)])
            }
        }

        @Test func nestedUnknownFieldsRoundTripAndRequiredFeaturesFail() throws {
            let data = try ContractCoding.makeEncoder().encode(document())
            var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            var devices = try #require(object["devices"] as? [[String: Any]])
            var layout = try #require(devices[0]["layout"] as? [String: Any])
            layout["futureClockMetadata"] = ["source": "observed"]
            devices[0]["layout"] = layout
            object["devices"] = devices
            object["future"] = true
            let decoded = try DeviceCapabilityDocument.decode(from: JSONSerialization.data(withJSONObject: object))
            #expect(decoded.devices[0].layout?.unknownFields["futureClockMetadata"] != nil)
            #expect(decoded.unknownFields["future"] == .bool(true))
            let roundTrip = try DeviceCapabilityDocument.decode(from: ContractCoding.makeEncoder().encode(decoded))
            #expect(roundTrip == decoded)
            object["requiredFeatures"] = ["future-routing"]
            #expect(throws: ControlValidationError.self) {
                try DeviceCapabilityDocument.decode(from: JSONSerialization.data(withJSONObject: object))
            }
        }
    }

    struct Parameters {
        @Test func descriptorBoundsDefaultsClassesAndRampsValidate() throws {
            let ramp = try ParameterRamp(.init(kind: .linear, minimumMilliseconds: 10, maximumMilliseconds: 100))
            let descriptor = try ParameterDescriptor(.init(
                id: ParameterID(validated: "param.mix"), unit: .normalized, lower: 0, upper: 1, defaultValue: 0.5,
                ceiling: 0.8, curve: .linear, ramp: ramp, controlClass: .live, verification: .reported
            ))
            try descriptor.check(.init(value: 0.6, unit: .normalized), rampMilliseconds: 50)
            #expect(throws: ParameterValueError.invalidRamp) {
                try descriptor.check(.init(value: 0.6, unit: .normalized), rampMilliseconds: 101)
            }
            #expect(throws: ParameterValueError.nonFinite) {
                try descriptor.check(.init(value: 0.6, unit: .normalized), ceiling: .nan)
            }
            #expect(throws: ControlValidationError.self) {
                try ParameterRamp(.init(kind: .linear, minimumMilliseconds: -1, maximumMilliseconds: 100))
            }
            for (lower, upper, ceiling) in [(2.0, 1.0, 1.0), (0, 1, Double.nan), (0, 1, 2)] {
                #expect(throws: ControlValidationError.self) {
                    try ParameterDescriptor(.init(
                        id: descriptor.id, unit: .normalized, lower: lower, upper: upper, defaultValue: 0.5,
                        ceiling: ceiling, curve: .linear, ramp: ramp, controlClass: .live, verification: .reported
                    ))
                }
            }
        }

        @Test func catalogsRejectDuplicatesAndUnsafeValues() throws {
            let fader = try #require(ParameterCatalog.wing[ParameterCatalog.wingFaderDecibels])
            #expect(throws: DuplicateIDError.self) { try ParameterCatalog([fader, fader]) }
            for value in [Double.nan, .infinity, -91, 11] {
                #expect(throws: ParameterValueError.self) { try fader.check(.init(value: value, unit: .decibels)) }
            }
            #expect(throws: ParameterValueError.self) {
                try fader.check(.init(value: 1, unit: .decibels), ceiling: 0)
            }
            let colour = try #require(ParameterCatalog.wing[ParameterCatalog.wingColour])
            #expect(throws: ParameterValueError.notIntegral(1.5)) {
                try colour.check(.init(value: 1.5, unit: .index))
            }
        }

        @Test func catalogEnvelopePreservesOptionalFieldsAndRejectsFutureVersion() throws {
            var envelope = try ParameterCatalogDocument(revision: .initial, payload: .wing)
            envelope.unknownFields["future"] = .bool(true)
            let data = try ContractCoding.makeEncoder().encode(envelope)
            #expect(try ContractCoding.decode(ParameterCatalogDocument.self, from: data) == envelope)
            let text = try #require(String(data: data, encoding: .utf8))
            let json = text.replacingOccurrences(of: "\"version\":1", with: "\"version\":2")
            #expect(throws: ContractVersionError.self) {
                try ContractCoding.decode(ParameterCatalogDocument.self, from: Data(json.utf8))
            }
        }
    }
}
