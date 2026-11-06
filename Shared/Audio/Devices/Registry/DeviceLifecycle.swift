/// A capability field compared when a returning device is revalidated.
enum DeviceCapabilityField: String, Hashable, Sendable, CaseIterable {
    case capabilities
    case layout
    case actualRate
    case bufferFrames
}

/// Why a record remains muted rather than being resumed automatically.
enum DeviceMismatchReason: Hashable, Sendable {
    case noMeasuredBaseline
    case capabilityMismatch(DeviceCapabilityField)
}

/// Presence and safe revalidation state for one device.
enum DeviceLifecycle: Hashable, Sendable {
    case present
    case lostMuted
    case revalidating
    case muted(DeviceMismatchReason)

    /// True for every state in which a fresh engine acquisition must be denied.
    var blocksEngineAcquisition: Bool {
        switch self {
        case .present: false
        case .lostMuted, .revalidating, .muted: true
        }
    }
}

/// A pure registry event. Identity-bearing events use the validated UID key;
/// record creation and replacement use validated `DeviceRecord` values.
enum DeviceRegistryEvent: Hashable, Sendable {
    case observed(DeviceRecord)
    case disappeared(DeviceIdentityKey)
    case returned(DeviceIdentityKey)
    case capabilitiesMeasured(DeviceIdentityKey, DeviceCapabilitySet)
    /// Explicit caller-approved replacement of an existing record and baseline.
    case replacingRecord(DeviceRecord)
}

/// A typed description of the state transition emitted by the reducer.
enum DeviceRegistryEffect: Hashable, Sendable {
    case registered(DeviceID)
    case replaced(DeviceID)
    /// The first measured capability set became the baseline of a present device.
    case capabilitiesMeasured(DeviceID)
    case lifecycleChanged(DeviceID, from: DeviceLifecycle, to: DeviceLifecycle)
}
