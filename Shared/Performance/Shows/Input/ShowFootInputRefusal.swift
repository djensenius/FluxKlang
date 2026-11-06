//
//  ShowFootInputRefusal.swift
//  FluxKlang
//
//  Typed refusals of the footswitch-to-navigation adapter (#106 SH3).
//  A refused call builds nothing and changes nothing.
//

enum ShowFootInputRefusal: Error, Hashable, Sendable {
    /// More than `ShowFootswitchMap.maximumTargets` navigation targets were supplied.
    case tooManyTargets(Int)
    /// More than `ShowFootswitchMap.maximumSources` (`ShowLimits.maximumInputSources`) control sources were supplied.
    case tooManySources(Int)
    /// Two control sources map onto one show source, so its sequence would come from two streams. Reported for the
    /// first repeated show source met in control source ID order, with its first two claimants in that order.
    case duplicateShowSource(ShowInputSourceID, first: ControlSourceID, second: ControlSourceID)
    /// More than `ControlTriggerDetector.maximumBindings` bindings were supplied.
    case tooManyBindings(Int)
    /// Two supplied bindings share one ID, so a command could not be traced to one binding.
    case duplicateBinding(BindingID)
    /// Navigation is momentary: a toggle or latch binding on a navigation target is refused.
    case statefulNavigationBinding(BindingID, ControlTriggerMode)
    /// A control source on a navigation target has no show source.
    case unmappedSource(ControlSourceID)
    /// A command on a navigation target does not come from a binding the adapter validated for it: its binding ID
    /// is unknown, its target or source differs from that binding's, or it is a `switchedOn` / `switchedOff` with
    /// cause `.input`; host-caused commands that pass the binding check are never refused.
    case bindingTargetUnknown(BindingID)
}
