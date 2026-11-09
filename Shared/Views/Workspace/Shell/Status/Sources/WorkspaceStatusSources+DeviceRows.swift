//
//  WorkspaceStatusSources+DeviceRows.swift
//  FluxKlang
//
//  The device rows of the status strip: one pass that finds the refusals, one sort by name bytes (#99 WSS1).
//

extension WorkspaceStatusSources {
    /// One row before sorting. The id is kept for the tie break only.
    private struct RowKey {
        let id: DeviceID
        let name: String
        let presence: DevicePresence
    }

    /// What the one pass found: the rows, and the smallest repeated and the smallest nameless id.
    private struct Scan {
        let keys: [RowKey]
        let duplicate: DeviceID?
        let nameless: DeviceID?
    }

    /// The rows for `devices`, named by the caller's `names`, sorted by the name's UTF-8 bytes and then by the
    /// device id's UTF-8 bytes. That order is total: it does not depend on the input order or on sort stability.
    /// A row carries the descriptor's presence unchanged. Names are never validated, trimmed or truncated: an
    /// empty or an over-long name is the projection's refusal, at its sorted index. Entries of `names` for other
    /// ids are ignored. The refusals, in order, each over the whole input: more than `maximumDevices`
    /// descriptors (decided from the count alone), a repeated device id (the smallest), a device without a name
    /// (the smallest). A refused call returns no rows.
    static func deviceRows(
        _ devices: [DeviceDescriptor], names: [DeviceID: String]
    ) throws(WorkspaceStatusSourceRefusal) -> [WorkspaceStatusDevice] {
        guard devices.count <= maximumDevices else {
            throw .tooManyDevices(count: devices.count, maximum: maximumDevices)
        }
        let scan = scanned(devices, names: names)
        if let duplicate = scan.duplicate { throw .duplicateDevice(duplicate) }
        if let nameless = scan.nameless { throw .missingName(nameless) }
        let ordered = scan.keys.sorted(by: precedes)
        return ordered.map { WorkspaceStatusDevice(name: $0.name, presence: $0.presence) }
    }

    private static func scanned(_ devices: [DeviceDescriptor], names: [DeviceID: String]) -> Scan {
        var seen: Set<DeviceID> = []
        seen.reserveCapacity(devices.count)
        var keys: [RowKey] = []
        keys.reserveCapacity(devices.count)
        var duplicate: DeviceID?
        var nameless: DeviceID?
        for device in devices {
            let id = device.id
            if seen.update(with: id) != nil { keepSmaller(id, in: &duplicate) }
            if let name = names[id] {
                keys.append(RowKey(id: id, name: name, presence: device.presence))
            } else {
                keepSmaller(id, in: &nameless)
            }
        }
        return Scan(keys: keys, duplicate: duplicate, nameless: nameless)
    }

    /// Keeps the smaller of `current` and `candidate` by UTF-8 bytes.
    private static func keepSmaller(_ candidate: DeviceID, in current: inout DeviceID?) {
        guard let held = current else {
            current = candidate
            return
        }
        if candidate.rawValue.utf8.lexicographicallyPrecedes(held.rawValue.utf8) { current = candidate }
    }

    private static func precedes(_ lhs: RowKey, _ rhs: RowKey) -> Bool {
        if lhs.name.utf8.elementsEqual(rhs.name.utf8) {
            return lhs.id.rawValue.utf8.lexicographicallyPrecedes(rhs.id.rawValue.utf8)
        }
        return lhs.name.utf8.lexicographicallyPrecedes(rhs.name.utf8)
    }
}
