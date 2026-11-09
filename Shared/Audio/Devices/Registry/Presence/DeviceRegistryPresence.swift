/// The registry's devices as the three-case `DevicePresence` that route and status consumers read, plus the
/// engine-gate counts, built in one pass over the records.
///
/// Only a `.present` lifecycle is reported as present. A device the registry does not know is absent from the
/// map, so a consumer reads it as unobserved.
struct DeviceRegistryPresence: Hashable, Sendable {
    let byDevice: [DeviceID: DevicePresence]
    let gate: DeviceRegistryPresenceGate

    private init(byDevice: [DeviceID: DevicePresence], gate: DeviceRegistryPresenceGate) {
        self.byDevice = byDevice
        self.gate = gate
    }

    /// Projects `records` in one pass. Refusals, in order: more records than `DeviceCapabilityLimits.devices`
    /// (checked before anything is allocated), then the first record, in input order, whose id repeats an earlier
    /// one. The result does not depend on input order; the payload of a duplicate refusal does.
    static func make(records: [DeviceRecord]) throws(DeviceRegistryRefusal) -> DeviceRegistryPresence {
        let maximum = DeviceCapabilityLimits.devices
        guard records.count <= maximum else {
            throw .tooManyDevices(count: records.count, maximum: maximum)
        }
        var byDevice: [DeviceID: DevicePresence] = [:]
        byDevice.reserveCapacity(records.count)
        var gate = DeviceRegistryPresenceGate.none
        for record in records {
            let state = presence(of: record.lifecycle)
            if byDevice.updateValue(state, forKey: record.id) != nil {
                throw .duplicateDeviceID(record.id)
            }
            gate = gate.adding(record.lifecycle)
        }
        return DeviceRegistryPresence(byDevice: byDevice, gate: gate)
    }

    /// One registry sort (the registry's own), then the single pass of `make(records:)`.
    static func make(registry: DeviceRegistry) throws(DeviceRegistryRefusal) -> DeviceRegistryPresence {
        try make(records: registry.records)
    }

    /// The presence of one device, or nil when the registry does not know it.
    func presence(of device: DeviceID) -> DevicePresence? {
        byDevice[device]
    }

    /// The pinned mapping. Every blocked state is reported as unavailable; the muted reason is ignored.
    static func presence(of lifecycle: DeviceLifecycle) -> DevicePresence {
        switch lifecycle {
        case .present: .present
        case .lostMuted: .missing
        case .revalidating, .muted: .stale
        }
    }
}
