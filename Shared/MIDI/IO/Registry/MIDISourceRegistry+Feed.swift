extension MIDISourceRegistry {
    /// The binding of one `MIDIInputID`: the only owner of that source's parser and state, so no byte of another
    /// source can frame it or change its state.
    struct Source: Sendable {
        private static let systemReset = MIDI1Event.realTime(status: 0xFF)

        let input: MIDIInputID
        let key: MIDIEndpointKey
        let profile: MIDISourceProfile
        private var parser: MIDI1Parser
        private var state: MIDI1PerformanceState

        /// Nil only if the profile's SysEx bound cannot build a parser, which a validated profile never has.
        init?(input: MIDIInputID, key: MIDIEndpointKey, profile: MIDISourceProfile) {
            guard let parser = MIDI1Parser(maximumSysExPayloadBytes: profile.maximumSysExPayloadBytes) else {
                return nil
            }
            self.input = input
            self.key = key
            self.profile = profile
            self.parser = parser
            state = MIDI1PerformanceState(policy: profile.statePolicy)
        }

        var descriptor: MIDISourceDescriptor {
            MIDISourceDescriptor(input: input, key: key, profile: profile)
        }

        var snapshot: MIDISourceSnapshot {
            MIDISourceSnapshot(input: input, key: key, profile: profile, state: state.snapshot)
        }

        /// Every held note, key-down and sustained, ascending by channel 1...16 and then note.
        var releases: [MIDISourceRelease] {
            state.channels.enumerated().flatMap { index, channel in
                channel.heldNotes.notes.map {
                    MIDISourceRelease(channel: UInt8(index + 1), note: $0.note, phase: $0.phase)
                }
            }
        }

        /// Reports what was held, then replaces the state with a fresh one of the profile's policy and resets the
        /// parser (half messages, running status and an open SysEx are dropped).
        mutating func reset() -> [MIDISourceRelease] {
            let released = releases
            state = MIDI1PerformanceState(policy: profile.statePolicy)
            parser.reset()
            return released
        }

        /// One output per emitted event, in byte order; the parser emits at most one event per byte.
        mutating func consume(_ bytes: [UInt8]) -> [MIDISourceOutput] {
            var outputs: [MIDISourceOutput] = []
            for byte in bytes {
                guard let event = parser.consume(byte) else { continue }
                outputs.append(output(for: event))
            }
            return outputs
        }

        private mutating func output(for event: MIDI1Event) -> MIDISourceOutput {
            if event == Self.systemReset, profile.systemReset == .resetSource {
                return MIDISourceOutput(input: input, event: event, outcome: .systemReset(released: reset()))
            }
            do throws(MIDI1StateRefusal) {
                let update = try state.apply(event)
                return MIDISourceOutput(input: input, event: event, outcome: .applied(update))
            } catch {
                return MIDISourceOutput(input: input, event: event, outcome: .refused(error))
            }
        }
    }
}
