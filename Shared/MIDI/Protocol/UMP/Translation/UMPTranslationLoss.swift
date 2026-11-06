/// Why a translated message lost information. Every loss is declared and counted; nothing is dropped silently.
///
/// The MIDI 2.0 → MIDI 1.0 reasons mirror the SMF export loss categories of media-contract §9.3.
enum UMPTranslationLossReason: Equatable, Hashable, Sendable, CaseIterable {
    // MIDI 1.0 → MIDI 2.0 (incomplete MIDI 1.0 sequences).
    /// A Program Change arrived after only one of Bank Select MSB (CC 0) and LSB (CC 32); it is sent with
    /// Bank Valid clear.
    case incompleteBankSelect
    /// Data Entry (CC 6 or CC 38) arrived with no complete RPN/NRPN selected, or with the null RPN (127/127)
    /// selected; nothing is sent.
    case dataEntryWithoutParameter
    /// Data Entry LSB (CC 38) arrived before any Data Entry MSB (CC 6) for the selected parameter; nothing is sent.
    case dataEntryLSBWithoutMSB

    // MIDI 2.0 → MIDI 1.0 (messages or fields MIDI 1.0 cannot carry).
    /// Registered or assignable per-note controllers (MT 0x4 status 0x0 and 0x1); nothing is sent.
    case perNoteController
    /// Per-note pitch bend (status 0x6); nothing is sent.
    case perNotePitchBend
    /// Per-note management (status 0xF); nothing is sent.
    case perNoteManagement
    /// Relative registered or assignable controllers (status 0x4 and 0x5); nothing is sent.
    case relativeController
    /// A MIDI 2.0 Control Change on an index MIDI 2.0 replaces with dedicated messages (Bank Select 0/32, Data
    /// Entry 6/38, NRPN 98/99, RPN 100/101); nothing is sent, so the translator's bank and parameter state stay true.
    case controllerReservedInMIDI2
    /// A registered controller at bank 127, index 127: in MIDI 1.0 that address is the null RPN; nothing is sent.
    case nullParameterAddress
    /// A Note On or Off had an attribute type or attribute value other than 0; the note is sent without it.
    case attributeDropped
    /// A MIDI 2.0 Note On whose velocity scales down to 0 is sent with velocity 1, so it stays a Note On.
    case noteOnVelocityRemapped
    /// A 16-bit velocity is not the min-centre-max upscale of its top 7 bits; the top 7 bits are sent.
    case velocityDownscaled
    /// A 32-bit value is not the min-centre-max upscale of its top 7 (or 14) bits; the top bits are sent.
    case valueDownscaled
}

/// One declared loss, attributed to the group and channel of the message that caused it.
struct UMPTranslationLoss: Equatable, Sendable {
    let reason: UMPTranslationLossReason
    let group: UMPGroup
    let channel: UMPChannel
}

/// Running totals of declared losses, one count per reason.
struct UMPTranslationLossCounts: Equatable, Sendable {
    private var storedCounts: [UMPTranslationLossReason: Int] = [:]

    init() {}

    /// How many losses with `reason` have been declared.
    func count(_ reason: UMPTranslationLossReason) -> Int { storedCounts[reason] ?? 0 }

    /// All declared losses.
    var total: Int { storedCounts.values.reduce(0, +) }

    /// Adds one to the count of each loss's reason.
    mutating func record(_ losses: [UMPTranslationLoss]) {
        for loss in losses { storedCounts[loss.reason, default: 0] += 1 }
    }
}

/// What one translated message produced: zero or more messages in the other protocol, plus its declared losses.
///
/// Empty `messages` with empty `losses` means the input only updated translator state (a Bank Select, or an RPN or
/// NRPN selection, waiting for its Program Change or Data Entry).
struct UMPTranslationOutput<Message: Equatable & Sendable>: Equatable, Sendable {
    let messages: [Message]
    let losses: [UMPTranslationLoss]
}
