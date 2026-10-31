//
//  DeviceCapability.swift
//  FluxKlang
//
//  The host-local device capability contract (`fluxklang.devices` v1): which
//  devices a rig has, their channel layouts, how each binding was established,
//  and the audio routes that bind portable roles to device channels. Contracts
//  only: nothing here discovers, opens or configures a device.
//

import Foundation

enum DeviceTag: ContractIDTag {}
typealias DeviceID = ContractID<DeviceTag>
enum HostTag: ContractIDTag {}
typealias HostID = ContractID<HostTag>
enum ConnectionTag: ContractIDTag {}
typealias ConnectionID = ContractID<ConnectionTag>

enum IdentityEvidence: String, Codable, Hashable, Sendable {
    case deviceUID, endpointUID, transport, channelLayout, modelUID
}

struct DeviceIdentityFields: ControlFields {
    static let knownKeys: Set<String> = ["uid", "evidence"]
    let uid: String
    let evidence: Set<IdentityEvidence>

    func validate() throws {
        guard !uid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, uid.utf8.count <= 1024,
              !evidence.isDisjoint(with: [.deviceUID, .endpointUID]) else {
            throw ControlValidationError.invalid("Per-device UID evidence is required; modelUID is not identity")
        }
    }
}
typealias DeviceIdentity = ControlRecord<DeviceIdentityFields>

enum DevicePresence: String, Codable, Sendable { case present, missing, stale }

struct MeasuredRateFields: ControlFields {
    static let knownKeys: Set<String> = ["hertz", "evidence"]
    let hertz: Double
    let evidence: String

    func validate() throws {
        guard hertz.isFinite, (1...768_000).contains(hertz), !evidence.isEmpty else {
            throw ControlValidationError.invalid("Actual rate requires finite measurement and evidence")
        }
    }
}
typealias MeasuredRate = ControlRecord<MeasuredRateFields>

/// How a binding or value is known. Only `measured` has hardware evidence.
enum MeasurementStatus: String, Codable, Sendable, CaseIterable {
    /// Observed on the hardware (loopback, readback or console response).
    case measured
    /// Claimed by the device or OS, or by the shipping code, without measurement.
    case reported
    /// Not yet checked against hardware.
    case unverified
}

/// Why a channel layout is not valid.
enum ChannelLayoutError: Error, Equatable, Sendable {
    case invalidChannelCount(Int)
    case invalidSampleRate(Int)
}

/// A device's channel counts and nominal rate. Route channels are 0-based
/// indices (`0..<inputs` or `0..<outputs`); `position(ofIndex:)` gives the
/// 1-based position a console or interface shows (WING USB 1…48).
struct ChannelLayout: Hashable, Sendable, Codable {
    let inputs: Int
    let outputs: Int
    let sampleRate: Int
    var unknownFields: [String: JSONValue] = [:]

    /// WING USB audio: 48 × 48 channels at 48 kHz.
    static let wingUSB = ChannelLayout(uncheckedInputs: 48, outputs: 48, sampleRate: 48_000)

    init(inputs: Int, outputs: Int, sampleRate: Int) throws(ChannelLayoutError) {
        guard (0...4096).contains(inputs) else { throw .invalidChannelCount(inputs) }
        guard (0...4096).contains(outputs) else { throw .invalidChannelCount(outputs) }
        guard (1...768_000).contains(sampleRate) else { throw .invalidSampleRate(sampleRate) }
        self.init(uncheckedInputs: inputs, outputs: outputs, sampleRate: sampleRate)
    }

    private init(uncheckedInputs inputs: Int, outputs: Int, sampleRate: Int) {
        self.inputs = inputs
        self.outputs = outputs
        self.sampleRate = sampleRate
    }

    init(from decoder: any Decoder) throws {
        struct Raw: Decodable { let inputs: Int, outputs: Int, sampleRate: Int }
        let raw = try Raw(from: decoder)
        do {
            try self.init(inputs: raw.inputs, outputs: raw.outputs, sampleRate: raw.sampleRate)
        } catch {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath, debugDescription: "Invalid channel layout: \(error)"
            ))
        }
        unknownFields = try ExtensionFields.decode(from: decoder, knownKeys: ["inputs", "outputs", "sampleRate"])
    }

    func encode(to encoder: any Encoder) throws {
        struct Raw: Encodable { let inputs: Int, outputs: Int, sampleRate: Int }
        try Raw(inputs: inputs, outputs: outputs, sampleRate: sampleRate).encode(to: encoder)
        try ExtensionFields.encode(unknownFields, to: encoder, knownKeys: ["inputs", "outputs", "sampleRate"])
    }

    func channelCount(_ direction: RouteDirection) -> Int {
        direction == .input ? inputs : outputs
    }

    /// The 1-based position of a 0-based channel index, or nil when out of bounds.
    func position(ofIndex index: Int, direction: RouteDirection) -> Int? {
        (0..<channelCount(direction)).contains(index) ? index + 1 : nil
    }

    /// The 0-based index of a 1-based position, or nil when out of bounds.
    func index(ofPosition position: Int, direction: RouteDirection) -> Int? {
        position >= 1 && position <= channelCount(direction) ? position - 1 : nil
    }
}

