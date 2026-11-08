/// One mapping of a received Program Change to a target: the input source and channel it arrived on, the program, and
/// the Bank Select values (MSB, LSB) that were latched when it arrived. A nil bank part means any value. A caller
/// builds the carrier freely; `ProgramRecallTable.make` validates it.
struct ProgramRecallEntry: Equatable, Sendable {
    let input: MIDIInputID
    /// MIDI channel, 1...16.
    let channel: UInt8
    /// Bank Select MSB in 0...127, or nil for any.
    let bankMSB: UInt8?
    /// Bank Select LSB in 0...127, or nil for any.
    let bankLSB: UInt8?
    /// Program in 0...127.
    let program: UInt8
    let target: ControlTriggerTargetID
}

/// What a table answers for one received Program Change.
enum ProgramRecallOutcome: Equatable, Sendable {
    case mapped(ControlTriggerTargetID)
    case unmapped
}

/// A validated, immutable table from (input, channel, bank, program) to a target. It fires, sends and remembers
/// nothing: `mapped` is a lookup answer, not an authorization, and `resolve` does not change the table. A Bank Select
/// latch that was never written reads (0, 0) like an explicit Bank Select 0/0, so an exact (0, 0) entry and a
/// wildcard both match it.
struct ProgramRecallTable: Equatable, Sendable {
    /// The most entries a table may hold; 256 are accepted and 257 are refused.
    static let maximumEntries = 256
    /// The valid MIDI channels.
    static let channels: ClosedRange<UInt8> = 1...16
    /// The largest program or Bank Select value.
    static let maximumValue: UInt8 = 127

    /// The entries in the order the caller gave them; the order never changes which target a lookup returns.
    let entries: [ProgramRecallEntry]

    private init(entries: [ProgramRecallEntry]) {
        self.entries = entries
    }

    /// Builds a table. Refuses, in this order: more than `maximumEntries` entries; then, entry by entry in index order
    /// (channel, then bank MSB and LSB, then program, all of one entry before the next); then, only when every entry
    /// is valid, the first overlapping pair of equal specificity. Specificity is the number of non-nil bank parts.
    /// Entries of unequal specificity may overlap: the more specific one wins. An empty list gives an empty table.
    static func make(_ entries: [ProgramRecallEntry]) throws(ProgramRecallRefusal) -> Self {
        guard entries.count <= maximumEntries else { throw .tooManyEntries(entries.count) }
        try validate(entries)
        try requireNoEqualOverlap(entries)
        return Self(entries: entries)
    }

    /// Looks up one received Program Change. The channel and the selection are re-validated first (channel, then
    /// selection); an entry matches when input, channel and program are equal and each bank part is nil or equal. The
    /// matching entry of highest specificity wins; nothing matching, or an empty table, is `unmapped`. Input and
    /// channel are exact: there is no omni.
    func resolve(
        input: MIDIInputID,
        channel: UInt8,
        selection: MIDI1ProgramSelection
    ) throws(ProgramRecallRefusal) -> ProgramRecallOutcome {
        guard Self.channels.contains(channel) else { throw .invalidReceivedChannel(channel) }
        guard Self.isValidSelection(selection) else { throw .invalidReceivedSelection(selection) }
        var winner: ControlTriggerTargetID?
        var winnerSpecificity = -1
        for entry in entries where Self.matches(entry, input: input, channel: channel, selection: selection) {
            let specificity = Self.specificity(entry)
            if specificity > winnerSpecificity {
                winner = entry.target
                winnerSpecificity = specificity
            }
        }
        guard let target = winner else { return .unmapped }
        return .mapped(target)
    }

    private static func validate(_ entries: [ProgramRecallEntry]) throws(ProgramRecallRefusal) {
        for (index, entry) in entries.enumerated() {
            guard channels.contains(entry.channel) else { throw .invalidChannel(entry: index) }
            guard isValidBankPart(entry.bankMSB), isValidBankPart(entry.bankLSB) else {
                throw .invalidBank(entry: index)
            }
            guard entry.program <= maximumValue else { throw .invalidProgram(entry: index) }
        }
    }

    private static func requireNoEqualOverlap(_ entries: [ProgramRecallEntry]) throws(ProgramRecallRefusal) {
        for first in entries.indices {
            for second in (first + 1)..<entries.count where isAmbiguous(entries[first], entries[second]) {
                throw .overlappingEntries(first: first, second: second)
            }
        }
    }

    private static func isValidBankPart(_ part: UInt8?) -> Bool {
        guard let value = part else { return true }
        return value <= maximumValue
    }

    private static func isValidSelection(_ selection: MIDI1ProgramSelection) -> Bool {
        guard selection.bankMSB <= maximumValue else { return false }
        guard selection.bankLSB <= maximumValue else { return false }
        return selection.program <= maximumValue
    }

    private static func specificity(_ entry: ProgramRecallEntry) -> Int {
        let msb = entry.bankMSB == nil ? 0 : 1
        let lsb = entry.bankLSB == nil ? 0 : 1
        return msb + lsb
    }

    private static func partMatches(_ scope: UInt8?, _ value: UInt8) -> Bool {
        guard let wanted = scope else { return true }
        return wanted == value
    }

    private static func matches(
        _ entry: ProgramRecallEntry,
        input: MIDIInputID,
        channel: UInt8,
        selection: MIDI1ProgramSelection
    ) -> Bool {
        guard entry.input == input else { return false }
        guard entry.channel == channel else { return false }
        guard entry.program == selection.program else { return false }
        guard partMatches(entry.bankMSB, selection.bankMSB) else { return false }
        return partMatches(entry.bankLSB, selection.bankLSB)
    }

    private static func scopesOverlap(_ left: UInt8?, _ right: UInt8?) -> Bool {
        guard let leftValue = left, let rightValue = right else { return true }
        return leftValue == rightValue
    }

    private static func overlaps(_ left: ProgramRecallEntry, _ right: ProgramRecallEntry) -> Bool {
        guard left.input == right.input else { return false }
        guard left.channel == right.channel else { return false }
        guard left.program == right.program else { return false }
        guard scopesOverlap(left.bankMSB, right.bankMSB) else { return false }
        return scopesOverlap(left.bankLSB, right.bankLSB)
    }

    private static func isAmbiguous(_ left: ProgramRecallEntry, _ right: ProgramRecallEntry) -> Bool {
        guard specificity(left) == specificity(right) else { return false }
        return overlaps(left, right)
    }
}
