/// Which MIDI 1.0 parameter-number family a Data Entry addresses: RPN (CC 101/100) → MIDI 2.0 Registered
/// Controller, NRPN (CC 99/98) → MIDI 2.0 Assignable Controller.
enum UMPParameterKind: Equatable, Sendable {
    case registered
    case assignable
}

/// A complete RPN or NRPN address: bank is the selection MSB (CC 101 or 99), index the LSB (CC 100 or 98).
struct UMPParameterAddress: Equatable, Sendable {
    let kind: UMPParameterKind
    let bank: UMPSevenBit
    let index: UMPSevenBit

    /// RPN 127/127 is the MIDI 1.0 null RPN: it deselects, so Data Entry after it addresses nothing.
    /// NRPN 127/127 is an ordinary address here, because MIDI 2.0 Assignable Controller 127/127 is one. Hazard (kept
    /// as implemented): downward, Assignable Controller 127/127 is sent as NRPN 127/127, which some MIDI 1.0
    /// receivers treat as a null selection and so ignore the Data Entry that follows.
    var isNull: Bool { kind == .registered && bank.value == 127 && index.value == 127 }
}

/// MIDI 1.0 → MIDI 2.0 state of one group and channel.
///
/// - Bank Select MSB and LSB persist (as in MIDI 1.0) until replaced; a Program Change does not clear them.
/// - RPN/NRPN selection bytes persist until replaced. Selecting the other family clears both bytes first, so a
///   mixed RPN MSB + NRPN LSB pair never forms an address. Any selection byte clears the Data Entry MSB.
/// - The Data Entry MSB is the last CC 6 value for the current selection; CC 38 combines with it. Data Increment or
///   Decrement (CC 96/97) forgets it, because the receiver's value is then unknown. The controller a CC 6 produced,
///   waiting for its CC 38, is held by `UMPMIDI1ToMIDI2Translator` (one slot for all groups and channels).
struct UMPUpChannelState: Equatable, Sendable {
    var bankMSB: UMPSevenBit?
    var bankLSB: UMPSevenBit?
    var parameterKind: UMPParameterKind?
    var parameterMSB: UMPSevenBit?
    var parameterLSB: UMPSevenBit?
    var dataEntryMSB: UMPSevenBit?

    init() {}

    /// The selected address, or nil while either selection byte is missing.
    var parameter: UMPParameterAddress? {
        guard let parameterKind, let parameterMSB, let parameterLSB else { return nil }
        return UMPParameterAddress(kind: parameterKind, bank: parameterMSB, index: parameterLSB)
    }

    /// Bank Valid needs both Bank Select bytes. Project decision: a missing byte is not guessed (the references
    /// differ); see `UMPMIDI1ToMIDI2Translator`.
    var bank: UMPBankSelect? {
        guard let bankMSB, let bankLSB else { return nil }
        return UMPBankSelect(msb: bankMSB, lsb: bankLSB)
    }

    /// Records one RPN/NRPN selection byte (`isMSB` for CC 101/99, otherwise CC 100/98).
    mutating func select(_ kind: UMPParameterKind, isMSB: Bool, value: UMPSevenBit) {
        if parameterKind != kind {
            parameterKind = kind
            parameterMSB = nil
            parameterLSB = nil
        }
        if isMSB { parameterMSB = value } else { parameterLSB = value }
        dataEntryMSB = nil
    }

    /// Reset All Controllers (CC 121): the RPN/NRPN selection and Data Entry MSB are forgotten; the bank is kept.
    mutating func resetAllControllers() {
        parameterKind = nil
        parameterMSB = nil
        parameterLSB = nil
        dataEntryMSB = nil
    }
}

/// MIDI 2.0 → MIDI 1.0 state of one group and channel: what the MIDI 1.0 receiver has already been sent, so
/// unchanged Bank Select, RPN/NRPN selection and Data Entry MSB bytes are not repeated.
struct UMPDownChannelState: Equatable, Sendable {
    var bank: UMPBankSelect?
    var parameter: UMPParameterAddress?
    var dataEntryMSB: UMPSevenBit?

    init() {}

    /// Reset All Controllers (CC 121) sent to the receiver: its selection is null and its Data Entry MSB unknown,
    /// so the next parameter write resends them; the bank is kept.
    mutating func resetAllControllers() {
        parameter = nil
        dataEntryMSB = nil
    }
}

/// Fixed-size per-group, per-channel state: exactly 16 groups × 16 channels, so it never grows.
struct UMPTranslationTable<Element: Equatable & Sendable>: Equatable, Sendable {
    /// 16 groups × 16 channels.
    static var capacity: Int { 256 }

    private var storedElements: [Element]

    init(repeating element: Element) {
        storedElements = Array(repeating: element, count: Self.capacity)
    }

    subscript(group: UMPGroup, channel: UMPChannel) -> Element {
        get { storedElements[Int(group.value) * 16 + Int(channel.value)] }
        set { storedElements[Int(group.value) * 16 + Int(channel.value)] = newValue }
    }
}
