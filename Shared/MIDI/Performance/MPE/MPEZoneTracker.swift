/// Follows the MPE zone layout across a MIDI 1 stream (#82, slice MPC1). Nothing calls it yet. It reads the
/// `MIDI1StateUpdate` values `MIDI1PerformanceState` yields and applies the one that is a registered parameter 0/6
/// (RPN 6) data entry with `MPEZoneConfiguration.fromRPN6`. Only the MSB of the 14-bit value counts, so Data Entry LSB
/// is ignored; Data Increment and Decrement move the 14-bit value and so are read as the MSB of the stepped value.
struct MPEZoneTracker: Equatable, Sendable {
    private(set) var configuration: MPEZoneConfiguration

    /// nil when `update` is not an RPN 6 data entry; otherwise the change that was applied (even when nothing
    /// changed). A refusal leaves the tracker unchanged.
    mutating func apply(_ update: MIDI1StateUpdate) throws(MPERefusal) -> MPEZoneChange? {
        guard case let .parameter(number, value) = update.effect,
              number == MIDI1ParameterNumber(kind: .registered, msb: 0, lsb: 6) else { return nil }
        guard let channel = update.channel else { throw .invalidChannel(0) }
        guard value <= 0x3FFF else { throw .valueOutOfRange(value) }
        let change = try MPEZoneConfiguration.fromRPN6(
            channel: channel, dataEntryMSB: UInt8(value >> 7), current: configuration
        )
        configuration = change.configuration
        return change
    }
}
