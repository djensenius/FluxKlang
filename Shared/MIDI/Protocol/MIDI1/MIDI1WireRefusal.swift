/// Why a MIDI 1 message cannot be put on the wire as it is (#81, slice MWB1). Nothing is clamped or masked.
/// Nothing calls it yet.
enum MIDI1WireRefusal: Error, Equatable, Hashable, Sendable {
    /// A semantic channel is not 1...16.
    case channelOutOfRange(UInt8)
    /// A data byte of a channel or System Common message is 0x80 or more.
    case dataByteHigh(UInt8)
    /// A semantic pitch bend value is above 16383.
    case pitchBendOutOfRange(UInt16)
    /// A semantic Note On with velocity 0, which the wire reads as a Note Off; send `.noteOff` instead.
    case noteOnVelocityZero(channel: UInt8, note: UInt8)
    /// The System Common status is not F1, F2, F3 or F6.
    case unsupportedSystemCommon(UInt8)
    /// The System Common message has the wrong number of data bytes for its status.
    case systemCommonDataShape(status: UInt8)
    /// The real-time status is not F8, FA, FB, FC, FE or FF.
    case unsupportedRealTime(UInt8)
    /// The first SysEx payload byte that is 0x80 or more.
    case sysExByteHigh(index: Int, byte: UInt8)
    /// An event channel status is outside 0x80...0xEF.
    case channelStatus(UInt8)
    /// The data bytes of an event channel message do not fit its status.
    case channelDataShape(status: UInt8)
}
