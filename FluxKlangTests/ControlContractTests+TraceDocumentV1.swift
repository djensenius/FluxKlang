//
//  ControlContractTests+TraceDocumentV1.swift
//  FluxKlangTests
//
//  The complete media contract v1 trace document: root shape, deterministic encoding, optional sections,
//  schema refusals, and the checker's static time-stretch capability requirement.
//

import Foundation
import Testing
@testable import FluxKlang

private func traceDocument(
    exampleId: String = "ex.01-clock-restart",
    title: String = "Clock restart",
    covers: [String] = ["clockRestart"],
    initialGenerations suppliedInitialGenerations: InitialGenerationsV1Record? = nil,
    timeline suppliedTimeline: TimelineV1Record? = nil,
    notes: [String]? = nil,
    adapterCapabilities: TraceDocumentV1.AdapterCapabilities? = nil,
    streams: StreamsV1Record? = nil,
    actions: ActionsV1Record? = nil,
    extensions: [String: JSONValue]? = nil
) throws -> TraceDocumentV1 {
    let sampleClock = ClockID(validated: "smp.main")
    let musicalClock = ClockID(validated: "mus.main")
    let fields = try TransportFields(
        host: .init(host: HostID(validated: "host.test"), generation: .initial),
        primaryClock: sampleClock, sampleGeneration: .initial, nominalRate: 48_000,
        musicalClock: musicalClock, transportGeneration: .initial, musicalMapRevision: .initial,
        segments: [TempoSegment(.init(atTicks: 0, microsPerQuarter: 500_000), unknownFields: [:])],
        meter: MusicalMeter(.init(numerator: 4, denominator: 4)), loop: nil)
    let transport = try TransportDocument(revision: .initial, payload: ControlRecord(fields))
    let clocks = try ClocksV1Record.make(transport: transport, timebase: HostTimebase(numer: 125, denom: 3))
    let generations: [GenerationKey: Generation] = [
        GenerationKey(.sampleClock, sampleClock): .initial,
        GenerationKey(.transport, musicalClock): .initial,
        GenerationKey(.musicalMap, musicalClock): .initial
    ]
    let initialGenerations = try suppliedInitialGenerations
        ?? InitialGenerationsV1Record.make(generations: generations, musicalClock: musicalClock)
    let timeline = try suppliedTimeline
        ?? TimelineV1Record.make([ControlContractTests.TimelineV1Fixtures.anchor(1)])
    return try TraceDocumentV1.make(
        exampleId: exampleId, title: title, covers: covers, clocks: clocks,
        initialGenerations: initialGenerations, timeline: timeline, notes: notes,
        adapterCapabilities: adapterCapabilities, streams: streams, actions: actions, extensions: extensions)
}

private func traceDocumentRefusal(
    exampleId: String = "ex.01-clock-restart",
    title: String = "Clock restart",
    covers: [String] = ["clockRestart"],
    initialGenerations: InitialGenerationsV1Record? = nil,
    timeline: TimelineV1Record? = nil,
    notes: [String]? = nil,
    adapterCapabilities: TraceDocumentV1.AdapterCapabilities? = nil,
    streams: StreamsV1Record? = nil,
    actions: ActionsV1Record? = nil
) -> TraceDocumentV1Refusal? {
    do {
        _ = try traceDocument(exampleId: exampleId, title: title, covers: covers,
                              initialGenerations: initialGenerations, timeline: timeline, notes: notes,
                              adapterCapabilities: adapterCapabilities, streams: streams, actions: actions)
        return nil
    } catch let error as TraceDocumentV1Refusal {
        return error
    } catch {
        Issue.record(error)
        return nil
    }
}

private func canonicalJSON(_ data: Data) throws -> Data {
    let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .fragmentsAllowed])
}

private func traceAnchor(
    _ seq: Int,
    clock: String,
    generation: Generation = .initial
) throws -> TimelineV1Entry {
    let anchor = ClockAnchor(
        sample: SampleStamp(clock: try ClockID(clock), generation: generation, frame: 0),
        host: HostStamp(ticks: 1), musical: nil)
    return .anchor(try AnchorV1Record.make(anchor, seq: seq))
}

