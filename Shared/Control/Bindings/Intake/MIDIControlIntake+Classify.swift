extension MIDIControlIntake {
    /// A control effect reduced to what a key and a decode need. `number` is `Int` so a refusal can name any value.
    struct Classified: Equatable, Sendable {
        let kind: ControlSourceKind
        let number: Int
        let raw: Int
    }

    /// Maps an effect to its kind, number and raw value, applying the number check, the raw-range check and the
    /// dialect's low-part check in that order. Every effect is listed: a new `MIDI1StateEffect` case fails the build.
    static func classify(
        _ effect: MIDI1StateEffect, dialect: ControlIntakeDialect
    ) throws(ControlIntakeRefusal) -> Classified {
        switch effect {
        case let .controller(number, value):
            return try plainController(number, value: value)
        case let .controller14(number, value):
            return try pairedController(number, value: value, dialect: dialect)
        case let .parameter(parameter, value):
            return try parameterMessage(parameter, value: value)
        case let .pitchBend(value):
            return try singleMessage(.pitchBend, raw: Int(value))
        case let .channelPressure(value):
            return try singleMessage(.channelPressure, raw: Int(value))
        case .unchanged,
             .noteOn,
             .noteOff,
             .polyPressure,
             .bankLatched,
             .parameterSelected,
             .program,
             .sustain,
             .allSoundOff,
             .allNotesOff,
             .controllersReset,
             .localControl,
             .mode:
            throw .notControlInput
        }
    }

    private static func plainController(_ number: UInt8, value: UInt8) throws(ControlIntakeRefusal) -> Classified {
        guard ControlIntakeBounds.reachableControllerRanges.contains(where: { $0.contains(number) }) else {
            throw .invalidNumber(Int(number))
        }
        try requireRaw(Int(value), width: .seven)
        return Classified(kind: .controller, number: Int(number), raw: Int(value))
    }

    private static func pairedController(
        _ number: UInt8, value: UInt16, dialect: ControlIntakeDialect
    ) throws(ControlIntakeRefusal) -> Classified {
        guard ControlIntakeBounds.pairedControllerRange.contains(number) else { throw .invalidNumber(Int(number)) }
        try requireRaw(Int(value), width: .fourteen)
        switch dialect {
        case .pairedFourteenBit:
            return Classified(kind: .controller14, number: Int(number), raw: Int(value))
        case .msbOnlySevenBit:
            let low = Int(value) & ControlIntakeBounds.sevenBitMaximum
            guard low == 0 else { throw .lsbPresent(raw: low) }
            return Classified(kind: .controller, number: Int(number), raw: Int(value) >> EncoderBitWidth.seven.rawValue)
        }
    }

    private static func parameterMessage(
        _ parameter: MIDI1ParameterNumber, value: UInt16
    ) throws(ControlIntakeRefusal) -> Classified {
        let number = parameterNumber(parameter)
        let maximum = ControlIntakeBounds.parameterByteMaximum
        guard Int(parameter.msb) <= maximum, Int(parameter.lsb) <= maximum else { throw .invalidNumber(number) }
        try requireRaw(Int(value), width: .fourteen)
        switch parameter.kind {
        case .registered:
            return Classified(kind: .registeredParameter, number: number, raw: Int(value))
        case .nonRegistered:
            return Classified(kind: .nonRegisteredParameter, number: number, raw: Int(value))
        }
    }

    private static func singleMessage(_ kind: ControlSourceKind, raw: Int) throws(ControlIntakeRefusal) -> Classified {
        try requireRaw(raw, width: kind.width)
        return Classified(kind: kind, number: 0, raw: raw)
    }

    private static func requireRaw(_ raw: Int, width: EncoderBitWidth) throws(ControlIntakeRefusal) {
        let maximum = ControlIntakeBounds.maximum(for: width)
        guard raw <= maximum else { throw .rawOutOfRange(raw: raw, maximum: maximum) }
    }

    /// `msb * 128 + lsb` with reporting-overflow arithmetic, saturating at `Int.max` (unreachable for `UInt8` inputs).
    private static func parameterNumber(_ parameter: MIDI1ParameterNumber) -> Int {
        let valueCount = EncoderBitWidth.seven.valueCount
        let (scaled, scaleOverflow) = Int(parameter.msb).multipliedReportingOverflow(by: valueCount)
        let (sum, sumOverflow) = scaled.addingReportingOverflow(Int(parameter.lsb))
        return scaleOverflow || sumOverflow ? Int.max : sum
    }
}
