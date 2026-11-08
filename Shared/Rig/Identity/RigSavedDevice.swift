//
//  RigSavedDevice.swift
//  FluxKlang
//
//  A saved rig and the devices it expects. A device is expected by its UID,
//  never by its model, its transport, its channel layout, its `DeviceID` or
//  its USB position. Values are built by throwing factories; a hand-built
//  `RigSavedRig` is re-validated by every match and selection.
//

import Foundation

enum RigProfileTag: ContractIDTag {}
/// The id of a saved rig.
typealias RigProfileID = ContractID<RigProfileTag>

/// A device UID compared and hashed by unicode scalars. `String ==` would merge canonically equivalent
/// spellings of two distinct UIDs; this type never does.
struct RigUID: Hashable, Sendable {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.text.unicodeScalars.elementsEqual(rhs.text.unicodeScalars) }
    func hash(into hasher: inout Hasher) { for scalar in text.unicodeScalars { hasher.combine(scalar.value) } }
}

/// One device a saved rig expects, identified by its UID.
struct RigSavedDevice: Hashable, Sendable {
    /// The `DeviceID` the rig last saw. It is a label, never identity: a UID found under another id is renumbered.
    let id: DeviceID
    /// The identity: 1...1,024 UTF-8 bytes, not blank. Stored as text and compared only through `RigUID`, which
    /// compares unicode scalars, never `String ==`.
    let uid: String
    let role: RoleID?
    /// A required device lowers the operating mode when it is not matched; an optional one never does.
    let required: Bool

    private init(id: DeviceID, uid: String, role: RoleID?, required: Bool) {
        self.id = id
        self.uid = uid
        self.role = role
        self.required = required
    }

    /// Refuses a UID over `RigIdentityLimits.uidBytes` UTF-8 bytes (`uidTooLong`) before a blank one (`emptyUID`).
    static func make(id: DeviceID, uid: String, role: RoleID?,
                     required: Bool) throws(RigIdentityRefusal) -> RigSavedDevice {
        let bytes = uid.utf8.count
        guard bytes <= RigIdentityLimits.uidBytes else { throw .uidTooLong(bytes) }
        guard !uid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw .emptyUID }
        return RigSavedDevice(id: id, uid: uid, role: role, required: required)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && RigUID(lhs.uid) == RigUID(rhs.uid) && lhs.role == rhs.role && lhs.required == rhs.required
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(RigUID(uid))
        hasher.combine(role)
        hasher.combine(required)
    }
}

/// A saved rig: an id and the devices it expects. The memberwise initializer builds a rig without validation;
/// `RigIdentityMatcher.match` and `RigSelection.choose` re-validate it.
struct RigSavedRig: Hashable, Sendable {
    let id: RigProfileID
    private(set) var devices: [RigSavedDevice]

    /// A validated rig. An empty rig is legal.
    static func make(id: RigProfileID, devices: [RigSavedDevice]) throws(RigIdentityRefusal) -> RigSavedRig {
        let rig = RigSavedRig(id: id, devices: devices)
        try rig.validate()
        return rig
    }

    /// Refuses, in this order: too many devices, a repeated `DeviceID`, a repeated UID. The count is checked
    /// before any work that depends on it. Ids reported are the smallest by raw id, so input order is irrelevant.
    func validate() throws(RigIdentityRefusal) {
        guard devices.count <= RigIdentityLimits.devicesPerRig else {
            throw .tooManyDevices(count: devices.count, maximum: RigIdentityLimits.devicesPerRig)
        }
        let sorted = devices.sorted { $0.id < $1.id }
        for (earlier, later) in zip(sorted, sorted.dropFirst()) where earlier.id == later.id {
            throw .duplicateDevice(earlier.id)
        }
        var firstByUID: [RigUID: DeviceID] = [:]
        for device in sorted {
            if let first = firstByUID[RigUID(device.uid)] { throw .duplicateUID(first: first, second: device.id) }
            firstByUID[RigUID(device.uid)] = device.id
        }
    }
}
