/// Pedals whose release the ledger tracks, by controller number. Declaration order is carry order.
enum MIDIPedal: UInt8, CaseIterable, Hashable, Sendable {
    case sustain = 64
    case sostenuto = 66
}

/// One input holding one pedal down on one route and channel. Ordered by route, channel, pedal, then input.
struct MIDIPedalHold: Hashable, Comparable, Sendable {
    let route: MIDIRouteID
    let channel: UInt8
    let pedal: MIDIPedal
    let input: MIDIInputID

    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.route.rawValue, lhs.channel, lhs.pedal.rawValue, lhs.input.rawValue)
            < (rhs.route.rawValue, rhs.channel, rhs.pedal.rawValue, rhs.input.rawValue)
    }
}

/// One note-on sent to one route. `note` is the transformed note actually sent; every release reuses it.
struct MIDINoteInstance: Equatable, Sendable {
    /// Shared by the instances (one per layer) that one Note On created. A Note Off releases a whole press.
    let press: UInt64
    let input: MIDIInputID
    let channel: UInt8
    let inputNote: UInt8
    let route: MIDIRouteID
    let note: UInt8
    /// The key that started it has not been released.
    var keyDown = true
    /// Released while the route's sustain pedal (CC 64) was down on this channel.
    var sustained = false
    /// Key-down when the route's sostenuto pedal (CC 66) went down on this channel.
    var sostenuto = false
}
