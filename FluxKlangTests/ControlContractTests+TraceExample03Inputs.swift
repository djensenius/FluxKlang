//
//  ControlContractTests+TraceExample03Inputs.swift
//  FluxKlangTests
//
//  The typed builder inputs of media contract example 03 (#84 EXG6), split from
//  `ControlContractTests+TraceExample03.swift` to keep both files short. Every value is written here as a typed
//  literal or comes from `MIDICaptureFixture`; nothing is decoded from the example.
//
//  The SMF `export` record (seq 23) is built from a SYNTHETIC `SMFWriteResult`: a 14-byte header (format 1, two
//  tracks, division 960) and typed losses. The real exporter writes format 0 at division 15360, so this proves the
//  record builder, not the exporter.
//

import Foundation
@testable import FluxKlang

enum TraceExample03Inputs {
    enum InputError: Error { case captureCount(Int) }

    static let smpMain = ClockID(validated: "smp.main")
    static let musMain = ClockID(validated: "mus.main")
    static let ctxMain = ClockID(validated: "ctx.main")
    static let stateStream = StreamID(validated: "str.state")
    static let verseStream = StreamID(validated: "str.verse")
    static let verse = ActionID(validated: "act.verse")
    static let backing = ActionID(validated: "act.backing")

    // MARK: Sections

    static func clocksRecord(loopEnd: Int64 = 122_880) throws -> ClocksV1Record {
        let fields = try TransportFields(
            host: .init(host: HostID(validated: "host.test"), generation: .initial),
            primaryClock: smpMain, sampleGeneration: .initial, nominalRate: 48_000, musicalClock: musMain,
            transportGeneration: .initial, musicalMapRevision: .initial,
            segments: [TempoSegment(.init(atTicks: 0, microsPerQuarter: 500_000), unknownFields: [:])],
            meter: MusicalMeter(.init(numerator: 4, denominator: 4)),
            loop: LoopRange(startTicks: 0, endTicks: loopEnd))
        let transport = try TransportDocument(revision: .initial, payload: ControlRecord(fields))
        return try ClocksV1Record.make(transport: transport, timebase: HostTimebase(numer: 125, denom: 3))
    }

    static func streamsRecord() throws -> StreamsV1Record {
        try StreamsV1Record.make([
            StreamsV1Record.Stream(id: stateStream, ordinal: 0, media: .state, direction: .playback),
            StreamsV1Record.Stream(id: verseStream, ordinal: 1, media: .midi, direction: .playback),
            StreamsV1Record.Stream(id: MIDICaptureFixture.keysIn, ordinal: 2, media: .midi, direction: .capture)])
    }

    static func initialGenerationsRecord() throws -> InitialGenerationsV1Record {
        let generations: [GenerationKey: Generation] = [
            GenerationKey(.sampleClock, smpMain): .initial,
            GenerationKey(.transport, musMain): .initial,
            GenerationKey(.musicalMap, musMain): .initial,
            GenerationKey(.context, ctxMain): .initial
        ]
        return try InitialGenerationsV1Record.make(generations: generations, musicalClock: musMain)
    }

    static func actionsRecord() throws -> ActionsV1Record {
        let versePolicy = try ActionPolicy(media: .midi, timePolicy: .tempoFollowing,
                                           latePolicy: .nextBoundary(gridTicks: nil), gridTicks: 61_440)
        let backingPolicy = try ActionPolicy(media: .audio, timePolicy: .fixedRate,
                                             latePolicy: .joinInProgress(maxLatenessMs: 50), gridTicks: 61_440)
        let plan = try PrefetchPlan.make(blockFrames: 4_096, blockCount: 16, headFrames: 48_000)
        return try ActionsV1Record.make([
            ActionV1Record.make(id: verse, policy: versePolicy, quantize: .grid(ticks: 61_440), readiness: .ready),
            ActionV1Record.make(id: backing, policy: backingPolicy, quantize: .grid(ticks: 61_440),
                                readiness: .ready, prefetch: plan)])
    }

    // MARK: Timeline entries

    private static func generation(_ value: Int) throws -> Generation {
        try Generation(value)
    }

