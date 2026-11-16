//
//  LaunchControlXLMapping+State.swift
//  FluxKlang
//

/// The Launch Control XL read through the MIDI 1 state layer (#80). Its CCs 6, 38 and 98...101 are plain knobs and
/// buttons, so it uses the `.unpaired` profile: every CC 0...119 except Sustain (64) is applied as a plain
/// `.controller` and maps exactly as `action(for: MIDIControlChange)` does.
extension LaunchControlXLMapping {
    /// `LaunchControlXLStream` registers the surface with this profile, so its state policy, SysEx payload bound
    /// and System Reset policy (`.ignore`) all apply to the incoming bytes.
    static let sourceProfile: MIDISourceProfile = .unpaired

    /// Only a channel `.controller` update maps; everything else (notes, bend, program, system, channel mode
    /// 120...127, and Sustain, which the state reports as `.sustain`) is nil.
    func action(for update: MIDI1StateUpdate) -> LaunchControlXLAction? {
        guard let channel = update.channel, case let .controller(controller, value) = update.effect else {
            return nil
        }
        return action(for: MIDIControlChange(channel: Int(channel), controller: controller, value: value))
    }

    /// Actions of the applied outputs, in output order; refused outputs and System Resets map to nothing. CC 64 is
    /// a `.sustain` update whose effect drops the 7-bit value, so it is mapped from the applied event's own bytes
    /// and behaves as before the state layer.
    func actions(for outputs: [MIDISourceOutput]) -> [LaunchControlXLAction] {
        outputs.compactMap { output in
            guard case let .applied(update) = output.outcome else { return nil }
            if case .sustain = update.effect, let sustain = Self.sustainControl(output.event) {
                return action(for: sustain)
            }
            return action(for: update)
        }
    }

    private static func sustainControl(_ event: MIDI1Event) -> MIDIControlChange? {
        guard case let .channel(status, 64, value?) = event, status & 0xF0 == 0xB0 else { return nil }
        return MIDIControlChange(channel: Int(status & 0x0F) + 1, controller: 64, value: value)
    }
}
