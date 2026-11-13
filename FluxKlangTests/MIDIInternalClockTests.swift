import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// The internal MIDI clock master (#84). The tests live in this root suite and its `MIDIInternalClockTests+...`
/// extensions; the fixtures are shared here.
///
/// Fixture A (the default map): 48 kHz, 500,000 microseconds per quarter (120 BPM), anchored at frame 0 and tick 0.
/// One 24-PPQN pulse falls every 1,000 frames and one Song Position unit every 6,000 frames. Fixture C is 192 kHz at
/// 60,000 microseconds per quarter: one pulse every 480 frames, the fastest pulse rate the schedule allows.
@Suite(.productionAccessAudit)
struct MIDIInternalClockTests {
    /// The sample clock every fixture map is anchored on.
    static let sampleClock = ClockID(validated: "clock.sample")

    /// A musical map on the first sample generation whose musical anchor belongs to `transport`'s generation.
    static func map(for transport: MIDIInternalTransport, rate: Int = 48_000,
                    tempos: [(Int64, Int64)] = [(0, 500_000)], anchorFrame: Int64 = 0,
                    anchorTicks: Int64 = 0) throws -> MusicalClockMap {
        let anchor = ClockAnchor(sample: .init(clock: sampleClock, generation: .initial, frame: anchorFrame),
                                 host: .init(ticks: 0),
                                 musical: .init(transport: transport.generation, musicalMap: .initial,
                                                ticks: anchorTicks, loopIteration: 0))
        let segments = try tempos.map { try TempoSegment(atTicks: $0.0, microsPerQuarter: $0.1) }
        let musical = try MusicalMap(clock: ClockID(validated: "clock.musical"), revision: .initial,
                                     segments: segments)
        return try MusicalClockMap(anchor: anchor, map: musical, nominalRate: rate, currentSample: .initial,
                                   currentTransport: transport.generation)
    }

    /// `base` re-anchored on the sample clock generation `generation`.
    static func map(_ base: MusicalClockMap, onSampleGeneration generation: Generation) throws -> MusicalClockMap {
        let anchor = ClockAnchor(sample: .init(clock: base.anchor.sample.clock, generation: generation,
                                               frame: base.anchor.sample.frame),
                                 host: base.anchor.host, musical: base.anchor.musical)
        return try MusicalClockMap(anchor: anchor, map: base.map, nominalRate: base.nominalRate,
                                   currentSample: generation, currentTransport: base.musical.transport)
    }

    static func window(_ start: Int64, _ count: Int64,
                       sampleGeneration: Generation = .initial) throws -> MIDIInternalClockWindow {
        try MIDIInternalClockWindow.make(sampleGeneration: sampleGeneration, startFrame: start, frameCount: count)
    }

    /// The plan of the internal leader for `transport`.
    static func plan(_ transport: MIDIInternalTransport, _ map: MusicalClockMap,
                     _ window: MIDIInternalClockWindow) throws -> MIDIInternalClockPlan {
        try MIDIInternalClockPlan.make(transport: transport, leader: .internal, map: map, window: window)
    }

    static func run(from ticks: Int64, at frame: Int64, _ origin: MIDIInternalTransport.Origin)
        -> MIDIInternalTransport.Run {
        MIDIInternalTransport.Run(fromTicks: ticks, atFrame: frame, origin: origin)
    }

    /// Generation 2: started at `frame` from position 0.
    static func started(atFrame frame: Int64 = 0) throws -> MIDIInternalTransport {
        try MIDIInternalTransport.initial.starting(atFrame: frame)
    }

    /// Generation 2: continued at `frame` from the stopped position `ticks`.
    static func continued(fromTicks ticks: Int64, atFrame frame: Int64) throws -> MIDIInternalTransport {
        try MIDIInternalTransport.stopped(atTicks: ticks, generation: .initial).continuing(atFrame: frame)
    }

    /// Generation 3: started at `startFrame` on fixture A, with a Stop pending at `stopFrame`.
    static func stopPending(atFrame stopFrame: Int64, startedAt startFrame: Int64 = 0) throws
        -> MIDIInternalTransport {
        let running = try started(atFrame: startFrame)
        return try running.stopping(atFrame: stopFrame, in: map(for: running, anchorFrame: startFrame))
    }

    /// Generation 4: the run and Stop of `stopPending(atFrame:)` on fixture A, one transition later (a locate came
    /// first), so a plan made for it names another transport generation.
    static func laterStopPending(atFrame stopFrame: Int64) throws -> MIDIInternalTransport {
        let running = try MIDIInternalTransport.initial.locating(toTicks: 0).starting(atFrame: 0)
        return try running.stopping(atFrame: stopFrame, in: map(for: running))
    }

    static func event(_ frame: Int64, _ message: MIDIClockMessage) -> MIDIInternalClockEvent {
        MIDIInternalClockEvent(frame: frame, message: message)
    }

    static func clock(_ frame: Int64, _ pulse: Int64) -> MIDIInternalClockEvent {
        MIDIInternalClockEvent(frame: frame, message: .clock, pulseIndex: pulse)
    }

    @Test
    func planLimitsArePolicyValuesBelowTheScheduleCapacity() {
        #expect(MIDIInternalClockPlan.maximumLookaheadFrames == 384_000)
        #expect(MIDIInternalClockPlan.maximumPlanEvents == 512)
        #expect(MIDIInternalClockPlan.maximumPlanEvents <= MIDIClockPulseSchedule.maximumCapacity)
    }
}
