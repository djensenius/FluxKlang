//
//  WorkspaceStatusSourceRefusal.swift
//  FluxKlang
//
//  Why a list of devices could not become the status strip's device rows (#99 WSS1).
//

enum WorkspaceStatusSourceRefusal: Error, Equatable, Sendable {
    /// More descriptors than `WorkspaceStatusSources.maximumDevices`. Reported before anything else.
    case tooManyDevices(count: Int, maximum: Int)
    /// One device id appears more than once; carries the smallest such id by UTF-8 bytes.
    case duplicateDevice(DeviceID)
    /// The caller's table has no display name for the device; carries the smallest such id by UTF-8 bytes.
    case missingName(DeviceID)
}
