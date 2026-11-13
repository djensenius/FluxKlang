/// Expression values (MPE "pressure", "slide" and "bend") of one source: a member channel or a zone's manager channel.
/// These are OUTPUT report values: the memberwise initialiser is internal (tests build expected values with it), a
/// caller-built value carries no validity guarantee, and nothing in the module accepts one as input.
struct MPEExpressionValues: Equatable, Sendable {
    /// The pitch bend value at rest (the centre of 0...16383).
    static let neutralPitchBend: UInt16 = 8192

    /// Channel pressure 0...127; 0 until a message arrives.
    let pressure: UInt8
    /// Controller 74 value 0...127; 0 until a message arrives.
    let slide: UInt8
    /// The raw 14-bit pitch bend 0...16383.
    let pitchBend: UInt16
    /// The bend in cents for the caller-supplied range: `(pitchBend - 8192) * range * 100 / 8192`, truncated toward
    /// zero. It is not summed with another source's bend; the member and zone values are reported separately.
    let bendCents: Int
}

/// One bound note with its own member-channel values and the values of its zone's manager channel. Like
/// `MPEExpressionValues` it is an output report value with an internal memberwise initialiser and no validity
/// guarantee when caller-built.
struct MPEExpressionEntry: Equatable, Sendable {
    let channel: UInt8
    let note: UInt8
    let member: MPEExpressionValues
    let zone: MPEExpressionValues
}

/// What an expression message touched: one member channel, or a whole zone through its manager channel. `entries`
/// lists the affected bound notes in ascending channel order; a member message before Note On, or a manager message
/// with no bound note in the zone, has an empty list but still updates its channel or zone values. An output report
/// value, like the two types above.
struct MPEExpressionUpdate: Equatable, Sendable {
    enum Target: Equatable, Sendable {
        case memberChannel(channel: UInt8)
        case zone(MPEZone)
    }

    let target: Target
    let entries: [MPEExpressionEntry]
}

/// Tracks channel pressure, pitch bend and controller 74 on member channels independently of note bindings, and
/// applies the same messages on a manager channel to every note in its zone. The bend range is caller-supplied,
/// 1...96 semitones, with no fallback. Only `make` builds one. Its bindings are independent of `MPEMemberAllocator`:
/// the caller keeps the two in sync, and binding a note to a channel the allocator did not hand out is not checked.
struct MPENoteExpression: Equatable, Sendable {
    static let bendRangeSemitones = 1...96
    static let slideController: UInt8 = 74

    let configuration: MPEZoneConfiguration
    let bendRange: Int

    private struct Raw: Equatable, Sendable {
        var pressure: UInt8 = 0
        var slide: UInt8 = 0
        var pitchBend: UInt16 = MPEExpressionValues.neutralPitchBend
    }

    private struct Bound: Equatable, Sendable {
        let note: UInt8
    }

    private enum Change {
        case pressure(UInt8)
        case slide(UInt8)
        case pitchBend(UInt16)
    }

    private var bound: [Bound?]
    private var memberRaw: [Raw]
    private var zoneRaw: [Raw]

    private init(configuration: MPEZoneConfiguration, bendRange: Int) {
        self.configuration = configuration
        self.bendRange = bendRange
        bound = Array(repeating: nil, count: 16)
        memberRaw = Array(repeating: Raw(), count: 16)
        zoneRaw = Array(repeating: Raw(), count: MPEZone.allCases.count)
    }

    /// Refuses a bend range outside 1...96 semitones.
    static func make(
        configuration: MPEZoneConfiguration, bendRange: Int
    ) throws(MPERefusal) -> MPENoteExpression {
        guard bendRangeSemitones.contains(bendRange) else { throw .invalidBendRange(bendRange) }
        return MPENoteExpression(configuration: configuration, bendRange: bendRange)
    }

    func boundNote(on channel: UInt8) -> UInt8? {
        guard (1...16).contains(channel) else { return nil }
        return bound[Int(channel) - 1]?.note
    }

    /// The member channel's own values, or nil when no note is bound there.
    func memberValues(on channel: UInt8) -> MPEExpressionValues? {
        guard (1...16).contains(channel), bound[Int(channel) - 1] != nil else { return nil }
        return values(memberRaw[Int(channel) - 1])
    }

    /// The raw values stored for a member channel, or nil for an invalid or non-member channel.
    func memberChannelValues(on channel: UInt8) -> MPEExpressionValues? {
        guard (1...16).contains(channel),
              let role = try? MPEChannelClassifier.role(of: channel, in: configuration),
              case .member = role else { return nil }
        return values(memberRaw[Int(channel) - 1])
    }