    private static func anchor( // swiftlint:disable:this function_parameter_count
        _ seq: Int, frame: Int64, host: UInt64, transport: Int, ticks: Int64, loopIteration: UInt32
    ) throws -> TimelineV1Entry {
        let musical = MusicalStamp(transport: try generation(transport), musicalMap: .initial, ticks: ticks,
                                   loopIteration: loopIteration)
        let stamp = ClockAnchor(sample: SampleStamp(clock: smpMain, generation: .initial, frame: frame),
                                host: HostStamp(ticks: host), musical: musical)
        return .anchor(try AnchorV1Record.make(stamp, seq: seq))
    }

    /// What a trigger names; every trigger of this example is stamped under sample 1 and context 1.
    private struct Press {
        let id: StaticString
        let action: ActionID
        let originHostTicks: UInt64
        let horizonFrame: Int64
        let transport: Int
        let note: String?
    }

    private static func trigger(_ seq: Int, _ press: Press) throws -> TimelineV1Entry {
        let requires = [GenerationRequirement(key: GenerationKey(.sampleClock, smpMain), generation: .initial),
                        GenerationRequirement(key: GenerationKey(.transport, musMain),
                                              generation: try generation(press.transport)),
                        GenerationRequirement(key: GenerationKey(.context, ctxMain), generation: .initial)]
        let late: LatePolicy = press.action == verse ? .nextBoundary(gridTicks: nil)
            : .joinInProgress(maxLatenessMs: 50)
        let stamp = TriggerStamp(id: TriggerID(validated: press.id), action: press.action,
                                 originHost: HostStamp(ticks: press.originHostTicks),
                                 horizonFrame: press.horizonFrame, requires: requires,
                                 target: .grid(ticks: 61_440), latePolicy: late)
        return .trigger(try TriggerV1Record.make(stamp, seq: seq, quantize: .grid(ticks: 61_440), note: press.note))
    }

    private static func discontinuity(_ seq: Int, _ event: DiscontinuityV1Record.Event,
                                      frame: Int64) throws -> TimelineV1Entry {
        .discontinuity(try DiscontinuityV1Record.make(event, sampleClock: smpMain, generation: .initial,
                                                      frame: frame, seq: seq))
    }

    private static func dispatch( // swiftlint:disable:this function_parameter_count
        _ seq: Int, frame: Int64, lane: DispatchV1Lane, stream: StreamID, streamSeq: UInt64, event: String
    ) throws -> TimelineV1Entry {
        .dispatch(try DispatchV1Record.make(seq: seq, frame: frame, lane: lane, stream: stream,
                                            streamSeq: streamSeq, event: event))
    }

    private static func fired(_ seq: Int, trigger id: StaticString, frame: Int64,
                              note: String? = nil) throws -> TimelineV1Entry {
        let outcome = TriggerOutcome(trigger: TriggerID(validated: id), result: .fired, assignedFrame: frame,
                                     frame: frame, musicalMap: .initial)
        return .outcome(try TriggerOutcomeV1Record.make(outcome, seq: seq, note: note))
    }

    private static func cancelledByLocate(_ seq: Int) throws -> TimelineV1Entry {
        let outcome = TriggerOutcome(trigger: TriggerID(validated: "trg.2"), result: .cancelled,
                                     stale: .generation(GenerationKey(.transport, musMain)))
        return .outcome(try TriggerOutcomeV1Record.make(outcome, seq: seq))
    }

    private static func locateGeneration(_ seq: Int) throws -> TimelineV1Entry {
        .generation(try GenerationV1Record.make(counter: GenerationKey(.transport, musMain), from: .initial,
                                                to: generation(2), reason: .locate(ticks: 61_440), seq: seq))
    }

    private static func readiness(_ seq: Int, from: ReadinessState, to: ReadinessState,
                                  reason: String? = nil) throws -> TimelineV1Entry {
        .readiness(try ReadinessV1Record.make(backing, from: from, to: to, seq: seq, reason: reason))
    }