/// A device kind in the v1 contract.
enum DeviceKind: String, Codable, Sendable, CaseIterable {
    case audioInterface
    case midiController
    case consoleCompatibility
}

/// One device on the host and how its binding was established.
struct DeviceDescriptor: Hashable, Sendable, Codable {
    enum CodingKeys: String, CodingKey, CaseIterable {
        case id, kind, layout, binding, capabilities, identity, presence, evidence, actualRate, requestedRate
    }

    var id: DeviceID
    var kind: DeviceKind
    var layout: ChannelLayout?
    var binding: MeasurementStatus
    var capabilities: [CapabilityID]
    let identity: DeviceIdentity
    var presence: DevicePresence
    var evidence: String?
    var actualRate: MeasuredRate?
    var requestedRate: Int?
    var unknownFields: [String: JSONValue] = [:]

    init(id: DeviceID, kind: DeviceKind, layout: ChannelLayout?, binding: MeasurementStatus,
         identity: DeviceIdentity, presence: DevicePresence = .present, evidence: String? = nil,
         capabilities: [CapabilityID] = []) throws {
        self.id = id
        self.kind = kind
        self.layout = layout
        self.binding = binding
        self.capabilities = capabilities
        self.identity = identity
        self.presence = presence
        self.evidence = evidence
        try validate()
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(DeviceID.self, forKey: .id)
        kind = try container.decode(DeviceKind.self, forKey: .kind)
        layout = try container.decodeIfPresent(ChannelLayout.self, forKey: .layout)
        binding = try container.decode(MeasurementStatus.self, forKey: .binding)
        capabilities = try container.decodeIfPresent([CapabilityID].self, forKey: .capabilities) ?? []
        identity = try container.decode(DeviceIdentity.self, forKey: .identity)
        presence = try container.decode(DevicePresence.self, forKey: .presence)
        evidence = try container.decodeIfPresent(String.self, forKey: .evidence)
        actualRate = try container.decodeIfPresent(MeasuredRate.self, forKey: .actualRate)
        requestedRate = try container.decodeIfPresent(Int.self, forKey: .requestedRate)
        unknownFields = try ExtensionFields.decode(from: decoder, knownKeys: CodingKeys.self)
        try validate()
    }

    func encode(to encoder: any Encoder) throws {
        try validate()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(layout, forKey: .layout)
        try container.encode(binding, forKey: .binding)
        try container.encode(capabilities, forKey: .capabilities)
        try container.encode(identity, forKey: .identity)
        try container.encode(presence, forKey: .presence)
        try container.encodeIfPresent(evidence, forKey: .evidence)
        try container.encodeIfPresent(actualRate, forKey: .actualRate)
        try container.encodeIfPresent(requestedRate, forKey: .requestedRate)
        try ExtensionFields.encode(unknownFields, to: encoder, knownKeys: CodingKeys.self)
    }

    func validate() throws {
        guard binding != .measured || (presence == .present && evidence?.isEmpty == false),
              presence == .present || actualRate == nil,
              requestedRate.map({ (1...768_000).contains($0) }) ?? true else {
            throw ControlValidationError.invalid("Device measurement or requested rate is invalid")
        }
        try ContractUniqueness.require(capabilities)
    }
}

enum CapabilityLevel: String, Codable, Hashable, Sendable { case required, advisory }

struct CapabilityRequirement: Hashable, Sendable {
    let capability: CapabilityID
    let level: CapabilityLevel
}

struct CapabilityAssessment: Hashable, Sendable {
    let missingRequired: Set<CapabilityID>
    let missingAdvisory: Set<CapabilityID>
    var requirementsSatisfied: Bool { missingRequired.isEmpty }
}

/// The versioned, host-local device document. Decode it only with
/// `DeviceCapabilityDocument.decode(from:)`, which goes through
/// `ContractCoding.decode` and the version policy.
struct DeviceCapabilityDocument: Hashable, Sendable, Codable {
    static let supported = ContractVersion(contract: "fluxklang.devices", version: 1)

    enum CodingKeys: String, CodingKey, CaseIterable {
        case contract, version, revision, devices, routes, extensions, host, hostEpoch, requiredFeatures
    }

