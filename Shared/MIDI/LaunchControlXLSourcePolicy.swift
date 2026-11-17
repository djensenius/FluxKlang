//
//  LaunchControlXLSourcePolicy.swift
//  FluxKlang
//

/// How the Launch Control XL's one logical source is read (#80): the validated receiver profile of its stream and
/// what a change of matched sources does to that stream. Injected in code only; nothing persists it. Per-sender
/// selection belongs to #81.
struct LaunchControlXLSourcePolicy: Equatable, Sendable {
    /// What a change of the matched source names does to the stream. CoreMIDI reports display names, not endpoint
    /// identities, and every matched endpoint feeds the one stream, so only a different sorted name list counts as
    /// a change. No timer or timeout is involved.
    enum SourceChange: Equatable, Sendable {
        /// The stream carries on: a half message, running status or open SysEx survives an unplug.
        case keep
        /// The stream is reset (half message, running status, open SysEx and state dropped) whenever the sorted
        /// name list differs from the last one seen since the current start. Best effort: packets and source
        /// reports reach the main actor as separate unordered jobs, so a half message received just before an
        /// unplug can be handled after the reset and survive. Adding a source also resets, dropping another
        /// source's half message.
        case resetStream
    }

    /// Today's behaviour: `LaunchControlXLMapping.sourceProfile` and `.keep`.
    static let `default` = LaunchControlXLSourcePolicy(
        profile: LaunchControlXLMapping.sourceProfile, sourceChange: .keep
    )

    let profile: MIDISourceProfile
    let sourceChange: SourceChange
}
