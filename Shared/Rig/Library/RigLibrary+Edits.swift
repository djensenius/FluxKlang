//
//  RigLibrary+Edits.swift
//  FluxKlang
//
//  The seven edits of a rig library. Each takes the library by value and
//  returns a new library with a change flag, or throws; a refusal leaves the
//  caller's library as it was. Each edit refuses in the order its doc comment
//  lists, every step over the whole input, and ends in `RigLibrary.make`, so
//  an edit cannot return a library `make` would refuse. Nothing here reads a
//  device or activates a rig.
//

/// The library an accepted edit returns and whether it differs from the library the edit was given.
struct RigLibraryEdit: Hashable, Sendable {
    let library: RigLibrary
    let change: RigLibraryChange

    fileprivate init(library: RigLibrary, change: RigLibraryChange) {
        self.library = library
        self.change = change
    }
}

/// Positions and name holders of a library, built once per edit (a library holds at most 16 entries).
private struct RigLibraryIndex {
    let position: [RigProfileID: Int]
    let holder: [RigUID: RigProfileID]

    init(_ library: RigLibrary) {
        var position: [RigProfileID: Int] = [:]
        var holder: [RigUID: RigProfileID] = [:]
        for (offset, entry) in library.entries.enumerated() {
            position[entry.id] = offset
            holder[entry.name] = entry.id
        }
        self.position = position
        self.holder = holder
    }
}

/// Where a device sits: the entry in the library and the device in its rig.
private struct RigLibraryDeviceSite {
    let entry: Int
    let device: Int
}

extension RigLibrary {
    /// Adds a rig built from the observed devices. Refuses, in this order: more than `RigIdentityLimits.observed`
    /// descriptors, a repeated observed `DeviceID` (both through `RigObservedIndex.make`); a name over
    /// `RigLibraryEntry.nameBytes` bytes or a blank one; `id` already in the library (`.rig(.duplicateRig)`);
    /// the name already held (`duplicateName`); a full library (`.rig(.tooManyRigs)`); then the rig itself.
    /// Only present descriptors with device or endpoint UID evidence are kept; missing and stale ones are
    /// skipped without a report. Every kept device has no role and is not required. A list of more than
    /// `RigIdentityLimits.devicesPerRig` present devices is refused with the first count over the limit (65),
    /// and two present devices that share a UID are refused (`.rig(.duplicateUID)`), not resolved.
    /// `selected` is left as it was.
    func capturing(id: RigProfileID, name: String, observed: [DeviceDescriptor]) throws(RigLibraryRefusal)
        -> RigLibraryEdit {
        try RigLibraryRefusal.wrapping { () throws(RigIdentityRefusal) in _ = try RigObservedIndex.make(observed) }
        try RigLibraryEntry.checkName(name)
        let index = RigLibraryIndex(self)
        guard index.position[id] == nil else { throw .rig(.duplicateRig(id)) }
        if let holder = index.holder[RigUID(name)] { throw .duplicateName(holder) }
        try checkRoom()
        let rig = try Self.capturedRig(id: id, observed: observed)
        return try appended(RigLibraryEntry(name: RigUID(name), rig: rig))
    }

    /// Adds a copy of rig `source` under a new id and name, with the same devices. Refuses, in this order:
    /// `unknownRig(source)`, the name rule, `id` already in the library (`.rig(.duplicateRig)`), the name
    /// already held (`duplicateName`), a full library (`.rig(.tooManyRigs)`). `selected` is left as it was.
    func duplicating(_ source: RigProfileID, as id: RigProfileID,
                     name: String) throws(RigLibraryRefusal) -> RigLibraryEdit {
        let index = RigLibraryIndex(self)
        guard let position = index.position[source] else { throw .unknownRig(source) }
        try RigLibraryEntry.checkName(name)
        guard index.position[id] == nil else { throw .rig(.duplicateRig(id)) }
        if let holder = index.holder[RigUID(name)] { throw .duplicateName(holder) }
        try checkRoom()
        let devices = entries[position].rig.devices
        let rig = try RigLibraryRefusal.wrapping { () throws(RigIdentityRefusal) in
            try RigSavedRig.make(id: id, devices: devices)
        }
        return try appended(RigLibraryEntry(name: RigUID(name), rig: rig))
    }

    /// Renames a rig. Refuses, in this order: `unknownRig`, the name rule, a name held by another rig
    /// (`duplicateName`). The scalars the rig already has are `.unchanged`; a canonically equal spelling with
    /// other scalars is `.changed`.
    func renaming(_ id: RigProfileID, to name: String) throws(RigLibraryRefusal) -> RigLibraryEdit {
        let index = RigLibraryIndex(self)
        guard let position = index.position[id] else { throw .unknownRig(id) }
        try RigLibraryEntry.checkName(name)
        let key = RigUID(name)
        if let holder = index.holder[key] {
            guard holder == id else { throw .duplicateName(holder) }
            return RigLibraryEdit(library: self, change: .unchanged)
        }
        var kept = entries
        kept[position] = RigLibraryEntry(name: key, rig: entries[position].rig)
        return try replaced(kept, selected: selected)
    }

    /// Removes a rig. A rig that is not in the library is `.unchanged`. Removing the selected rig selects the
    /// next rig in id order, else the previous one, else nothing; removing any other rig keeps `selected`.
    func removing(_ id: RigProfileID) throws(RigLibraryRefusal) -> RigLibraryEdit {
        guard let position = RigLibraryIndex(self).position[id] else {
            return RigLibraryEdit(library: self, change: .unchanged)
        }
        var kept = entries
        kept.remove(at: position)
        var next = selected
        if selected == id {
            let neighbour = position < kept.count ? position : position - 1
            next = kept.indices.contains(neighbour) ? kept[neighbour].id : nil
        }
        return try replaced(kept, selected: next)
    }

