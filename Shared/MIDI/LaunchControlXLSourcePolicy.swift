//
//  LaunchControlXLSourcePolicy.swift
//  FluxKlang
//

/// How the Launch Control XL's sources are read (#80, #81): the validated receiver profile of every source in its
/// stream and what a change of connected sources does to them. Injected in code only; nothing persists it.
struct LaunchControlXLSourcePolicy: Equatable, Sendable {
    /// What a change of connected sources does. Under either case a resolved unit that leaves, or is rekeyed, loses
    /// its source, and a unit that arrives starts fresh, so no state crosses a replug; a departing unit's half
    /// message is dropped with it. A resolved unit is also rekeyed when a second unit with the same fingerprint
    /// arrives (both become unresolved) or when that second unit leaves, so it loses its half message then too. The
    /// cases differ only for the shared legacy source that unresolved units feed. No timer or timeout is involved.
    enum SourceChange: Equatable, Sendable {
        /// The shared source carries on: a half message, running status or open SysEx survives an unresolved unit's
        /// unplug.
        case keep
        /// The shared source is reset (half message, running status, open SysEx and state dropped) whenever an
        /// unresolved unit joins or leaves it. Other resolved units' sources are not reset, so adding a unit with a
        /// distinct fingerprint never drops another unit's half message. Best effort: packets and source reports
        /// reach the main actor as separate unordered jobs, so a half message received just before an unplug can be
        /// handled after the reset and survive.
        case resetStream
    }

    /// Today's behaviour: `LaunchControlXLMapping.sourceProfile` and `.keep`.
    static let `default` = LaunchControlXLSourcePolicy(
        profile: LaunchControlXLMapping.sourceProfile, sourceChange: .keep
    )

    let profile: MIDISourceProfile
    let sourceChange: SourceChange
}
