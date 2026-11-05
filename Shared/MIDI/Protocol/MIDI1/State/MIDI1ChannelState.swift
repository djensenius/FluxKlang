/// Persistent state of one MIDI 1 channel. There are no timeouts: RPN/NRPN selection, the Bank Select latch and
/// 14-bit MSBs stay valid until replaced, however late the following message arrives.
/// A refused message leaves the value unchanged; every throwing path validates before it writes.
struct MIDI1ChannelState: Equatable, Sendable {
    static let controllerCount = 128
    static let centredPitchBend: UInt16 = 8192
    static let maximum14BitValue: UInt16 = 16_383
    /// Last 7-bit value of each CC 0...119. CC 120...127 are channel mode messages and are never stored.
    /// Power-up values follow General MIDI: volume 100, pan 64, expression 127; RPN/NRPN latches are null.
    static let initialControllers: [UInt8] = (0..<UInt8(controllerCount)).map { controller in
        switch controller {
        case 7: 100
        case 10: 64
        case 11, 98...101: 127
        default: 0
        }
    }

    private(set) var controllers = Self.initialControllers
    private(set) var polyPressure = [UInt8](repeating: 0, count: 128)
    private(set) var pitchBend = Self.centredPitchBend
    private(set) var channelPressure: UInt8 = 0
    /// Nil until a Program Change arrives.
    private(set) var program: MIDI1ProgramSelection?
    /// Which latch pair (RPN or NRPN) was written last. Nil at power-up and after Reset All Controllers.
    private(set) var activeParameterKind: MIDI1ParameterKind?
    private(set) var parameters: [MIDI1ParameterNumber: UInt16] = [:]
    private(set) var heldNotes = MIDI1HeldNotes()
    private(set) var mode = MIDI1ChannelMode()
    private(set) var localControl = true

    var sustainDown: Bool { controllers[64] >= 64 }

    /// Combined value of MSB `controller` 0...31 and its LSB `controller + 32`.
    func value14(controller: UInt8) -> UInt16? {
        guard controller < 32 else { return nil }
        return UInt16(controllers[Int(controller)]) << 7 | UInt16(controllers[Int(controller) + 32])
    }

    /// The selected RPN or NRPN, or nil when nothing is selected or the null function (127/127) is active.
    func selectedParameter(policy: MIDI1StatePolicy) -> MIDI1ParameterNumber? {
        guard let kind = activeParameterKind else { return nil }
        let number = kind == .registered
            ? MIDI1ParameterNumber(kind: kind, msb: controllers[101], lsb: controllers[100])
            : MIDI1ParameterNumber(kind: kind, msb: controllers[99], lsb: controllers[98])
        let isNull = number.msb == 0x7F && number.lsb == 0x7F
        guard !isNull || (kind == .nonRegistered && !policy.nrpnNullDeselects) else { return nil }
        return number
    }

    func parameterValue(_ number: MIDI1ParameterNumber) -> UInt16? {
        parameters[number]
    }

    /// Applies a channel voice message already validated by `MIDI1PerformanceState`; `channel` is 1...16.
    mutating func apply(
        _ semantic: MIDI1Semantic, channel: UInt8, policy: MIDI1StatePolicy
    ) throws(MIDI1StateRefusal) -> MIDI1StateEffect {
        switch semantic {
        case let .noteOn(_, note, 0):
            // Note On velocity 0 is Note Off, as `MIDI1Event.semantic` already normalizes raw 9n bytes.
            return noteOff(note: note)
        case let .noteOn(_, note, velocity):
            guard heldNotes.press(note: note, velocity: velocity, limit: policy.maximumHeldNotes) else {
                throw .heldNoteLimit(channel: channel, note: note)
            }
            return .noteOn(note: note, velocity: velocity)
        case let .noteOff(_, note, _):
            return noteOff(note: note)
        case let .polyphonicPressure(_, note, pressure):
            polyPressure[Int(note)] = pressure
            return .polyPressure(note: note, pressure: pressure)
        case let .controlChange(_, controller, value):
            return try applyController(controller, value: value, channel: channel, policy: policy)
        case let .programChange(_, number):
            let selection = MIDI1ProgramSelection(bankMSB: controllers[0], bankLSB: controllers[32], program: number)
            program = selection
            return .program(selection)
        case let .channelPressure(_, pressure):
            channelPressure = pressure
            return .channelPressure(pressure)
        case let .pitchBend(_, value):
            pitchBend = value
            return .pitchBend(value)
        default:
            return .unchanged
        }
    }