    /// Advisory loss is reported independently; satisfying requirements never authorizes activation.
    func assess(_ requirements: [CapabilityRequirement]) throws -> CapabilityAssessment {
        guard requirements.count <= 4096 else { throw ControlValidationError.invalid("Too many capabilities") }
        try ContractUniqueness.require(requirements.map(\.capability))
        for device in devices { try device.validate() }
        let available = Set(devices.filter { $0.presence == .present }.flatMap(\.capabilities))
        return CapabilityAssessment(
            missingRequired: Set(requirements.filter {
                $0.level == .required && !available.contains($0.capability)
            }.map(\.capability)),
            missingAdvisory: Set(requirements.filter {
                $0.level == .advisory && !available.contains($0.capability)
            }.map(\.capability))
        )
    }

    var revision: ContractRevision
    var devices: [DeviceDescriptor]
    var routes: [AudioRoute]
    var extensions: [String: JSONValue]?
    var unknownFields: [String: JSONValue] = [:]
    let host: HostID
    let hostEpoch: Generation

    init(revision: ContractRevision, host: HostID, hostEpoch: Generation,
         devices: [DeviceDescriptor], routes: [AudioRoute]) throws {
        self.revision = revision
        self.devices = devices
        self.routes = routes
        self.host = host
        self.hostEpoch = hostEpoch
        try validate()
    }

    static func decode(from data: Data) throws -> DeviceCapabilityDocument {
        try ContractCoding.decode(DeviceCapabilityDocument.self, from: data)
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let compatibility = try ContractVersion.check(
            contract: container.decodeIfPresent(String.self, forKey: .contract),
            version: container.decodeIfPresent(Int.self, forKey: .version),
            supported: Self.supported
        )
        guard compatibility == .current else {
            throw DecodingError.dataCorruptedError(
                forKey: .version, in: container, debugDescription: "Unsupported devices document: \(compatibility)"
            )
        }
        revision = try container.decode(ContractRevision.self, forKey: .revision)
        host = try container.decode(HostID.self, forKey: .host)
        hostEpoch = try container.decode(Generation.self, forKey: .hostEpoch)
        let required = try container.decodeIfPresent([String].self, forKey: .requiredFeatures) ?? []
        guard required.isEmpty else { throw ControlValidationError.unsupportedRequiredData(required) }
        devices = try container.decode([DeviceDescriptor].self, forKey: .devices)
        routes = try container.decodeIfPresent([AudioRoute].self, forKey: .routes) ?? []
        extensions = try container.decodeIfPresent([String: JSONValue].self, forKey: .extensions)
        unknownFields = try ExtensionFields.decode(from: decoder, knownKeys: CodingKeys.self)
        try validate()
    }

    func encode(to encoder: any Encoder) throws {
        try validate()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.supported.contract, forKey: .contract)
        try container.encode(Self.supported.version, forKey: .version)
        try container.encode(revision, forKey: .revision)
        try container.encode(host, forKey: .host)
        try container.encode(hostEpoch, forKey: .hostEpoch)
        try container.encode(devices, forKey: .devices)
        try container.encode(routes, forKey: .routes)
        try container.encodeIfPresent(extensions, forKey: .extensions)
        try ExtensionFields.encode(unknownFields, to: encoder, knownKeys: CodingKeys.self)
    }

    /// Intrinsic validity needs only the document's own devices and host-local evidence.
    /// Checked on construction and at both codec boundaries, including after mutation.
    func validate() throws {
        do {
            try ContractUniqueness.require(devices.map(\.id))
            try ContractUniqueness.require(routes.map(\.id))
        } catch {
            throw RouteValidationError.duplicateID(error.rawValue)
        }
        let devicesByID = Dictionary(uniqueKeysWithValues: devices.map { ($0.id, $0) })
        for device in devices { try device.validate() }
        for route in routes {
            guard let device = devicesByID[route.device] else {
                throw RouteValidationError.unknownDevice(route.id, route.device)
            }
            if route.binding == .confirmed {
                guard device.presence == .present,
                      route.confirmedDeviceUID == device.identity.uid,
                      route.confirmedHost == host, route.confirmedEpoch == hostEpoch,
                      route.evidence?.isEmpty == false else {
                    throw ControlValidationError.invalid("Confirmed route requires current host-local evidence")
                }
            }
            try route.validate(layout: device.layout)
        }
    }

    /// External role existence, direction and channel counts remain a separate check.
    func validate(roles: [RoleID: RouteRoleRequirement]) throws {
        try validate()
        let layouts = Dictionary(uniqueKeysWithValues: devices.map { ($0.id, $0.layout) })
        for route in routes {
            guard let role = roles[route.role] else { throw RouteValidationError.unknownRole(route.id, route.role) }
            try route.validate(layout: layouts[route.device] ?? nil, role: role)
        }
    }
}