    /// Selects a rig, or clears the selection with nil. Refuses `unknownRig` for an id not in the library.
    /// Choosing what is already selected is `.unchanged`. Selecting activates nothing.
    func selecting(_ id: RigProfileID?) throws(RigLibraryRefusal) -> RigLibraryEdit {
        if let id, RigLibraryIndex(self).position[id] == nil { throw .unknownRig(id) }
        guard selected != id else { return RigLibraryEdit(library: self, change: .unchanged) }
        return try replaced(entries, selected: id)
    }

    /// Sets or clears one device's role. Refuses `unknownRig`, then `unknownDevice`. The same role is
    /// `.unchanged`. Roles need not be unique within a rig.
    func settingRole(_ role: RoleID?, of device: DeviceID,
                     in rig: RigProfileID) throws(RigLibraryRefusal) -> RigLibraryEdit {
        let site = try locate(device, in: rig)
        let old = entries[site.entry].rig.devices[site.device]
        let edited = try Self.rebuilt(old, role: role, required: old.required)
        return try replacing(edited, at: site)
    }

    /// Marks one device required or optional. Refuses `unknownRig`, then `unknownDevice`. The same flag is
    /// `.unchanged`. A required device lowers the operating mode when it is not matched.
    func settingRequired(_ required: Bool, of device: DeviceID,
                         in rig: RigProfileID) throws(RigLibraryRefusal) -> RigLibraryEdit {
        let site = try locate(device, in: rig)
        let old = entries[site.entry].rig.devices[site.device]
        let edited = try Self.rebuilt(old, role: old.role, required: required)
        return try replacing(edited, at: site)
    }

    private func checkRoom() throws(RigLibraryRefusal) {
        guard entries.count < RigIdentityLimits.rigs else {
            throw .rig(.tooManyRigs(count: entries.count + 1, maximum: RigIdentityLimits.rigs))
        }
    }

    private func appended(_ entry: RigLibraryEntry) throws(RigLibraryRefusal) -> RigLibraryEdit {
        try replaced(entries + [entry], selected: selected)
    }

    private func replaced(_ kept: [RigLibraryEntry],
                          selected: RigProfileID?) throws(RigLibraryRefusal) -> RigLibraryEdit {
        let library = try RigLibrary.make(entries: kept, selected: selected)
        return RigLibraryEdit(library: library, change: .changed)
    }

    private func locate(_ device: DeviceID,
                        in rig: RigProfileID) throws(RigLibraryRefusal) -> RigLibraryDeviceSite {
        guard let entry = RigLibraryIndex(self).position[rig] else { throw .unknownRig(rig) }
        let devices = entries[entry].rig.devices
        guard let found = devices.firstIndex(where: { $0.id == device }) else {
            throw .unknownDevice(rig: rig, device: device)
        }
        return RigLibraryDeviceSite(entry: entry, device: found)
    }

    private func replacing(_ edited: RigSavedDevice,
                           at site: RigLibraryDeviceSite) throws(RigLibraryRefusal) -> RigLibraryEdit {
        let entry = entries[site.entry]
        guard edited != entry.rig.devices[site.device] else {
            return RigLibraryEdit(library: self, change: .unchanged)
        }
        var devices = entry.rig.devices
        devices[site.device] = edited
        let rig = try RigLibraryRefusal.wrapping { () throws(RigIdentityRefusal) in
            try RigSavedRig.make(id: entry.id, devices: devices)
        }
        var kept = entries
        kept[site.entry] = RigLibraryEntry(name: entry.name, rig: rig)
        return try replaced(kept, selected: selected)
    }

    private static func rebuilt(_ old: RigSavedDevice, role: RoleID?,
                                required: Bool) throws(RigLibraryRefusal) -> RigSavedDevice {
        try RigLibraryRefusal.wrapping { () throws(RigIdentityRefusal) in
            try RigSavedDevice.make(id: old.id, uid: old.uid, role: role, required: required)
        }
    }

    /// One pass over the observed list; the count is checked as devices are kept, so at most one over the limit
    /// is ever kept before the refusal.
    private static func capturedRig(id: RigProfileID,
                                    observed: [DeviceDescriptor]) throws(RigLibraryRefusal) -> RigSavedRig {
        var devices: [RigSavedDevice] = []
        for descriptor in observed where descriptor.presence == .present
            && !descriptor.identity.evidence.isDisjoint(with: [.deviceUID, .endpointUID]) {
            let device = try RigLibraryRefusal.wrapping { () throws(RigIdentityRefusal) in
                try RigSavedDevice.make(id: descriptor.id, uid: descriptor.identity.uid, role: nil, required: false)
            }
            devices.append(device)
            guard devices.count <= RigIdentityLimits.devicesPerRig else {
                throw .rig(.tooManyDevices(count: devices.count, maximum: RigIdentityLimits.devicesPerRig))
            }
        }
        devices.sort { $0.id.rawValue.utf8.lexicographicallyPrecedes($1.id.rawValue.utf8) }
        return try RigLibraryRefusal.wrapping { () throws(RigIdentityRefusal) in
            try RigSavedRig.make(id: id, devices: devices)
        }
    }
}