    private mutating func noteOff(note: UInt8) -> MIDI1StateEffect {
        switch heldNotes.release(note: note, sustainDown: sustainDown) {
        case .notHeld: .unchanged
        case .sustained: .noteOff(note: note, sustained: true)
        case .released: .noteOff(note: note, sustained: false)
        }
    }
}

extension MIDI1ChannelState {
    private static let dataEntryControllers: Set<UInt8> = [6, 38, 96, 97]
    private static let rp015ResetControllers: [(controller: Int, value: UInt8)] = [
        (1, 0), (33, 0), (11, 127), (43, 0), (64, 0), (65, 0), (66, 0), (67, 0),
        (98, 127), (99, 127), (100, 127), (101, 127)
    ]

    private mutating func applyController(
        _ controller: UInt8, value: UInt8, channel: UInt8, policy: MIDI1StatePolicy
    ) throws(MIDI1StateRefusal) -> MIDI1StateEffect {
        if controller >= 120 {
            return try applyChannelMode(controller, value: value, channel: channel)
        }
        if (98...101).contains(controller) {
            controllers[Int(controller)] = value
            activeParameterKind = controller >= 100 ? .registered : .nonRegistered
            return .parameterSelected(selectedParameter(policy: policy))
        }
        if Self.dataEntryControllers.contains(controller) {
            return try applyDataEntry(controller, value: value, channel: channel, policy: policy)
        }
        controllers[Int(controller)] = value
        switch controller {
        case 0, 32:
            // Bank Select is latched as a pair until Program Change, so its MSB never resets its LSB.
            return .bankLatched(msb: controllers[0], lsb: controllers[32])
        case 1...31:
            if policy.lsbReset == .resetOnMSB { controllers[Int(controller) + 32] = 0 }
            return .controller14(controller, value: value14(controller: controller) ?? 0)
        case 33...63:
            return .controller14(controller - 32, value: value14(controller: controller - 32) ?? 0)
        case 64:
            guard sustainDown else { return .sustain(down: false, released: heldNotes.releaseSustained()) }
            return .sustain(down: true, released: [])
        default:
            return .controller(controller, value: value)
        }
    }

    /// CC 6/38 write the selected parameter's MSB/LSB; CC 96/97 step it, ignoring their value byte (RP-018).
    private mutating func applyDataEntry(
        _ controller: UInt8, value: UInt8, channel: UInt8, policy: MIDI1StatePolicy
    ) throws(MIDI1StateRefusal) -> MIDI1StateEffect {
        guard let number = selectedParameter(policy: policy) else {
            throw .noParameterSelected(channel: channel, controller: controller)
        }
        let stored = parameters[number]
        guard stored != nil || parameters.count < policy.maximumParameterValues else {
            throw .parameterStoreFull(channel: channel)
        }
        let old = stored ?? 0
        let updated = Self.dataEntryValue(controller, value: value, old: old, number: number, policy: policy)
        parameters[number] = updated
        controllers[Int(controller)] = value
        if controller == 6, policy.lsbReset == .resetOnMSB { controllers[38] = 0 }
        return .parameter(number, value: updated)
    }

    private static func dataEntryValue(
        _ controller: UInt8, value: UInt8, old: UInt16, number: MIDI1ParameterNumber, policy: MIDI1StatePolicy
    ) -> UInt16 {
        let msb = old >> 7
        let lsb = old & 0x7F
        switch controller {
        case 6:
            return UInt16(value) << 7 | (policy.lsbReset == .resetOnMSB ? 0 : lsb)
        case 38:
            return msb << 7 | UInt16(value)
        case 96:
            // Coarse Tuning (RPN 0/2) steps in semitones, its MSB; every other parameter steps by 1.
            if number == .coarseTuning { return min(msb + 1, 0x7F) << 7 | lsb }
            return min(old + 1, maximum14BitValue)
        default:
            if number == .coarseTuning { return (msb == 0 ? 0 : msb - 1) << 7 | lsb }
            return old == 0 ? 0 : old - 1
        }
    }

