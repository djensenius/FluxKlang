/// Assigns notes to the member channels of the zones of one configuration, one note per channel. Allocation is
/// round-robin: each zone keeps a cursor just after the member it allocated last, and the next allocation takes the
/// first free member from the cursor onward, wrapping once (an open owner question: the alternatives are one global
/// cursor or always the lowest free member). The first allocation of a zone therefore takes its lowest
/// member. Nothing is ever stolen: when every member holds a note the allocation is refused. Only `make` builds one.
struct MPEMemberAllocator: Equatable, Sendable {
    let configuration: MPEZoneConfiguration
    /// Index 0 is channel 1. A manager, an unassigned channel and a free member hold nil.
    private(set) var holders: [UInt8?]
    private(set) var lowerCursor: Int
    private(set) var upperCursor: Int

    private init(configuration: MPEZoneConfiguration) {
        self.configuration = configuration
        holders = Array(repeating: nil, count: 16)
        lowerCursor = 0
        upperCursor = 0
    }

    /// A fresh allocator with every member free. Throws nothing today beyond what the validated configuration already
    /// guarantees; the throwing signature keeps every construction path a factory.
    static func make(configuration: MPEZoneConfiguration) throws(MPERefusal) -> MPEMemberAllocator {
        _ = try MPEZoneConfiguration.make(
            lowerMembers: configuration.lowerMembers, upperMembers: configuration.upperMembers
        )
        return MPEMemberAllocator(configuration: configuration)
    }

    /// The number of notes the zone can hold: its member count.
    func capacity(of zone: MPEZone) -> Int {
        configuration.memberCount(zone)
    }

    func heldCount(in zone: MPEZone) -> Int {
        configuration.memberChannels(of: zone).filter { holders[Int($0) - 1] != nil }.count
    }

    /// The note held by `channel`, or nil for a free, manager, unassigned or out-of-range channel.
    func note(on channel: UInt8) -> UInt8? {
        guard (1...16).contains(channel) else { return nil }
        return holders[Int(channel) - 1]
    }

    /// The member channel holding `note` in `zone`, or nil.
    func channel(of note: UInt8, in zone: MPEZone) -> UInt8? {
        configuration.memberChannels(of: zone).first { holders[Int($0) - 1] == note }
    }

    /// Refuses, in this order: a note above 127, a zone that is off, every member busy. A note already held in the
    /// zone returns its channel and changes nothing.
    mutating func allocate(note: UInt8, zone: MPEZone) throws(MPERefusal) -> UInt8 {
        guard note <= 127 else { throw .invalidNote(note) }
        let members = configuration.memberChannels(of: zone)
        guard !members.isEmpty else { throw .zoneOff(zone) }
        if let existing = channel(of: note, in: zone) { return existing }
        let start = zone == .lower ? lowerCursor : upperCursor
        for offset in 0..<members.count {
            let index = (start + offset) % members.count
            let channel = members[index]
            if holders[Int(channel) - 1] == nil {
                holders[Int(channel) - 1] = note
                let next = (index + 1) % members.count
                if zone == .lower { lowerCursor = next } else { upperCursor = next }
                return channel
            }
        }
        throw .membersExhausted(zone)
    }

    /// Frees the channel holding `note` in `zone` and returns true; false (and no change) for a note that is not
    /// held there. The cursor does not move.
    @discardableResult
    mutating func release(note: UInt8, zone: MPEZone) -> Bool {
        guard let channel = channel(of: note, in: zone) else { return false }
        holders[Int(channel) - 1] = nil
        return true
    }
}
