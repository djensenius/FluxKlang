enum MIDI1ParameterKind: Equatable, Hashable, Sendable {
    /// RPN, selected by CC 101 (MSB) and CC 100 (LSB).
    case registered
    /// NRPN, selected by CC 99 (MSB) and CC 98 (LSB).
    case nonRegistered
}

struct MIDI1ParameterNumber: Hashable, Comparable, Sendable {
    static let coarseTuning = MIDI1ParameterNumber(kind: .registered, msb: 0, lsb: 2)

    let kind: MIDI1ParameterKind
    let msb: UInt8
    let lsb: UInt8

    var isValid: Bool { msb < 0x80 && lsb < 0x80 }

    static func < (lhs: Self, rhs: Self) -> Bool {
        let lhsOrder = lhs.kind == .registered ? 0 : 1
        let rhsOrder = rhs.kind == .registered ? 0 : 1
        return (lhsOrder, lhs.msb, lhs.lsb) < (rhsOrder, rhs.msb, rhs.lsb)
    }
}

struct MIDI1ParameterValue: Equatable, Hashable, Sendable {
    let number: MIDI1ParameterNumber
    let value: UInt16
}

/// Bank is the Bank Select latch (CC 0/32) captured when the Program Change arrived.
struct MIDI1ProgramSelection: Equatable, Hashable, Sendable {
    let bankMSB: UInt8
    let bankLSB: UInt8
    let program: UInt8
}

enum MIDI1VoiceMode: Equatable, Hashable, Sendable {
    case poly
    /// CC 126 value: the number of channels, where 0 means as many as the receiver has voices.
    case mono(channels: UInt8)
}

/// Power-up default is Mode 1: Omni On, Poly.
struct MIDI1ChannelMode: Equatable, Hashable, Sendable {
    var omni = true
    var voices = MIDI1VoiceMode.poly
}
