/// A note held on a channel that is no longer a member channel of the zone that holds it. #82 slice MPX1. Nothing
/// calls it yet.
struct MPEDisplacedNote: Equatable, Sendable {
    let channel: UInt8
    let note: UInt8
    let zone: MPEZone
}

/// Reports what a zone layout change does to the notes an `MPEMemberAllocator` holds. It reports only: it releases,
/// moves and reassigns nothing, and it names no policy for what to do next (none exists in the repository).
enum MPEZoneImpact {
    /// Notes held in `allocator` whose channel is not a member channel of the same zone under `configuration`,
    /// ascending by channel. A channel that became the other zone's member, a manager or unassigned counts as
    /// displaced. Call it BEFORE replacing the allocator; it changes nothing.
    static func displacedNotes(
        in allocator: MPEMemberAllocator, after configuration: MPEZoneConfiguration
    ) -> [MPEDisplacedNote] {
        var displaced: [MPEDisplacedNote] = []
        for zone in MPEZone.allCases {
            let kept = configuration.memberChannels(of: zone)
            for channel in allocator.configuration.memberChannels(of: zone) where !kept.contains(channel) {
                if let note = allocator.note(on: channel) {
                    displaced.append(MPEDisplacedNote(channel: channel, note: note, zone: zone))
                }
            }
        }
        return displaced.sorted { $0.channel < $1.channel }
    }
}