    func zoneValues(_ zone: MPEZone) -> MPEExpressionValues {
        values(zoneRaw[Self.index(of: zone)])
    }

    /// Binds `note` to a member channel with its current channel values. Refuses, in this order: a channel outside
    /// 1...16, a note above 127, a channel that is not a member channel, a channel already bound, a note already
    /// bound to another member channel of the same zone.
    mutating func bind(note: UInt8, channel: UInt8) throws(MPERefusal) {
        let role = try MPEChannelClassifier.role(of: channel, in: configuration)
        guard note <= 127 else { throw .invalidNote(note) }
        guard case let .member(zone) = role else { throw .notMemberChannel(channel) }
        guard bound[Int(channel) - 1] == nil else { throw .channelAlreadyBound(channel) }
        for other in configuration.memberChannels(of: zone) where bound[Int(other) - 1]?.note == note {
            throw .noteAlreadyBound(note)
        }
        bound[Int(channel) - 1] = Bound(note: note)
    }

    /// Frees the member channel and returns the note it carried; nil (and no change) when nothing was bound.
    @discardableResult
    mutating func unbind(channel: UInt8) -> UInt8? {
        guard (1...16).contains(channel), let slot = bound[Int(channel) - 1] else { return nil }
        bound[Int(channel) - 1] = nil
        return slot.note
    }

    /// Applies channel pressure, pitch bend or controller 74. Refuses, in this order: any other message, a channel
    /// outside 1...16, a value above 127 (16383 for pitch bend), or a channel with no role. A member channel's values
    /// update even with no bound note; on a manager channel the zone values update for every bound note.
    mutating func apply(_ semantic: MIDI1Semantic) throws(MPERefusal) -> MPEExpressionUpdate {
        let (channel, change) = try Self.parse(semantic)
        let role = try MPEChannelClassifier.role(of: channel, in: configuration)
        try Self.requireInRange(change)
        switch role {
        case .unassigned:
            throw .unboundChannel(channel)
        case let .member(zone):
            Self.write(change, to: &memberRaw[Int(channel) - 1])
            let entries = bound[Int(channel) - 1].map {
                [entry(channel: channel, slot: $0, zone: zone)]
            } ?? []
            return MPEExpressionUpdate(
                target: .memberChannel(channel: channel), entries: entries
            )
        case let .manager(zone):
            Self.write(change, to: &zoneRaw[Self.index(of: zone)])
            let entries = configuration.memberChannels(of: zone).sorted().compactMap { member in
                bound[Int(member) - 1].map { entry(channel: member, slot: $0, zone: zone) }
            }
            return MPEExpressionUpdate(target: .zone(zone), entries: entries)
        }
    }

    private static func index(of zone: MPEZone) -> Int {
        zone == .lower ? 0 : 1
    }

    private static func parse(_ semantic: MIDI1Semantic) throws(MPERefusal) -> (UInt8, Change) {
        switch semantic {
        case let .channelPressure(source, pressure):
            return (source, .pressure(pressure))
        case let .controlChange(source, controller, value) where controller == slideController:
            return (source, .slide(value))
        case let .pitchBend(source, value):
            return (source, .pitchBend(value))
        default:
            throw .notExpressionMessage
        }
    }

    private static func requireInRange(_ change: Change) throws(MPERefusal) {
        switch change {
        case let .pressure(value), let .slide(value):
            guard value <= 127 else { throw .valueOutOfRange(UInt16(value)) }
        case let .pitchBend(value):
            guard value <= 16_383 else { throw .valueOutOfRange(value) }
        }
    }

    private static func write(_ change: Change, to raw: inout Raw) {
        switch change {
        case let .pressure(value): raw.pressure = value
        case let .slide(value): raw.slide = value
        case let .pitchBend(value): raw.pitchBend = value
        }
    }

    private func values(_ raw: Raw) -> MPEExpressionValues {
        MPEExpressionValues(
            pressure: raw.pressure, slide: raw.slide, pitchBend: raw.pitchBend,
            bendCents: (Int(raw.pitchBend) - Int(MPEExpressionValues.neutralPitchBend)) * bendRange * 100 / 8192
        )
    }

    private func entry(channel: UInt8, slot: Bound, zone: MPEZone) -> MPEExpressionEntry {
        MPEExpressionEntry(
            channel: channel, note: slot.note, member: values(memberRaw[Int(channel) - 1]), zone: zoneValues(zone)
        )
    }
}
