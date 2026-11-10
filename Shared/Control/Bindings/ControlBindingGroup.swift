import Foundation

enum BindingGroupTag: ContractIDTag {}
typealias BindingGroupID = ContractID<BindingGroupTag>

/// One control fanned out to several existing bindings, in declared order. Members must share one source and one
/// encoder profile and write distinct targets. Scaling follows the shared profile: a relative group steps each
/// member by its own step from its own host value, clamping each independently; an absolute group maps one
/// position over each member's own writable range under each member's own pickup.
struct ControlBindingGroupFields: ControlFields {
    static let knownKeys: Set<String> = ["id", "members"]
    static let maximumMembers = 64
    /// The most bindings a caller may supply to look members up in.
    static let maximumBindings = ControlBindingLimit.maximumBindings
    let id: BindingGroupID
    let members: [BindingID]

    func validate() throws {
        guard (1...Self.maximumMembers).contains(members.count) else {
            throw ControlValidationError.invalid("Binding group needs 1...64 members")
        }
        try ContractUniqueness.require(members)
    }
}
typealias ControlBindingGroup = ControlRecord<ControlBindingGroupFields>

/// The group as a whole cannot resolve: its definition no longer matches the supplied bindings, or the caller's
/// pickup states are incomplete. Nothing is fanned out.
enum ControlBindingGroupRefusal: Error, Hashable, Sendable {
    /// More than `ControlBindingGroupFields.maximumBindings` bindings were supplied.
    case tooManyBindings(Int)
    /// The supplied bindings hold two bindings with one ID, so members cannot be named unambiguously.
    case duplicateBinding(BindingID)
    /// A member is not among the supplied bindings (for example it was deleted); the group is stale.
    case memberMissing(BindingID)
    case mixedSource(BindingID, expected: ControlSourceID, found: ControlSourceID)
    case mixedProfile(BindingID, expected: EncoderProfile, found: EncoderProfile)
    /// Two members write one parameter, so the fan-out would depend on order.
    case duplicateTarget(ParameterID)
    /// The caller holds no pickup state for a member.
    case stateMissing(BindingID)
}

/// What one member did with the group's input.
enum ControlGroupMemberOutcome: Hashable, Sendable {
    /// The caller stores the resolution's new state for this member.
    case resolved(PickupResolution)
    /// This member alone is refused; the caller keeps its previous state.
    case refused(ControlBindingRefusal)
}

struct ControlGroupMemberResolution: Hashable, Sendable {
    let binding: BindingID
    let outcome: ControlGroupMemberOutcome
}
