/// Why a program recall call was refused. A refusal returns no table and no outcome.
enum ProgramRecallRefusal: Error, Equatable, Sendable {
    /// More than `ProgramRecallTable.maximumEntries` entries were supplied (the count is reported).
    case tooManyEntries(Int)
    /// The entry at this index has a channel outside 1...16.
    case invalidChannel(entry: Int)
    /// The entry at this index has a Bank Select MSB or LSB above 127.
    case invalidBank(entry: Int)
    /// The entry at this index has a program above 127.
    case invalidProgram(entry: Int)
    /// Two entries of equal specificity can match one Program Change, so no winner could be chosen. The indices are
    /// the first pair in scan order: `first` ascending, then `second` ascending, with `first < second`.
    case overlappingEntries(first: Int, second: Int)
    /// The received channel is outside 1...16.
    case invalidReceivedChannel(UInt8)
    /// The received bank MSB, bank LSB or program is above 127.
    case invalidReceivedSelection(MIDI1ProgramSelection)
    /// A displayed number is outside the range of its base, or an internal value is above 127.
    case numberOutOfRange(Int)
}
