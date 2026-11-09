//
//  ShowTransitionWalkRefusal.swift
//  FluxKlang
//
//  Why a setlist transition walk was refused (#106 STW1).
//

/// The checks run in the order the cases are listed: the setlist must exist, then its stop count must fit under
/// `ShowTransitionWalk.maximumStops`. The last two cases are defensive: the walk makes its own cursor and presses,
/// and no test exercises them.
enum ShowTransitionWalkRefusal: Error, Hashable, Sendable {
    case unknownSetlist(SetlistID)
    /// The exact stop count of the named setlist, not the cap.
    case tooManyStops(Int)
    case showRefused(ShowRefusal)
    case inputIgnored(ShowInputIgnoral)
}
