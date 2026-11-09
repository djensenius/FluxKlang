/// The MIDI 1 bytes that tell one controller one position, with the key and step they were built from. Bytes are
/// complete messages (no running status): 2 for channel pressure, 3 for a CC or pitch bend, 6 for a 14-bit CC pair
/// (MSB message, then LSB message). Every data byte is below 0x80. Built only by `make`, never forged: the storage
/// is private and the initializer is `fileprivate`. Nothing here sends anything.
struct ControlFeedbackMIDI1Packet: Equatable, Sendable {
    private let storedBytes: [UInt8]
    let key: ControlSourceKey
    let step: Int

    var bytes: [UInt8] { storedBytes }

    fileprivate init(bytes: [UInt8], key: ControlSourceKey, step: Int) {
        storedBytes = bytes
        self.key = key
        self.step = step
    }
}

extension ControlFeedbackMIDI1Packet {
    private static let controllerStatus: UInt8 = 0xB0
    private static let pressureStatus: UInt8 = 0xD0
    private static let bendStatus: UInt8 = 0xE0
    private static let dataMask: UInt8 = 0x7F
    private static let lsbOffset: UInt8 = 32

    /// The bytes for `step` on `key`. A packet exists only for a key the intake can read back and a step inside
    /// 0...maximum of the kind's width. Refusal order: `requireReadable` first, then `stepOutOfRange`, then
    /// `unsupportedKind` for the kinds with no feedback encoding.
    /// A 14-bit pair sends the MSB first, the only order that survives the standard receiver policy: the receiver
    /// then reports two updates, the first with only the high 7 bits.
    static func make(
        key: ControlSourceKey, step: Int, dialect: ControlIntakeDialect
    ) throws(ControlFeedbackMIDI1Refusal) -> Self {
        try requireReadable(key, dialect: dialect)
        let maximum = ControlIntakeBounds.maximum(for: key.kind.width)
        guard (0...maximum).contains(step) else { throw .stepOutOfRange(step: step, maximum: maximum) }
        let nibble = key.channel - 1
        let low = UInt8(truncatingIfNeeded: step) & dataMask
        let high = UInt8(truncatingIfNeeded: step >> 7) & dataMask
        let number = UInt8(truncatingIfNeeded: key.number)
        let bytes: [UInt8]
        switch key.kind {
        case .controller:
            bytes = [controllerStatus | nibble, number, low]
        case .controller14:
            bytes = [
                controllerStatus | nibble, number, high,
                controllerStatus | nibble, number + lsbOffset, low
            ]
        case .pitchBend:
            bytes = [bendStatus | nibble, low, high]
        case .channelPressure:
            bytes = [pressureStatus | nibble, low]
        case .registeredParameter, .nonRegisteredParameter:
            throw .unsupportedKind(key.kind)
        }
        return Self(bytes: bytes, key: key, step: step)
    }
}

extension ControlFeedbackMIDI1Packet {
    private static let dataEntryNumber: UInt16 = 6

    /// The one readability rule: the key is one the receiver reports back as the same key. Plain CCs must be in the
    /// intake's reachable ranges (under the seven-bit-only dialect also 1...31, the MSB of a pair, except CC 6, data
    /// entry); a 14-bit pair needs the paired dialect and never CC 6.
    static func requireReadable(
        _ key: ControlSourceKey, dialect: ControlIntakeDialect
    ) throws(ControlFeedbackMIDI1Refusal) {
        switch key.kind {
        case .controller:
            guard isReadablePlain(key.number, dialect: dialect) else {
                throw .controllerNotReadable(number: Int(key.number))
            }
        case .controller14:
            switch dialect {
            case .pairedFourteenBit: break
            case .msbOnlySevenBit: throw .unsupportedKind(key.kind)
            }
            guard key.number != dataEntryNumber else { throw .controllerNotReadable(number: Int(key.number)) }
        case .pitchBend, .channelPressure, .registeredParameter, .nonRegisteredParameter:
            return
        }
    }

    private static func isReadablePlain(_ number: UInt16, dialect: ControlIntakeDialect) -> Bool {
        guard let byte = UInt8(exactly: number) else { return false }
        if ControlIntakeBounds.reachableControllerRanges.contains(where: { $0.contains(byte) }) { return true }
        switch dialect {
        case .pairedFourteenBit:
            return false
        case .msbOnlySevenBit:
            return ControlIntakeBounds.pairedControllerRange.contains(byte) && number != dataEntryNumber
        }
    }
}
