/// The typed cause a route/device is unavailable to the engine.
enum DeviceLossReason: Hashable, Sendable {
    case lost
    case revalidating
    case muted(DeviceMismatchReason)
}

/// One blocked device and all routes that refer to its stable `DeviceID`.
struct DeviceLossEntry: Hashable, Sendable {
    let device: DeviceID
    let identity: DeviceIdentityKey
    let reason: DeviceLossReason
    let routes: [RouteID]

    fileprivate init(device: DeviceID, identity: DeviceIdentityKey, reason: DeviceLossReason, routes: [RouteID]) {
        self.device = device
        self.identity = identity
        self.reason = reason
        self.routes = routes
    }
}

/// A deterministic, read-only snapshot of registry records that are not safely present.
struct DeviceLossReport: Hashable, Sendable {
    let entries: [DeviceLossEntry]

    private init(entries: [DeviceLossEntry]) {
        self.entries = entries
    }

    /// Builds a report from blocked registry records and host-local routes.
    static func make(
        records: [DeviceRecord], routes: [AudioRoute]
    ) throws(DeviceRegistryRefusal) -> DeviceLossReport {
        guard records.count <= DeviceCapabilityLimits.devices else {
            throw .tooManyDevices(count: records.count, maximum: DeviceCapabilityLimits.devices)
        }
        try validateRoutesForReport(routes)
        let blocked = records.filter { $0.lifecycle.blocksEngineAcquisition }
            .sorted { $0.identityKey < $1.identityKey }
        let entries = blocked.compactMap { record -> DeviceLossEntry? in
            let reason: DeviceLossReason
            switch record.lifecycle {
            case .present:
                return nil
            case .lostMuted:
                reason = .lost
            case .revalidating:
                reason = .revalidating
            case .muted(let mismatch):
                reason = .muted(mismatch)
            }
            let affectedRoutes = routes
                .filter { $0.device == record.id }
                .map(\.id)
                .sorted()
            return DeviceLossEntry(
                device: record.id, identity: record.identityKey, reason: reason, routes: affectedRoutes
            )
        }
        return DeviceLossReport(entries: entries)
    }

    /// All route IDs in stable ascending order, without duplicates.
    var affectedRoutes: [RouteID] {
        Array(Set(entries.flatMap(\.routes))).sorted()
    }
}

private func validateRoutesForReport(_ routes: [AudioRoute]) throws(DeviceRegistryRefusal) {
    guard routes.count <= DeviceCapabilityLimits.routes else {
        throw .tooManyRoutes(count: routes.count, maximum: DeviceCapabilityLimits.routes)
    }
    var seen = Set<RouteID>()
    for route in routes where !seen.insert(route.id).inserted {
        throw .duplicateRoute(route.id)
    }
}
