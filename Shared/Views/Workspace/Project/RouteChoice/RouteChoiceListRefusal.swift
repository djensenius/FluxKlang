//
//  RouteChoiceListRefusal.swift
//  FluxKlang
//
//  Why `RouteChoiceList.make` refuses its input (#100 MAP1). Every case names the first offender, in the order the
//  checks run. Nothing calls it yet.
//

enum RouteChoiceListRefusal: Error, Hashable, Sendable {
    /// More existing routes than `DeviceCapabilityLimits.routes`.
    case tooManyRoutes(count: Int, maximum: Int)
    /// A role the list shows (the target role, or one that claims a row) has no caller-supplied label.
    case missingRoleLabel(RoleID)
    /// A role label whose UTF-8 byte count is outside `RouteChoiceLimits.nameBytes`.
    case invalidRoleLabelLength(RoleID, bytes: Int)
    /// More candidates than `RigMappingLimits.candidatesPerRole`.
    case tooManyCandidates(count: Int, maximum: Int)
    /// The first candidate, in source order, that was made for another role.
    case candidateForOtherRole(RoleID)
    /// The first candidate, in source order, whose direction or width differs from the requirement.
    case candidateDoesNotFit(device: DeviceID, firstChannel: Int)
    /// A candidate's device has no caller-supplied name; the smallest such ID, by UTF-8 bytes.
    case missingDeviceName(DeviceID)
    /// A device name whose UTF-8 byte count is outside `RouteChoiceLimits.nameBytes`.
    case invalidDeviceNameLength(DeviceID, bytes: Int)
}

enum RouteChoiceLimits {
    /// The UTF-8 byte count of a device name or a role label. The same bound as `ContractID.maximumLength`.
    static let nameBytes = 1...128
}