    private mutating func applyChannelMode(
        _ controller: UInt8, value: UInt8, channel: UInt8
    ) throws(MIDI1StateRefusal) -> MIDI1StateEffect {
        guard Self.validModeValue(controller, value: value) else {
            throw .invalidModeValue(channel: channel, controller: controller, value: value)
        }
        switch controller {
        case 120:
            return .allSoundOff(released: heldNotes.clear())
        case 121:
            return .controllersReset(released: resetAllControllers())
        case 122:
            localControl = value == 127
            return .localControl(localControl)
        case 123:
            return .allNotesOff(released: heldNotes.releaseKeys(sustainDown: sustainDown))
        default:
            // Omni Off/On, Mono On and Poly On also act as All Notes Off.
            let released = heldNotes.releaseKeys(sustainDown: sustainDown)
            if controller == 124 || controller == 125 {
                mode.omni = controller == 125
            } else {
                mode.voices = controller == 126 ? .mono(channels: value) : .poly
            }
            return .mode(mode, released: released)
        }
    }

    /// 120, 121 and 123 accept any value; 122 is 0 or 127; 124, 125 and 127 are 0; 126 is 0...16.
    private static func validModeValue(_ controller: UInt8, value: UInt8) -> Bool {
        switch controller {
        case 122: value == 0 || value == 127
        case 124, 125, 127: value == 0
        case 126: value <= 16
        default: true
        }
    }

    /// RP-015. Keeps program, bank, volume, pan, effects 91...95, sound controllers 70...79, parameter values,
    /// local control and mode. Lifting the sustain pedal releases sustained notes.
    private mutating func resetAllControllers() -> [UInt8] {
        for (controller, value) in Self.rp015ResetControllers { controllers[controller] = value }
        activeParameterKind = nil
        pitchBend = Self.centredPitchBend
        channelPressure = 0
        polyPressure = [UInt8](repeating: 0, count: 128)
        return heldNotes.releaseSustained()
    }
}

extension MIDI1ChannelState {
    var snapshot: MIDI1ChannelSnapshot {
        MIDI1ChannelSnapshot(
            controllers: controllers, polyPressure: polyPressure, pitchBend: pitchBend,
            channelPressure: channelPressure, program: program, activeParameterKind: activeParameterKind,
            parameters: parameters.keys.sorted().map { MIDI1ParameterValue(number: $0, value: parameters[$0] ?? 0) },
            heldNotes: heldNotes.notes, mode: mode, localControl: localControl
        )
    }

    /// Refuses any snapshot this type could not have reached under `policy`.
    init(snapshot: MIDI1ChannelSnapshot, policy: MIDI1StatePolicy) throws(MIDI1StateRefusal) {
        func require(_ condition: Bool, _ field: MIDI1SnapshotField) throws(MIDI1StateRefusal) {
            if !condition { throw .invalidSnapshot(field) }
        }
        let controllers = snapshot.controllers
        try require(controllers.count == Self.controllerCount && controllers.allSatisfy { $0 < 0x80 }, .controllers)
        try require(controllers[120...].allSatisfy { $0 == 0 }, .controllers)
        try require(snapshot.polyPressure.count == 128 && snapshot.polyPressure.allSatisfy { $0 < 0x80 }, .polyPressure)
        try require(snapshot.pitchBend <= Self.maximum14BitValue, .pitchBend)
        try require(snapshot.channelPressure < 0x80, .channelPressure)
        let program = snapshot.program.map { [$0.bankMSB, $0.bankLSB, $0.program] } ?? []
        try require(program.allSatisfy { $0 < 0x80 }, .program)
        try require(Self.validParameters(snapshot.parameters, policy: policy), .parameters)
        if case let .mono(channels) = snapshot.mode.voices { try require(channels <= 16, .mode) }
        let sustainDown = controllers[64] >= 64
        guard let held = MIDI1HeldNotes(notes: snapshot.heldNotes, limit: policy.maximumHeldNotes,
                                        sustainDown: sustainDown) else { throw .invalidSnapshot(.heldNotes) }
        self.controllers = controllers
        polyPressure = snapshot.polyPressure
        pitchBend = snapshot.pitchBend
        channelPressure = snapshot.channelPressure
        self.program = snapshot.program
        activeParameterKind = snapshot.activeParameterKind
        parameters = Dictionary(uniqueKeysWithValues: snapshot.parameters.map { ($0.number, $0.value) })
        heldNotes = held
        mode = snapshot.mode
        localControl = snapshot.localControl
    }

    /// Strictly ascending numbers, so canonical and unique.
    private static func validParameters(_ values: [MIDI1ParameterValue], policy: MIDI1StatePolicy) -> Bool {
        guard values.count <= policy.maximumParameterValues else { return false }
        for (index, entry) in values.enumerated() {
            guard entry.number.isValid, entry.value <= maximum14BitValue else { return false }
            guard index == 0 || values[index - 1].number < entry.number else { return false }
        }
        return true
    }
}
