//
//  MIDIInternalClockEvent.swift
//  FluxKlang
//
//  One real-time message the internal clock master plans for a frame, and the total order of a plan (#84).
//

/// One planned MIDI real-time message.
///
/// Events of a plan are in ascending `precedes` order: frame first, then the message rank (`.stop`, then
/// `.songPosition`, then `.start`/`.continue`, then `.clock`), then the pulse index.
struct MIDIInternalClockEvent: Equatable, Sendable {
    let frame: Int64
    let message: MIDIClockMessage
    /// The song pulse of a `.clock` message (`ticks / MIDIClockMath.ticksPerPulse`); nil for every other message.
    let pulseIndex: Int64?
    /// The earliest host tick whose frame is at least `frame`; nil until the plan is stamped.
    let hostStamp: HostStamp?

    init(frame: Int64, message: MIDIClockMessage, pulseIndex: Int64? = nil, hostStamp: HostStamp? = nil) {
        self.frame = frame
        self.message = message
        self.pulseIndex = pulseIndex
        self.hostStamp = hostStamp
    }

    /// The same event with its lookahead host tick.
    func stamped(_ host: HostStamp) -> MIDIInternalClockEvent {
        MIDIInternalClockEvent(frame: frame, message: message, pulseIndex: pulseIndex, hostStamp: host)
    }

    /// The documented total order: ascending frame, then message rank, then ascending pulse index (nil counts as 0).
    static func precedes(_ lhs: MIDIInternalClockEvent, _ rhs: MIDIInternalClockEvent) -> Bool {
        if lhs.frame != rhs.frame { return lhs.frame < rhs.frame }
        if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
        return (lhs.pulseIndex ?? 0) < (rhs.pulseIndex ?? 0)
    }

    /// A Stop ends the run before anything else at its frame; a Start or Continue precedes the first Clock.
    private var rank: Int {
        switch message {
        case .stop: return 0
        case .songPosition: return 1
        case .start, .continue: return 2
        case .clock: return 3
        }
    }
}
