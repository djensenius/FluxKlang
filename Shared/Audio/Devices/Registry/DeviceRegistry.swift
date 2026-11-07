/// A typed refusal from validation, registry reduction, or report construction.
enum DeviceRegistryRefusal: Error, Hashable, Sendable {
    case missingUIDEvidence
    case duplicateCapability(CapabilityID)
    case duplicateDeviceID(DeviceID)
    case duplicateRoute(RouteID)
    case tooManyDevices(count: Int, maximum: Int)
    case tooManyCapabilities(count: Int, maximum: Int)
    case tooManyRoutes(count: Int, maximum: Int)
    case invalidBufferFrames(Int)
    case measurementInReportedCapabilities
    case unknownDevice(DeviceIdentityKey)
    case conflictingObservation(DeviceIdentityKey)
    case conflictingReplacement(DeviceIdentityKey)
    case deviceNotAvailable(DeviceIdentityKey)
}

/// One deterministic result of applying an event. A refusal carries no
/// replacement registry, so a failed operation cannot mutate the caller's value.
enum DeviceRegistryEventResult: Equatable, Sendable {
    case accepted(DeviceRegistry, effect: DeviceRegistryEffect?)
    case refused(DeviceRegistryRefusal)
}

/// A backend-neutral, bounded registry keyed by validated UID evidence.
struct DeviceRegistry: Sendable, Hashable {
    private var recordsByIdentity: [DeviceIdentityKey: DeviceRecord]

    private init(recordsByIdentity: [DeviceIdentityKey: DeviceRecord]) {
        self.recordsByIdentity = recordsByIdentity
    }

    /// An empty registry permits acquisition because it has no blocked records.
    static var empty: DeviceRegistry { DeviceRegistry(recordsByIdentity: [:]) }

    /// Records in stable UID/evidence order; dictionary order is never exposed.
    var records: [DeviceRecord] {
        recordsByIdentity.values.sorted { $0.identityKey < $1.identityKey }
    }

    /// A single global gate for every window's new engine acquisition.
    var allowsEngineAcquisition: Bool {
        recordsByIdentity.values.allSatisfy { !$0.lifecycle.blocksEngineAcquisition }
    }

    /// Returns the record for a validated identity key, if registered.
    func record(for identity: DeviceIdentityKey) -> DeviceRecord? {
        recordsByIdentity[identity]
    }

    /// Applies one event as a pure reducer. Route reports are built separately,
    /// so invalid report input cannot prevent a device loss from being recorded.
    func applying(_ event: DeviceRegistryEvent) -> DeviceRegistryEventResult {
        switch event {
        case .observed(let record):
            return observing(record)
        case .disappeared(let identity):
            return disappearing(identity)
        case .returned(let identity):
            return returning(identity)
        case .capabilitiesMeasured(let identity, let measured):
            return measuring(measured, for: identity)
        case .replacingRecord(let record):
            return replacing(record)
        }
    }

    /// Reports every record that is not safely present and the routes that use it.
    func lossReport(routes: [AudioRoute]) throws(DeviceRegistryRefusal) -> DeviceLossReport {
        try DeviceLossReport.make(records: records, routes: routes)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.records == rhs.records
    }

    func hash(into hasher: inout Hasher) {
        for record in records {
            hasher.combine(record.identityKey)
            hasher.combine(record)
        }
    }

    private func observing(_ record: DeviceRecord) -> DeviceRegistryEventResult {
        let key = record.identityKey
        if let existing = recordsByIdentity[key] {
            guard existing.hasSameObservation(as: record) else {
                return .refused(.conflictingObservation(key))
            }
            return .accepted(self, effect: nil)
        }
        guard recordsByIdentity.values.allSatisfy({ $0.id != record.id }) else {
            return .refused(.duplicateDeviceID(record.id))
        }
        guard recordsByIdentity.count < DeviceCapabilityLimits.devices else {
            return .refused(.tooManyDevices(
                count: recordsByIdentity.count + 1, maximum: DeviceCapabilityLimits.devices
            ))
        }
        var updated = recordsByIdentity
        updated[key] = record
        return .accepted(
            DeviceRegistry(recordsByIdentity: updated), effect: .registered(record.id)
        )
    }

    private func disappearing(_ identity: DeviceIdentityKey) -> DeviceRegistryEventResult {
        guard let record = recordsByIdentity[identity] else { return .refused(.unknownDevice(identity)) }
        let changed = record.afterDisappearance()
        guard changed != record else { return .accepted(self, effect: nil) }
        return updated(
            record: changed,
            effect: .lifecycleChanged(record.id, from: record.lifecycle, to: .lostMuted)
        )
    }

    private func returning(_ identity: DeviceIdentityKey) -> DeviceRegistryEventResult {
        guard let record = recordsByIdentity[identity] else { return .refused(.unknownDevice(identity)) }
        let changed = record.afterReturn()
        guard changed != record else { return .accepted(self, effect: nil) }
        return updated(
            record: changed,
            effect: .lifecycleChanged(record.id, from: .lostMuted, to: .revalidating)
        )
    }

    private func measuring(
        _ measured: DeviceCapabilitySet, for identity: DeviceIdentityKey
    ) -> DeviceRegistryEventResult {
        guard let record = recordsByIdentity[identity] else { return .refused(.unknownDevice(identity)) }
        switch record.afterMeasurement(measured) {
        case .refused(let refusal):
            return .refused(refusal)
        case .unchanged:
            return .accepted(self, effect: nil)
        case .changed(let changed, let effect):
            return updated(record: changed, effect: effect)
        }
    }

    private func replacing(_ record: DeviceRecord) -> DeviceRegistryEventResult {
        let key = record.identityKey
        guard let existing = recordsByIdentity[key] else { return .refused(.unknownDevice(key)) }
        guard existing.lifecycle != .lostMuted else { return .refused(.deviceNotAvailable(key)) }
        // Keep the key's bound ID; registry IDs stay unique across identities by construction.
        guard existing.id == record.id else { return .refused(.conflictingReplacement(key)) }
        guard existing != record else { return .accepted(self, effect: nil) }
        var updated = recordsByIdentity
        updated[key] = record
        return .accepted(DeviceRegistry(recordsByIdentity: updated), effect: .replaced(record.id))
    }

    private func updated(record: DeviceRecord, effect: DeviceRegistryEffect) -> DeviceRegistryEventResult {
        var updated = recordsByIdentity
        updated[record.identityKey] = record
        return .accepted(DeviceRegistry(recordsByIdentity: updated), effect: effect)
    }

}

extension DeviceRecord {
    fileprivate func hasSameObservation(as other: DeviceRecord) -> Bool {
        id == other.id && kind == other.kind
            && reportedCapabilities == other.reportedCapabilities
                && (other.measuredCapabilities == nil || measuredCapabilities == other.measuredCapabilities)
    }
}
