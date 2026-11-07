//
//  RemoteDispatchRefusal.swift
//  FluxKlang
//
//  Typed refusals of the remote mirror and the local-MIDI dispatcher (#96, RR2). A refusal is a value:
//  building a mirror throws it and `RemoteControlDispatch.propose` returns it in the result.
//

/// Why a mirror was not built, a call was refused as a whole, or one binding was refused.
enum RemoteDispatchRefusal: Error, Hashable, Sendable {
    /// No synced state to mirror: the receiver awaits a snapshot or a resync, or no mirror was supplied.
    case mirrorUnavailable
    /// More received values than `ControlHostTruth.maximumValues`; carries the received count.
    case tooManyValues(Int)
    /// A received value names a parameter the catalog does not know; carries the smallest such id.
    case unknownParameter(ParameterID)

    /// The role is not `.remoteController` (standalone, or the host was lost).
    case notRemoteController(RemoteRoleKind)
    /// The guard allows no peer command for this role; today that is the `observer` grant.
    case observerHasNoCommands
    /// The message is raw input as `RemoteRoleGuard.classify` sorts it (note, clock or other) and is refused.
    case rawInput(RawInputClass)
    /// The mirror belongs to another host than the one this role controls.
    case staleSession
    /// The update carries no control input a source id can be derived from.
    case intake(ControlIntakeRefusal)
    /// More bindings than `RemoteControlDispatch.maximumBindings`; carries the supplied count.
    case tooManyBindings(Int)
    /// A binding id appears more than once; carries the smallest such id.
    case duplicateBinding(BindingID)

    /// A matched binding has no entry in the pickup table.
    case pickupStateMissing(BindingID)
    /// The update does not fit this binding's encoder profile, for example its width or its range.
    case bindingIntake(BindingID, ControlIntakeRefusal)
    /// The binding itself refused: its pickup state, the host truth for its target, or its mapping.
    case binding(BindingID, ControlBindingRefusal)
}
