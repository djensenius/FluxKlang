//
//  RigIdentityRefusal.swift
//  FluxKlang
//
//  Why a saved rig, or a match of saved rigs against observed devices, is
//  refused, and the bounds that keep a match small. A refusal is never a
//  matching outcome: nothing is matched, selected or activated.
//

/// The documented bounds of identity matching.
enum RigIdentityLimits {
    /// A saved UID is at most this many UTF-8 bytes (the device contract's bound).
    static let uidBytes = 1_024
    /// A saved rig lists at most this many devices.
    static let devicesPerRig = 64
    /// One selection considers at most this many saved rigs.
    static let rigs = 16
    /// One match considers at most this many observed descriptors: the device contract's bound.
    static let observed = DeviceCapabilityLimits.devices
}

/// Why a saved device, a saved rig, or a match is refused.
enum RigIdentityRefusal: Error, Hashable, Sendable {
    /// A saved UID is longer than `RigIdentityLimits.uidBytes` UTF-8 bytes; the payload is its byte count.
    case uidTooLong(Int)
    /// A saved UID is empty or only whitespace.
    case emptyUID
    /// A saved rig lists more devices than `RigIdentityLimits.devicesPerRig`.
    case tooManyDevices(count: Int, maximum: Int)
    /// More saved rigs than `RigIdentityLimits.rigs`.
    case tooManyRigs(count: Int, maximum: Int)
    /// More observed descriptors than `RigIdentityLimits.observed`.
    case tooManyObserved(count: Int, maximum: Int)
    /// Two observed descriptors share a `DeviceID`; the payload is the smallest such id.
    case duplicateObservedDevice(DeviceID)
    /// Two saved rigs share an id; the payload is the smallest such id.
    case duplicateRig(RigProfileID)
    /// One saved rig lists a `DeviceID` twice; the payload is the smallest such id.
    case duplicateDevice(DeviceID)
    /// Two saved devices of one rig share a UID (compared by unicode scalars); the ids are in sorted order.
    case duplicateUID(first: DeviceID, second: DeviceID)
}
