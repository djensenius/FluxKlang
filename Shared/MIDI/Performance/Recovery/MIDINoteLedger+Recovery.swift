/// Which routes a panic silences.
enum MIDIPanicScope: Equatable, Sendable {
    case all
    case route(MIDIRouteID)

    func contains(_ route: MIDIRouteID) -> Bool {
        switch self {
        case .all: true
        case let .route(scoped): scoped == route
        }
    }
}

/// What a lost route took with it. Nothing can release these: the destination is gone.
struct MIDIOrphanedRoute: Equatable, Sendable {
    let route: MIDIRouteID
    /// Arrival order.
    let notes: [MIDINoteInstance]
    /// Ascending.
    let pedalHolds: [MIDIPedalHold]
}

/// One panic output before ordering. Sorting by route, stage, channel then detail gives the panic order.
private struct MIDIPanicStep: Comparable {
    enum Stage: UInt8 {
        case noteOff
        case pedalOff
        case channelMode
    }

    /// All Notes Off then All Sound Off, per channel.
    static let channelModeControllers: [UInt8] = [123, 120]

    let route: MIDIRouteID
    let stage: Stage
    let channel: UInt8
    /// The note, the pedal controller, or the index into `channelModeControllers`.
    let detail: UInt8

    var output: MIDIRoutedOutput {
        let message: MIDI1Semantic = switch stage {
        case .noteOff:
            .noteOff(channel: channel, note: detail, velocity: MIDINoteLedger.releaseVelocity)
        case .pedalOff:
            .controlChange(channel: channel, controller: detail, value: 0)
        case .channelMode:
            .controlChange(channel: channel, controller: Self.channelModeControllers[Int(detail)], value: 0)
        }
        return MIDIRoutedOutput(route: route, message: message)
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.route.rawValue, lhs.stage.rawValue, lhs.channel, lhs.detail)
            < (rhs.route.rawValue, rhs.stage.rawValue, rhs.channel, rhs.detail)
    }
}

extension MIDINoteLedger {
    /// Per route: one note-off per note and channel, one pedal-off per pedal and channel, and All Notes Off plus
    /// All Sound Off per channel (16 × 128 + 16 × 2 + 16 × 2).
    static let maximumPanicOutputsPerRoute = MIDI1PerformanceState.channelCount * MIDI1HeldNotes.capacity
        + MIDI1PerformanceState.channelCount * 2 + MIDI1PerformanceState.channelCount * 2

    /// Every instance and hold yields at most one release plus two channel mode messages.
    var maximumPanicOutputs: Int {
        3 * (policy.noteCapacity + policy.pedalCapacity)
    }

    /// What `panic(scope, allNotesAndSoundOff:)` sends, without changing the ledger. Per route (ascending):
    /// note-offs for every key-down, sustained or sostenuto note (channel, then note), then CC 64/66 = 0 where held
    /// (channel, then pedal), then, unless disabled, CC 123 and CC 120 per channel that had a note or a hold. Sorting
    /// is O(n log n) in the ledger's entries and allocates; panic is control-side work.
    func panicPlan(_ scope: MIDIPanicScope = .all, allNotesAndSoundOff: Bool = true) -> [MIDIRoutedOutput] {
        var steps: [MIDIPanicStep] = []
        for instance in notes where scope.contains(instance.route) {
            steps.append(MIDIPanicStep(route: instance.route, stage: .noteOff, channel: instance.channel,
                                       detail: instance.note))
            if allNotesAndSoundOff {
                Self.appendChannelMode(route: instance.route, channel: instance.channel, to: &steps)
            }
        }
        for hold in pedalHolds where scope.contains(hold.route) {
            steps.append(MIDIPanicStep(route: hold.route, stage: .pedalOff, channel: hold.channel,
                                       detail: hold.pedal.rawValue))
            if allNotesAndSoundOff {
                Self.appendChannelMode(route: hold.route, channel: hold.channel, to: &steps)
            }
        }
        steps.sort()
        var outputs: [MIDIRoutedOutput] = []
        var previous: MIDIPanicStep?
        for step in steps where step != previous {
            outputs.append(step.output)
            previous = step
        }
        return outputs
    }

    private static func appendChannelMode(route: MIDIRouteID, channel: UInt8, to steps: inout [MIDIPanicStep]) {
        for index in MIDIPanicStep.channelModeControllers.indices {
            steps.append(MIDIPanicStep(route: route, stage: .channelMode, channel: channel, detail: UInt8(index)))
        }
    }
}
