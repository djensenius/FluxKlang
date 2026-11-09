/// Projects registry records into the validated `DeviceDescriptor`s that the device contract carries.
///
/// One rule decides the binding. A descriptor is `.measured` only for a present device whose measured baseline has an
/// actual rate; it then carries the BASELINE's layout and capabilities and the rate's evidence. Every other record is
/// `.reported` and carries the REPORTED layout and capabilities, with no evidence and no rate. `.measured` is the
/// registry's label, not a hardware proof: nothing here checks the evidence text.
///
/// Presence comes from `DeviceRegistryPresence.presence(of:)`, called once per record, so a lost device is `.missing`,
/// a revalidating or muted device is `.stale`, and none of them carries `.measured`, evidence or a rate.
/// Output order is input order. Refusals cover the whole input, nothing partial is returned, and they come in this
/// order: more records than `DeviceCapabilityLimits.devices`, then the first record whose id repeats an earlier one,
/// then a descriptor the contract refuses. Cost: one cap check, n set inserts, then one or two validations per record.
enum DeviceDescriptorProjection {
    /// One descriptor per record, in input order, or one refusal for the whole input.
    static func descriptors(
        records: [DeviceRecord]
    ) throws(DeviceDescriptorProjectionRefusal) -> [DeviceDescriptor] {
        let maximum = DeviceCapabilityLimits.devices
        guard records.count <= maximum else {
            throw .tooManyDevices(count: records.count, maximum: maximum)
        }
        var seen = Set<DeviceID>()
        seen.reserveCapacity(records.count)
        for record in records {
            guard seen.insert(record.id).inserted else { throw .duplicateDeviceID(record.id) }
        }
        var output: [DeviceDescriptor] = []
        output.reserveCapacity(records.count)
        for record in records {
            output.append(try descriptor(for: record))
        }
        return output
    }

    /// One sort (the registry's own, read once), then the passes of `descriptors(records:)`. The refusals are not
    /// exercised for a registry: its reducer bounds and de-duplicates its records.
    static func descriptors(
        registry: DeviceRegistry
    ) throws(DeviceDescriptorProjectionRefusal) -> [DeviceDescriptor] {
        try descriptors(records: registry.records)
    }

    /// Where one row takes its layout and capabilities from, and the rate that makes the row measured.
    private struct Basis {
        let set: DeviceCapabilitySet
        let rate: MeasuredRate?
    }

    private static func descriptor(
        for record: DeviceRecord
    ) throws(DeviceDescriptorProjectionRefusal) -> DeviceDescriptor {
        let presence = DeviceRegistryPresence.presence(of: record.lifecycle)
        let picked = basis(of: record, presence: presence)
        do {
            var built = try DeviceDescriptor(
                id: record.id,
                kind: record.kind,
                layout: picked.set.layout,
                binding: picked.rate == nil ? .reported : .measured,
                identity: record.identity,
                presence: presence,
                evidence: picked.rate?.evidence,
                capabilities: picked.set.capabilities
            )
            if let rate = picked.rate {
                built.actualRate = rate
                try built.validate()
            }
            return built
        } catch {
            throw .invalidDescriptor(record.id)
        }
    }

    /// Only a present device whose baseline carries a rate is measured; every other row is reported.
    private static func basis(of record: DeviceRecord, presence: DevicePresence) -> Basis {
        guard presence == .present,
              let baseline = record.measuredCapabilities,
              let rate = baseline.actualRate else {
            return Basis(set: record.reportedCapabilities, rate: nil)
        }
        return Basis(set: baseline, rate: rate)
    }
}
