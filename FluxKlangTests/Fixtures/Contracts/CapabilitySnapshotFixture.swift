//
//  CapabilitySnapshotFixture.swift
//  FluxKlangTests
//
//  A fixed device capability snapshot for every `ContractFixtureState`. A
//  snapshot is an observation only: satisfying its requirements is not
//  preparation, activation or an engine lease.
//
//  - available: the fixture device is present and advertises both capabilities.
//  - missing: the device is `missing`; its advertised capabilities do not count.
//  - stale: the document was observed under the previous host epoch and the
//    device is `stale`; `currentHostEpoch` has moved on by one.
//  - failed: the device is present but its capability probe failed, so it
//    advertises nothing. The `unverified` binding ("not yet checked") is
//    informational only; the empty capability list is what fails, and
//    presence is what tells failed apart from missing.
//  - pressured: minimal case only. The device advertises exactly
//    `DeviceCapabilityLimits.capabilitiesPerDevice` capabilities. Document-wide
//    limits (devices, routes, bytes) are F5's `PressureFixture`.
//

@testable import FluxKlang

struct CapabilitySnapshotFixture: Hashable, Sendable {
    static let requiredCapability = ContractFixtureIDs.capability
    static let advisoryCapability = CapabilityID(validated: "fx.capability.advisory")
    static let requirements = [
        CapabilityRequirement(capability: requiredCapability, level: .required),
        CapabilityRequirement(capability: advisoryCapability, level: .advisory)
    ]

    /// The host-local document as last observed.
    let document: DeviceCapabilityDocument
    let requirements: [CapabilityRequirement]
    /// The host's live epoch; differs from `document.hostEpoch` only when stale.
    let currentHostEpoch: Generation

    /// Capabilities of present devices, the explicit set `validateForPreparation` needs.
    var supportedCapabilities: Set<CapabilityID> {
        Set(document.devices.filter { $0.presence == .present }.flatMap(\.capabilities))
    }

    static func make(_ state: ContractFixtureState) throws -> Self {
        let both = [requiredCapability, advisoryCapability]
        let observedEpoch = Generation.initial
        let currentEpoch = state == .stale ? try observedEpoch.next() : observedEpoch
        let device: DeviceDescriptor
        switch state {
        case .available:
            device = try Self.device(presence: .present, capabilities: both)
        case .missing:
            device = try Self.device(presence: .missing, capabilities: both)
        case .stale:
            device = try Self.device(presence: .stale, capabilities: both)
        case .failed:
            device = try Self.device(presence: .present, capabilities: [], binding: .unverified)
        case .pressured:
            var sequence = try FixtureIDSequence<CapabilityTag>(
                prefix: "capability.pressure", limit: DeviceCapabilityLimits.capabilitiesPerDevice - both.count
            )
            let filler = try (0..<sequence.limit).map { _ in try sequence.next() }
            device = try Self.device(presence: .present, capabilities: both + filler)
        }
        let document = try DeviceCapabilityDocument(
            revision: .initial, host: ContractFixtureIDs.host, hostEpoch: observedEpoch,
            devices: [device], routes: []
        )
        return Self(document: document, requirements: requirements, currentHostEpoch: currentEpoch)
    }

    private static func device(
        presence: DevicePresence, capabilities: [CapabilityID], binding: MeasurementStatus = .reported
    ) throws -> DeviceDescriptor {
        try DeviceDescriptor(
            id: ContractFixtureIDs.device, kind: .audioInterface,
            layout: ChannelLayout(inputs: 2, outputs: 2, sampleRate: 48_000), binding: binding,
            identity: DeviceIdentity(.init(uid: "fx.device.uid", evidence: [.deviceUID])),
            presence: presence, capabilities: capabilities
        )
    }
}