    /// The SMF export record of seq 23 over a synthetic header-only file (see the header comment).
    static func smfExportEntry(_ seq: Int, passesOverlaid: Int) throws -> TimelineV1Entry {
        let header: [UInt8] = [0x4D, 0x54, 0x68, 0x64, 0x00, 0x00, 0x00, 0x06, 0x00, 0x01, 0x00, 0x02, 0x03, 0xC0]
        let file = SMFWriteResult(bytes: header,
                                  losses: SMFExportLossReport(losses: [.passesOverlaid: passesOverlaid]),
                                  reorderedItems: 0)
        return .smfExport(try SMFExportV1Record.make(file, streams: [MIDICaptureFixture.keysIn],
                                                     exportID: ExportID(validated: "exp.smf"), seq: seq))
    }

    /// The 23 entries of the example. `horizon` is trg.1's horizon frame; `passesOverlaid` is the loss count of
    /// the export record. Both exist so a test can change one input.
    static func timelineEntries(horizon: Int64 = 192_256, passesOverlaid: Int = 2) throws -> [TimelineV1Entry] {
        let captures = try MIDICaptureFixture.example03().records
        guard captures.count == 3 else { throw InputError.captureCount(captures.count) }
        let beforeWrap = "Event before the wrap, delivered after it: it resolves through iteration 0's anchor."
        let first = Press(id: "trg.1", action: verse, originHostTicks: 2_495_500_000, horizonFrame: horizon,
                          transport: 1,
                          note: "Resolves to the loop end of iteration 0 (the wrap frame 192000), "
                              + "already behind the horizon.")
        let second = Press(id: "trg.2", action: verse, originHostTicks: 2_500_000_000, horizonFrame: 200_256,
                           transport: 1, note: "Resolves to bar 2 of iteration 1 (frame 288000); pending.")
        let third = Press(id: "trg.3", action: backing, originHostTicks: 2_506_000_000, horizonFrame: 212_256,
                          transport: 2, note: "Next bar is the loop end, so it resolves to the wrap frame.")
        return [
            try anchor(1, frame: 0, host: 2_400_000_000, transport: 1, ticks: 0, loopIteration: 0),
            try trigger(2, first),
            try discontinuity(3, .loopWrap, frame: 192_000),
            try anchor(4, frame: 192_000, host: 2_496_000_000, transport: 1, ticks: 0, loopIteration: 1),
            try dispatch(5, frame: 192_000, lane: .release, stream: verseStream, streamSeq: 41,
                         event: "noteOff 60 (owned note, releaseAtWrap)"),
            try dispatch(6, frame: 192_000, lane: .state, stream: stateStream, streamSeq: 7,
                         event: "program 12 (prepared state recall)"),
            try dispatch(7, frame: 192_000, lane: .content, stream: verseStream, streamSeq: 42,
                         event: "noteOn 60"),
            try fired(8, trigger: "trg.1", frame: 288_000,
                      note: "The wrap does not move the resolved target; nextBoundary advances it to bar 2 "
                          + "of iteration 1."),
            .midiCapture(try MIDICaptureV1Record.make(captures[0], seq: 9, note: beforeWrap)),
            .midiCapture(try MIDICaptureV1Record.make(captures[1], seq: 10)),
            try trigger(11, second),
            try locateGeneration(12),
            try discontinuity(13, .locate, frame: 210_000),
            try cancelledByLocate(14),
            try dispatch(15, frame: 210_000, lane: .release, stream: verseStream, streamSeq: 43,
                         event: "all owned notes off (locate)"),
            try readiness(16, from: .ready, to: .invalidated, reason: "locate moved the prefetch head"),
            try anchor(17, frame: 210_000, host: 2_505_000_000, transport: 2, ticks: 61_440, loopIteration: 0),
            try readiness(18, from: .invalidated, to: .preparing),
            try readiness(19, from: .preparing, to: .ready),
            try trigger(20, third),
            try fired(21, trigger: "trg.3", frame: 306_000),
            .midiCapture(try MIDICaptureV1Record.make(captures[2], seq: 22)),
            try smfExportEntry(23, passesOverlaid: passesOverlaid)]
    }

    static func timelineRecord(horizon: Int64 = 192_256, passesOverlaid: Int = 2) throws -> TimelineV1Record {
        try TimelineV1Record.make(timelineEntries(horizon: horizon, passesOverlaid: passesOverlaid))
    }
}