private func traceTrigger(
    _ seq: Int,
    target: TriggerTarget,
    requires: [GenerationRequirement]
) throws -> TimelineV1Entry {
    let stamp = TriggerStamp(
        id: TriggerID(validated: "trg.test"), action: ActionID(validated: "act.backing"),
        originHost: HostStamp(ticks: 1), horizonFrame: 0, requires: requires, target: target, latePolicy: .drop)
    return .trigger(try TriggerV1Record.make(stamp, seq: seq))
}

private func traceDispatch(_ seq: Int, stream: String) throws -> TimelineV1Entry {
    .dispatch(try DispatchV1Record.make(
        seq: seq, frame: 0, lane: .content, stream: StreamID(stream), streamSeq: 1, event: "event"))
}

private func traceOutcome(_ seq: Int, trigger: String) throws -> TimelineV1Entry {
    let outcome = TriggerOutcome(
        trigger: try TriggerID(trigger), result: .fired, assignedFrame: 0, frame: 0, musicalMap: .initial)
    return .outcome(try TriggerOutcomeV1Record.make(outcome, seq: seq))
}

extension ControlContractTests {
    struct TraceDocumentV1Assembly {
        @Test func documentWritesItsFixedEnvelopeAndExactlyTheRequiredRootKeys() throws {
            let document = try traceDocument()
            let data = try document.encodedJSON()
            let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(object["contract"] as? String == "fluxklang.media")
            #expect(object["version"] as? Int == 1)
            #expect(TraceDocumentV1.contract == "fluxklang.media")
            #expect(TraceDocumentV1.version == 1)
            #expect(Set(object.keys) == Set([
                "contract", "version", "exampleId", "title", "covers", "clocks", "initialGenerations", "timeline"
            ]))
            #expect(try document.encodedJSON() == data)
        }

        @Test func documentKeepsTheBuiltTimelineOrderAndSectionPayloads() throws {
            let document = try traceDocument()
            let object = try #require(JSONSerialization.jsonObject(with: document.encodedJSON()) as? [String: Any])
            let timeline = try #require(object["timeline"] as? [[String: Any]])
            try #require(timeline.count == 1)
            #expect(timeline[0]["seq"] as? Int == 1)
            #expect(timeline[0]["kind"] as? String == "anchor")
            let clocks = try #require(object["clocks"])
            let initialGenerations = try #require(object["initialGenerations"])
            let builtTimeline = try #require(object["timeline"])
            #expect(try canonicalJSON(JSONSerialization.data(withJSONObject: clocks))
                    == canonicalJSON(document.clocks.encodedJSON()))
            #expect(try canonicalJSON(JSONSerialization.data(withJSONObject: initialGenerations))
                    == canonicalJSON(document.initialGenerations.encodedJSON()))
            #expect(try canonicalJSON(JSONSerialization.data(withJSONObject: builtTimeline))
                    == canonicalJSON(document.timeline.encodedJSON()))
        }

        @Test func documentOmitsAbsentOptionalsAndIncludesSuppliedValues() throws {
            let absent = try traceDocument()
            let absentObject = try #require(JSONSerialization.jsonObject(with: absent.encodedJSON()) as? [String: Any])
            #expect(absentObject["notes"] == nil)
            #expect(absentObject["adapterCapabilities"] == nil)
            #expect(absentObject["streams"] == nil)
            #expect(absentObject["actions"] == nil)
            #expect(absentObject["extensions"] == nil)

            let streams = try StreamsV1Record.make([
                StreamsV1Record.Stream(id: StreamID(validated: "str.bed"), ordinal: 4,
                                       media: .audio, direction: .playback)
            ])
            let actions = try ActionsV1Record.make([ControlContractTests.ActionV1Fixtures.simple()])
            let present = try traceDocument(
                notes: [], adapterCapabilities: .init(timeStretch: nil), streams: streams, actions: actions,
                extensions: ["custom": .object(["enabled": .bool(true)])])
            let presentObject = try #require(
                JSONSerialization.jsonObject(with: present.encodedJSON()) as? [String: Any])
            #expect(presentObject["notes"] as? [String] == [])
            #expect((presentObject["adapterCapabilities"] as? [String: Any])?.isEmpty == true)
            #expect((presentObject["streams"] as? [[String: Any]])?.first?["ordinal"] as? Int == 4)
            #expect((presentObject["actions"] as? [[String: Any]])?.first?["actionId"] as? String == "act.a")
            #expect(presentObject["extensions"] != nil)
        }

        @Test func documentRootRefusalsFollowSchemaOrderWithoutTrimmingOrNoteLimits() throws {
            #expect(traceDocumentRefusal(exampleId: "bad", title: "", covers: [])
                    == .invalidExampleID("bad"))
            #expect(traceDocumentRefusal(title: "") == .emptyTitle)
            #expect(traceDocumentRefusal(covers: []) == .emptyCovers)
            #expect(traceDocumentRefusal(covers: ["clockRestart", "not-a-coverage"])
                    == .invalidCoverage(index: 1, value: "not-a-coverage"))
            #expect(traceDocumentRefusal(covers: ["not-a-coverage"], notes: [""])
                    == .invalidCoverage(index: 0, value: "not-a-coverage"))
            #expect(traceDocumentRefusal(notes: ["ok", ""]) == .emptyNote(index: 1))
            #expect(try traceDocument(exampleId: "ex.01-a").exampleId == "ex.01-a")

            let unrestrictedText = String(repeating: "x", count: 300)
            #expect(try traceDocument(title: " ", covers: ["clockRestart", "clockRestart"],
                                      notes: [" ", unrestrictedText]).title == " ")
        }

        @Test func readyTimeStretchActionsRequireTheDeclaredAdapterCapability() throws {
            let policy = try ControlContractTests.ActionV1Fixtures.policy(media: .audio, time: .timeStretch)
            let action = try ActionV1Record.make(
                id: ControlContractTests.ActionV1Fixtures.id("act.stretch"), policy: policy, quantize: .asap,
                readiness: .ready, prefetch: ControlContractTests.ActionV1Fixtures.plan())
            let actions = try ActionsV1Record.make([action])
            #expect(traceDocumentRefusal(actions: actions) == .timeStretchCapabilityRequired(action.id))
            #expect(traceDocumentRefusal(adapterCapabilities: .init(timeStretch: false), actions: actions)
                    == .timeStretchCapabilityRequired(action.id))
            #expect(traceDocumentRefusal(notes: [""], actions: actions) == .emptyNote(index: 0))
            #expect(try traceDocument(adapterCapabilities: .init(timeStretch: true), actions: actions)
                    .adapterCapabilities?.timeStretch == true)

            let unprepared = try ActionV1Record.make(
                id: action.id, policy: policy, quantize: .asap, readiness: .unprepared,
                prefetch: ControlContractTests.ActionV1Fixtures.plan())
            let unpreparedActions = try ActionsV1Record.make([unprepared])
            let transitions = try TimelineV1Record.make([
                .readiness(try ReadinessV1Record.make(action.id, from: .unprepared, to: .preparing, seq: 1)),
                .readiness(try ReadinessV1Record.make(action.id, from: .preparing, to: .ready, seq: 2))
            ])
            #expect(traceDocumentRefusal(timeline: transitions, actions: unpreparedActions)
                    == .timeStretchCapabilityRequired(action.id))
            #expect(try traceDocument(timeline: transitions, adapterCapabilities: .init(timeStretch: true),
                                      actions: unpreparedActions)
                    .timeline.entries.count == 2)
        }

        @Test func documentChecksInitialMusicalCountersAgainstItsClockHeader() throws {
            let otherClock = ClockID(validated: "mus.other")
            let supplied = try InitialGenerationsV1Record.make(generations: [
                GenerationKey(.sampleClock, ClockID(validated: "smp.main")): .initial,
                GenerationKey(.transport, otherClock): .initial,
                GenerationKey(.musicalMap, otherClock): .initial
            ], musicalClock: otherClock)
            #expect(traceDocumentRefusal(initialGenerations: supplied)
                    == .undeclaredMusicalClockCounter(GenerationKey(.musicalMap, otherClock)))
        }

        @Test func documentChecksDeclaredActionAndClockReferencesInTimelineOrder() throws {
            let ghostAction = try ControlContractTests.TimelineV1Fixtures.trigger(1, action: "act.ghost")
            let triggerTimeline = try TimelineV1Record.make([ghostAction])
            #expect(traceDocumentRefusal(timeline: triggerTimeline)
                    == .undeclaredAction(ActionID(validated: "act.ghost")))
            let ghostReadiness = try ReadinessV1Record.make(
                ActionID(validated: "act.ghost"), from: .unprepared, to: .preparing, seq: 1)
            let readinessTimeline = try TimelineV1Record.make([.readiness(ghostReadiness)])
            #expect(traceDocumentRefusal(timeline: readinessTimeline)
                    == .undeclaredAction(ActionID(validated: "act.ghost")))

            let ghostClock = try TimelineV1Record.make([traceAnchor(1, clock: "smp.ghost")])
            #expect(traceDocumentRefusal(timeline: ghostClock)
                    == .undeclaredClock(ClockID(validated: "smp.ghost")))

            let first = try traceDispatch(1, stream: "str.ghost")
            let later = try traceAnchor(2, clock: "smp.ghost")
            let ordered = try TimelineV1Record.make([first, later])
            #expect(traceDocumentRefusal(timeline: ordered) == .undeclaredStream(StreamID(validated: "str.ghost")))
        }

        @Test func documentChecksGenerationCountersAgainstDeclaredHeaders() throws {
            let otherSampleClock = ClockID(validated: "smp.other")
            let supplied = try InitialGenerationsV1Record.make(generations: [
                GenerationKey(.sampleClock, otherSampleClock): .initial,
                GenerationKey(.transport, ClockID(validated: "mus.main")): .initial,
                GenerationKey(.musicalMap, ClockID(validated: "mus.main")): .initial
            ], musicalClock: ClockID(validated: "mus.main"))
            #expect(traceDocumentRefusal(initialGenerations: supplied)
                    == .undeclaredSampleClockCounter(GenerationKey(.sampleClock, otherSampleClock)))

            let key = GenerationKey(.context, ClockID(validated: "ctx.ghost"))
            let bump = try GenerationV1Record.make(
                counter: key, from: .initial, to: Generation(2), reason: .contextChange, seq: 1)
            let timeline = try TimelineV1Record.make([.generation(bump)])
            #expect(traceDocumentRefusal(timeline: timeline) == .undeclaredGenerationCounter(key))
        }

        @Test func sampleClockReferencesRequireAnInitialGeneration() throws {
            let musicalClock = ControlContractTests.TimelineV1Fixtures.musicalClock
            let sampleClock = ControlContractTests.TimelineV1Fixtures.clock
            let key = GenerationKey(.sampleClock, sampleClock)
            let initialGenerations = try InitialGenerationsV1Record.make(generations: [
                GenerationKey(.transport, musicalClock): .initial,
                GenerationKey(.musicalMap, musicalClock): .initial
            ], musicalClock: musicalClock)
            let anchor = try TimelineV1Record.make([ControlContractTests.TimelineV1Fixtures.anchor(1)])
            let discontinuity = try TimelineV1Record.make([ControlContractTests.TimelineV1Fixtures.discontinuity(1)])

            #expect(traceDocumentRefusal(initialGenerations: initialGenerations, timeline: anchor)
                    == .undeclaredGenerationCounter(key))
            #expect(traceDocumentRefusal(initialGenerations: initialGenerations, timeline: discontinuity)
                    == .undeclaredGenerationCounter(key))
        }

        @Test func takeSegmentsRequireEarlierMatchingAnchors() throws {
            let takeEntry = try ControlContractTests.TimelineV1Fixtures.take(
                1, id: TakeID(validated: "tk.trace"))
            guard case .take(let take) = takeEntry else {
                Issue.record("TimelineV1Fixtures.take must build a take record")
                return
            }
            let takeStreams = try StreamsV1Record.make([
                .init(id: take.stream, ordinal: 0, media: .audio, direction: .capture)
            ])
            let takeTimeline = try TimelineV1Record.make([.take(take)])
            let takeSegment = try #require(take.segments.first)
            let takeAnchor = try traceAnchor(
                1, clock: takeSegment.sampleClock.rawValue, generation: takeSegment.generation)
            let anchoredTakeEntry = try ControlContractTests.TimelineV1Fixtures.take(
                2, id: TakeID(validated: "tk.trace"))
            guard case .take(let anchoredTakeRecord) = anchoredTakeEntry else {
                Issue.record("TimelineV1Fixtures.take must build a take record")
                return
            }
            let anchoredTake = try TimelineV1Record.make([
                takeAnchor,
                .take(anchoredTakeRecord)
            ])
            let musicalClock = ControlContractTests.TimelineV1Fixtures.musicalClock
            let noSampleGeneration = try InitialGenerationsV1Record.make(generations: [
                GenerationKey(.transport, musicalClock): .initial,
                GenerationKey(.musicalMap, musicalClock): .initial
            ], musicalClock: musicalClock)

            #expect(traceDocumentRefusal(timeline: takeTimeline, streams: takeStreams)
                    == .sampleGenerationWithoutEarlierAnchor(
                        sampleClock: takeSegment.sampleClock, generation: takeSegment.generation))
            #expect(traceDocumentRefusal(
                initialGenerations: noSampleGeneration, timeline: takeTimeline, streams: takeStreams)
                    == .undeclaredGenerationCounter(GenerationKey(.sampleClock, takeSegment.sampleClock)))
            #expect(traceDocumentRefusal(timeline: anchoredTake, streams: takeStreams) == nil)
        }

        @Test func nativeExportsRequireEarlierCapturesAndMatchingAnchors() throws {
            let captureLog = try MIDICaptureFixture.example10()
            let capture = try #require(captureLog.records.first)
            let nativeExport = try NativeUMPExport.make(
                from: captureLog, id: MIDICaptureFixture.umpExport,
                streams: [MIDICaptureFixture.synth, MIDICaptureFixture.legacy],
                origin: MIDICaptureFixture.origin(1, frame: 24_000))
            let exportStreams = try StreamsV1Record.make(nativeExport.streams.enumerated().map { index, stream in
                .init(id: stream, ordinal: index, media: .midi, direction: .capture)
            })
            let musicalClock = ControlContractTests.TimelineV1Fixtures.musicalClock
            let noSampleGeneration = try InitialGenerationsV1Record.make(generations: [
                GenerationKey(.transport, musicalClock): .initial,
                GenerationKey(.musicalMap, musicalClock): .initial
            ], musicalClock: musicalClock)
            let unrecordedExport = try NativeUMPExportV1Record.make(nativeExport, seq: 1)
            let unrecordedTimeline = try TimelineV1Record.make([.export(unrecordedExport)])
            let captureEntry = TimelineV1Entry.midiCapture(try MIDICaptureV1Record.make(capture, seq: 1))
            let unanchoredExport = try NativeUMPExportV1Record.make(nativeExport, seq: 2)
            let unanchoredTimeline = try TimelineV1Record.make([captureEntry, .export(unanchoredExport)])
            let anchor = try traceAnchor(
                1, clock: unanchoredExport.origin.sampleClock.rawValue,
                generation: unanchoredExport.origin.generation)
            let recordedCapture = TimelineV1Entry.midiCapture(try MIDICaptureV1Record.make(capture, seq: 2))
            let anchoredExport = try NativeUMPExportV1Record.make(nativeExport, seq: 3)
            let anchoredTimeline = try TimelineV1Record.make([
                anchor, recordedCapture, .export(anchoredExport)
            ])

            #expect(traceDocumentRefusal(timeline: unrecordedTimeline, streams: exportStreams)
                    == .exportWithoutEarlierCapture(unrecordedExport.exportID))
            #expect(traceDocumentRefusal(timeline: unanchoredTimeline, streams: exportStreams)
                    == .sampleGenerationWithoutEarlierAnchor(
                        sampleClock: unanchoredExport.origin.sampleClock,
                        generation: unanchoredExport.origin.generation))
            #expect(traceDocumentRefusal(
                initialGenerations: noSampleGeneration, timeline: unanchoredTimeline, streams: exportStreams)
                    == .undeclaredGenerationCounter(GenerationKey(.sampleClock, unanchoredExport.origin.sampleClock)))
            #expect(traceDocumentRefusal(timeline: anchoredTimeline, streams: exportStreams) == nil)
        }

        @Test func smfExportsRequireAnEarlierCaptureOnOneListedStream() throws {
            let captureLog = try MIDICaptureFixture.example10()
            let capture = try #require(captureLog.records.first)
            let streamIDs = [MIDICaptureFixture.synth, MIDICaptureFixture.legacy]
            let exportStreams = try StreamsV1Record.make(streamIDs.enumerated().map { index, stream in
                .init(id: stream, ordinal: index, media: .midi, direction: .capture)
            })
            let smfBytes: [UInt8] = [0x4D, 0x54, 0x68, 0x64, 0, 0, 0, 6, 0, 0, 0, 1, 0x3C, 0]
            let smfFile = SMFWriteResult(
                bytes: smfBytes, losses: SMFExportLossReport(losses: [:]), reorderedItems: 0)
            let smfID = ExportID(validated: "exp.smf")
            let unrecordedSMF = try SMFExportV1Record.make(
                smfFile, streams: streamIDs, exportID: smfID, seq: 1)
            let unrecordedSMFTimeline = try TimelineV1Record.make([.smfExport(unrecordedSMF)])
            #expect(traceDocumentRefusal(timeline: unrecordedSMFTimeline, streams: exportStreams)
                    == .exportWithoutEarlierCapture(smfID))

            let recordedSMF = try SMFExportV1Record.make(
                smfFile, streams: streamIDs, exportID: smfID, seq: 2)
            let captureEntry = TimelineV1Entry.midiCapture(try MIDICaptureV1Record.make(capture, seq: 1))
            let recordedSMFTimeline = try TimelineV1Record.make([captureEntry, .smfExport(recordedSMF)])
            #expect(traceDocumentRefusal(timeline: recordedSMFTimeline, streams: exportStreams) == nil)
        }

        @Test func triggerRecordsRequireTheCheckersClockAndContextCounters() throws {
            let action = try ControlContractTests.ActionV1Fixtures.simple("act.backing")
            let actions = try ActionsV1Record.make([action])
            let sampleKey = GenerationKey(.sampleClock, ControlContractTests.TimelineV1Fixtures.clock)
            let contextKey = GenerationKey(.context, ClockID(validated: "ctx.main"))
            let transportKey = GenerationKey(.transport, ControlContractTests.TimelineV1Fixtures.musicalClock)
            let context = GenerationRequirement(key: contextKey, generation: .initial)
            let sample = GenerationRequirement(key: sampleKey, generation: .initial)
            let transport = GenerationRequirement(key: transportKey, generation: .initial)

            #expect(traceDocumentRefusal(
                timeline: try TimelineV1Record.make([traceTrigger(1, target: .asap, requires: [context])]),
                actions: actions) == .missingTriggerPrimaryClockRequirement(TriggerID(validated: "trg.test")))
            #expect(traceDocumentRefusal(
                timeline: try TimelineV1Record.make([traceTrigger(1, target: .asap, requires: [sample])]),
                actions: actions) == .missingTriggerContextRequirement(TriggerID(validated: "trg.test")))
            #expect(traceDocumentRefusal(
                timeline: try TimelineV1Record.make([
                    traceTrigger(1, target: .musical(atTicks: 0), requires: [sample, context])
                ]), actions: actions) == .missingTriggerTransportRequirement(TriggerID(validated: "trg.test")))

            let nextBoundaryPolicy = try ControlContractTests.ActionV1Fixtures.policy(
                late: .nextBoundary(gridTicks: 1), grid: 1)
            let nextBoundaryAction = try ActionV1Record.make(
                id: ActionID(validated: "act.backing"), policy: nextBoundaryPolicy, quantize: .grid(ticks: 1),
                readiness: .ready)
            let nextBoundaryActions = try ActionsV1Record.make([nextBoundaryAction])
            let sampleTarget = try TimelineV1Record.make([
                traceTrigger(1, target: .sample(atFrame: 0), requires: [sample, context])
            ])
            #expect(traceDocumentRefusal(timeline: sampleTarget, actions: nextBoundaryActions)
                    == .missingTriggerTransportRequirement(TriggerID(validated: "trg.test")))

            let valid = try TimelineV1Record.make([
                traceTrigger(1, target: .musical(atTicks: 0), requires: [sample, context, transport])
            ])
            #expect(traceDocumentRefusal(timeline: valid, actions: actions) == nil)

        }

        @Test func documentChecksStreamDeclarationsAndOnlyApplicableMediaAndDirection() throws {
            let undeclared = try TimelineV1Record.make([traceDispatch(1, stream: "str.ghost")])
            #expect(traceDocumentRefusal(timeline: undeclared)
                    == .undeclaredStream(StreamID(validated: "str.ghost")))

            let streamID = StreamID(validated: "str.capture")
            let capture = try StreamsV1Record.make([
                .init(id: streamID, ordinal: 0, media: .audio, direction: .capture)
            ])
            let underrun = try DiscontinuityV1Record.make(
                .underrun(streamID, frames: 1), sampleClock: ClockID(validated: "smp.main"),
                generation: .initial, frame: 0, seq: 1)
            let underrunTimeline = try TimelineV1Record.make([.discontinuity(underrun)])
            #expect(traceDocumentRefusal(timeline: underrunTimeline, streams: capture)
                    == .incompatibleStream(streamID, media: nil, direction: .playback))
            let captureDispatch = try TimelineV1Record.make([traceDispatch(1, stream: "str.capture")])
            #expect(traceDocumentRefusal(timeline: captureDispatch, streams: capture) == nil)

            let midiCapture = try ControlContractTests.TimelineV1Fixtures.midiCapture(1)
            let midiTimeline = try TimelineV1Record.make([midiCapture])
            let audioCapture = try StreamsV1Record.make([
                .init(id: MIDICaptureFixture.keysA, ordinal: 0, media: .audio, direction: .capture)
            ])
            #expect(traceDocumentRefusal(timeline: midiTimeline, streams: audioCapture)
                    == .incompatibleStream(MIDICaptureFixture.keysA, media: .midi, direction: .capture))
        }

        @Test func outcomeRequiresItsTriggerEarlierInTheCallerOrderedTimeline() throws {
            let actions = try ActionsV1Record.make([
                ControlContractTests.ActionV1Fixtures.simple("act.backing")
            ])
            let outcomeBeforeTrigger = try TimelineV1Record.make([
                traceOutcome(1, trigger: "trg.1"),
                ControlContractTests.TimelineV1Fixtures.trigger(2)
            ])
            #expect(traceDocumentRefusal(timeline: outcomeBeforeTrigger, actions: actions)
                    == .outcomeWithoutEarlierTrigger(TriggerID(validated: "trg.1")))

            let triggerBeforeOutcome = try TimelineV1Record.make([
                ControlContractTests.TimelineV1Fixtures.trigger(1),
                traceOutcome(2, trigger: "trg.1")
            ])
            #expect(traceDocumentRefusal(timeline: triggerBeforeOutcome, actions: actions) == nil)
        }
    }
}
