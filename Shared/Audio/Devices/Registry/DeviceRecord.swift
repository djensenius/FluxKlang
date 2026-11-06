/// A canonical, bounded set of device capability values. `DeviceRecord` labels
/// each set as reported or measured so an advertisement is never measurement.
struct DeviceCapabilitySet: Hashable, Sendable {
    let capabilities: [CapabilityID]
    let layout: ChannelLayout?
    let actualRate: MeasuredRate?
    let bufferFrames: Int?

    private init(
        capabilities: [CapabilityID], layout: ChannelLayout?, actualRate: MeasuredRate?, bufferFrames: Int?
    ) {
        self.capabilities = capabilities.sorted()
        self.layout = layout
        self.actualRate = actualRate
        self.bufferFrames = bufferFrames
    }

    /// Validates and canonicalizes a capability set.
    static func make(
        capabilities: [CapabilityID], layout: ChannelLayout? = nil, actualRate: MeasuredRate? = nil,
        bufferFrames: Int? = nil
    ) throws(DeviceRegistryRefusal) -> DeviceCapabilitySet {
        guard capabilities.count <= DeviceCapabilityLimits.capabilitiesPerDevice else {
            throw .tooManyCapabilities(
                count: capabilities.count, maximum: DeviceCapabilityLimits.capabilitiesPerDevice
            )
        }
        var seen = Set<CapabilityID>()
        for capability in capabilities where !seen.insert(capability).inserted {
            throw .duplicateCapability(capability)
        }
        if let bufferFrames, bufferFrames <= 0 { throw .invalidBufferFrames(bufferFrames) }
        return DeviceCapabilitySet(
            capabilities: capabilities, layout: layout, actualRate: actualRate, bufferFrames: bufferFrames
        )
    }

    /// The first mismatch in documented field order, or nil when every measured
    /// field is identical.
    func firstMismatch(comparedTo other: DeviceCapabilitySet) -> DeviceCapabilityField? {
        if capabilities != other.capabilities { return .capabilities }
        if layout != other.layout { return .layout }
        if actualRate != other.actualRate { return .actualRate }
        if bufferFrames != other.bufferFrames { return .bufferFrames }
        return nil
    }
}

/// Stable identity key derived only from a device/endpoint UID and its UID source.
struct DeviceIdentityKey: Hashable, Comparable, Sendable {
    let uid: String
    let evidence: [IdentityEvidence]

    private init(uid: String, evidence: [IdentityEvidence]) {
        self.uid = uid
        self.evidence = evidence.sorted { $0.rawValue < $1.rawValue }
    }

    /// Builds a key only when the identity carries valid UID evidence.
    static func make(from identity: DeviceIdentity) throws(DeviceRegistryRefusal) -> DeviceIdentityKey {
        do {
            try identity.fields.validate()
        } catch {
            throw .missingUIDEvidence
        }
        let uidEvidence = identity.evidence.intersection(Set([.deviceUID, .endpointUID]))
        guard !uidEvidence.isEmpty else { throw .missingUIDEvidence }
        return DeviceIdentityKey(uid: identity.uid, evidence: Array(uidEvidence))
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.uid != rhs.uid { return lhs.uid < rhs.uid }
        return lhs.evidence.map(\.rawValue).joined(separator: ",")
            < rhs.evidence.map(\.rawValue).joined(separator: ",")
    }
}

/// A registry record whose identity, reported values, measured values and
/// lifecycle are independently represented.
struct DeviceRecord: Hashable, Sendable {
    let id: DeviceID
    let kind: DeviceKind
    let identity: DeviceIdentity
    let identityKey: DeviceIdentityKey
    let reportedCapabilities: DeviceCapabilitySet
    let measuredCapabilities: DeviceCapabilitySet?
    let lifecycle: DeviceLifecycle

    private init(
        id: DeviceID, kind: DeviceKind, identity: DeviceIdentity, identityKey: DeviceIdentityKey,
        reportedCapabilities: DeviceCapabilitySet, measuredCapabilities: DeviceCapabilitySet?,
        lifecycle: DeviceLifecycle
    ) {
        self.id = id
        self.kind = kind
        self.identity = identity
        self.identityKey = identityKey
        self.reportedCapabilities = reportedCapabilities
        self.measuredCapabilities = measuredCapabilities
        self.lifecycle = lifecycle
    }

    /// Constructs a new, present record. This is the explicit path for replacing
    /// a muted record when the caller intends to accept a new device baseline.
    static func make(
        id: DeviceID, kind: DeviceKind, identity fields: DeviceIdentityFields,
        reportedCapabilities: DeviceCapabilitySet,
        measuredCapabilities: DeviceCapabilitySet? = nil
    ) throws(DeviceRegistryRefusal) -> DeviceRecord {
        guard reportedCapabilities.actualRate == nil else {
            throw .measurementInReportedCapabilities
        }
        let identity: DeviceIdentity
        do {
            identity = try DeviceIdentity(fields)
        } catch {
            throw .missingUIDEvidence
        }
        let key = try DeviceIdentityKey.make(from: identity)
        return DeviceRecord(
            id: id, kind: kind, identity: identity, identityKey: key,
            reportedCapabilities: reportedCapabilities, measuredCapabilities: measuredCapabilities,
            lifecycle: .present
        )
    }

    func afterDisappearance() -> DeviceRecord {
        guard lifecycle != .lostMuted else { return self }
        return copying(lifecycle: .lostMuted)
    }

    func afterReturn() -> DeviceRecord {
        guard lifecycle == .lostMuted else { return self }
        return copying(lifecycle: .revalidating)
    }

    func afterMeasurement(_ measured: DeviceCapabilitySet) -> DeviceRecordMeasurementResult {
        guard lifecycle != .lostMuted else {
            return .refused(.deviceNotAvailable(identityKey))
        }
        guard let baseline = measuredCapabilities else {
            guard lifecycle == .present else {
                let reason = DeviceMismatchReason.noMeasuredBaseline
                let nextState = DeviceLifecycle.muted(reason)
                guard lifecycle != nextState else { return .unchanged }
                let next = copying(lifecycle: nextState)
                return .changed(
                    next,
                    effect: .lifecycleChanged(id, from: lifecycle, to: nextState)
                )
            }
            return .changed(
                copying(lifecycle: .present, measuredCapabilities: measured),
                effect: .capabilitiesMeasured(id)
            )
        }
        if let mismatch = measured.firstMismatch(comparedTo: baseline) {
            let nextState = DeviceLifecycle.muted(.capabilityMismatch(mismatch))
            guard lifecycle != nextState else { return .unchanged }
            let next = copying(lifecycle: nextState)
            return .changed(next, effect: .lifecycleChanged(id, from: lifecycle, to: nextState))
        }
        guard lifecycle != .present else { return .unchanged }
        let next = copying(lifecycle: .present)
        return .changed(next, effect: .lifecycleChanged(id, from: lifecycle, to: .present))
    }

    private func copying(
        lifecycle: DeviceLifecycle, measuredCapabilities: DeviceCapabilitySet? = nil
    ) -> DeviceRecord {
        DeviceRecord(
            id: id, kind: kind, identity: identity, identityKey: identityKey,
            reportedCapabilities: reportedCapabilities,
            measuredCapabilities: measuredCapabilities ?? self.measuredCapabilities,
            lifecycle: lifecycle
        )
    }
}

enum DeviceRecordMeasurementResult: Sendable {
    case unchanged
    case changed(DeviceRecord, effect: DeviceRegistryEffect)
    case refused(DeviceRegistryRefusal)
}
