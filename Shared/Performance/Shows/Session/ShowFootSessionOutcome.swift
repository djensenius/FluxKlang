//
//  ShowFootSessionOutcome.swift
//  FluxKlang
//
//  What a foot session answers and why it refuses (#106 SFS1). A refusal
//  leaves the session unchanged.
//

enum ShowFootSessionOutcome: Hashable, Sendable {
    /// The cursor moved; the stop is where it now is.
    case moved(ShowStop)
    /// The cursor answered and nothing moved: a repeated sequence changes nothing, a bounce records its sequence
    /// and tick.
    case ignored(ShowInputIgnoral)
    /// The command is not navigation for this session; the cursor was not touched.
    case notNavigation(ShowFootIgnoral)
}

enum ShowFootSessionRefusal: Error, Hashable, Sendable {
    /// The adapter refused its bindings or a command.
    case foot(ShowFootInputRefusal)
    /// The cursor refused the navigation input.
    case show(ShowRefusal)
    /// The first footswitch show source, in `ShowFootswitchMap.showSources` order (control source ID order), that
    /// the cursor does not declare.
    case cursorMissingSource(ShowInputSourceID)
    /// `navigate` was handed a show source that the footswitch map owns; those arrive through `deliver`.
    case footSource(ShowInputSourceID)
}
