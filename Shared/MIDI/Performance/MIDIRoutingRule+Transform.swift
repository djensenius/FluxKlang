/// How a rule's optional `MIDIValueTransform` reshapes what the ledger sends. Only a note-on of velocity 1...127 and
/// a control change whose controller is not in `MIDIProtectedControllers` can change, and only when the transform has
/// a matching curve (the velocity curve, or a curve for that controller). Every other message is sent as it came,
/// including note-offs, a note-on of velocity 0, both pressure kinds, program changes and pitch bends.
extension MIDIRoutingRule {
    /// The message with the rule's curve applied, or `message` itself when the rule has no transform, no curve
    /// applies, the controller is protected, `message` fails `hasRoutableData`, or the curve result is not a note-on of
    /// the same channel and note with velocity 1...127.
    func shaped(_ message: MIDI1Semantic) -> MIDI1Semantic {
        guard let transform, message.hasRoutableData else { return message }
        switch message {
        case let .noteOn(channel, note, velocity) where velocity > 0:
            let curved = transform.apply(message)
            guard case let .noteOn(curvedChannel, curvedNote, curvedVelocity) = curved,
                  curvedChannel == channel, curvedNote == note, (1...0x7F).contains(curvedVelocity) else {
                return message
            }
            return curved
        case let .controlChange(_, controller, _):
            return MIDIProtectedControllers.contains(controller) ? message : transform.apply(message)
        case .noteOn, .noteOff, .polyphonicPressure, .channelPressure, .programChange, .pitchBend,
             .systemCommon, .realTime, .sysEx:
            return message
        }
    }

    /// `shaped(message)` addressed to this rule's route.
    func routed(_ message: MIDI1Semantic) -> MIDIRoutedOutput {
        MIDIRoutedOutput(route: route, message: shaped(message))
    }
}

extension MIDIRoutedOutput {
    /// Whether this output and `other` go to the same route and are the same message once the data byte of a note-on
    /// (velocity) or a control change (value) is set aside. The ledger keeps the first of several such outputs, so
    /// two rules reaching one route send one note-on for one note whatever their curves, and the first rule in table
    /// order decides the data byte.
    func sharesTarget(_ other: MIDIRoutedOutput) -> Bool {
        route == other.route && message.withoutDataByte == other.message.withoutDataByte
    }
}

private extension MIDI1Semantic {
    /// A note-on or control change with its data byte replaced by 0; every other message as it is.
    var withoutDataByte: MIDI1Semantic {
        switch self {
        case let .noteOn(channel, note, _):
            .noteOn(channel: channel, note: note, velocity: 0)
        case let .controlChange(channel, controller, _):
            .controlChange(channel: channel, controller: controller, value: 0)
        case .noteOff, .polyphonicPressure, .channelPressure, .programChange, .pitchBend,
             .systemCommon, .realTime, .sysEx:
            self
        }
    }
}
