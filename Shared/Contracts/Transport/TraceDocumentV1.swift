//
//  TraceDocumentV1.swift
//  FluxKlang
//
//  The complete media contract v1 trace document, assembled from its validated typed sections.
//

import Foundation

/// A complete media contract v1 trace. Its sections are already-built immutable records; the assembler preserves
/// their order and performs only root-schema validation and static header/reference checks.
struct TraceDocumentV1: Hashable, Sendable {
    static let contract = "fluxklang.media"
    static let version = 1

    /// The optional `adapterCapabilities` object. `nil` represents an empty object when the object itself is supplied.
    struct AdapterCapabilities: Hashable, Sendable, Encodable {
        let timeStretch: Bool?
    }

    let exampleId: String
    let title: String
    let covers: [String]
    let clocks: ClocksV1Record
    let initialGenerations: InitialGenerationsV1Record
    let timeline: TimelineV1Record
    let notes: [String]?
    let adapterCapabilities: AdapterCapabilities?
    let streams: StreamsV1Record?
    let actions: ActionsV1Record?
    let extensions: [String: JSONValue]?

    /// Builds a trace document or throws the first root refusal in `TraceDocumentV1Refusal` order.
    ///
    /// The typed sections retain their own validation, sequence values and ordering. The assembler does not replay
    /// the timeline or infer cross-record state.
    static func make( // swiftlint:disable:this function_parameter_count
        exampleId: String,
        title: String,
        covers: [String],
        clocks: ClocksV1Record,
        initialGenerations: InitialGenerationsV1Record,
        timeline: TimelineV1Record,
        notes: [String]? = nil,
        adapterCapabilities: AdapterCapabilities? = nil,
        streams: StreamsV1Record? = nil,
        actions: ActionsV1Record? = nil,
        extensions: [String: JSONValue]? = nil
    ) throws(TraceDocumentV1Refusal) -> TraceDocumentV1 {
        guard Self.validExampleID(exampleId) else { throw .invalidExampleID(exampleId) }
        guard !title.isEmpty else { throw .emptyTitle }
        guard !covers.isEmpty else { throw .emptyCovers }
        for (index, coverage) in covers.enumerated() where !Self.coverageValues.contains(coverage) {
            throw .invalidCoverage(index: index, value: coverage)
        }
        if let notes {
            for (index, note) in notes.enumerated() where note.isEmpty {
                throw .emptyNote(index: index)
            }
        }
        let document = TraceDocumentV1(
            exampleId: exampleId,
            title: title,
            covers: covers,
            clocks: clocks,
            initialGenerations: initialGenerations,
            timeline: timeline,
            notes: notes,
            adapterCapabilities: adapterCapabilities,
            streams: streams,
            actions: actions,
            extensions: extensions
        )
        try document.checkStaticRelationships()
        return document
    }

    /// Compact UTF-8 JSON with sorted keys and unescaped slashes (`ContractCoding`).
    func encodedJSON() throws -> Data {
        try ContractCoding.makeEncoder().encode(self)
    }

    // swiftlint:disable cyclomatic_complexity
    /// Validates header and ordered timeline references; replay and state transitions remain with the checker.
    private func checkStaticRelationships() throws(TraceDocumentV1Refusal) {
        let declaredClocks = Set(clocks.sample.map(\.clockID))
        let declaredStreams = Dictionary(uniqueKeysWithValues: (streams?.streams ?? []).map { ($0.id, $0) })
        let declaredActions = Dictionary(uniqueKeysWithValues: (actions?.actions ?? []).map { ($0.id, $0) })
        var earlierAnchors: [ClockID: Set<Generation>] = [:]
        try checkInitialGenerations(declaredClocks: declaredClocks)
        if adapterCapabilities?.timeStretch != true {
            for action in actions?.actions ?? []
                where action.readiness == .ready && action.policy.timePolicy == .timeStretch {
                throw .timeStretchCapabilityRequired(action.id)
            }
        }

        func checkSampleClockGeneration(_ clock: ClockID) throws(TraceDocumentV1Refusal) {
            guard declaredClocks.contains(clock) else { throw .undeclaredClock(clock) }
            let key = GenerationKey(.sampleClock, clock)
            guard initialGenerations.generations[key] != nil else { throw .undeclaredGenerationCounter(key) }
        }

        func checkEarlierAnchor(_ clock: ClockID, generation: Generation) throws(TraceDocumentV1Refusal) {
            guard earlierAnchors[clock]?.contains(generation) == true else {
                throw .sampleGenerationWithoutEarlierAnchor(sampleClock: clock, generation: generation)
            }
        }

        func checkStream(
            _ streamID: StreamID,
            media: StreamsV1Record.Media?,
            direction: StreamsV1Record.Direction?
        ) throws(TraceDocumentV1Refusal) {
            guard let stream = declaredStreams[streamID] else { throw .undeclaredStream(streamID) }
            guard (media == nil || stream.media == media) && (direction == nil || stream.direction == direction) else {
                throw .incompatibleStream(streamID, media: media, direction: direction)
            }
        }

        var earlierTriggers = Set<TriggerID>()
        var earlierCaptures = Set<StreamID>()
        for entry in timeline.entries {
            switch entry {
            case .anchor(let record):
                try checkSampleClockGeneration(record.sampleClock)
                earlierAnchors[record.sampleClock, default: []].insert(record.generation)
            case .generation(let record):
                guard initialGenerations.generations[record.counter] != nil else {
                    throw .undeclaredGenerationCounter(record.counter)
                }
            case .trigger(let record):
                guard let action = declaredActions[record.actionID] else { throw .undeclaredAction(record.actionID) }
                try checkTriggerRequirements(record, action: action)
                earlierTriggers.insert(record.triggerID)
            case .outcome(let record):
                guard earlierTriggers.contains(record.triggerID) else {
                    throw .outcomeWithoutEarlierTrigger(record.triggerID)
                }
            case .readiness(let record):
                guard let action = declaredActions[record.actionID] else { throw .undeclaredAction(record.actionID) }
                if record.to == .ready, action.policy.timePolicy == .timeStretch,
                   adapterCapabilities?.timeStretch != true {
                    throw .timeStretchCapabilityRequired(record.actionID)
                }
            case .discontinuity(let record):
                try checkSampleClockGeneration(record.sampleClock)
                switch record.event {
                case .underrun(let stream, _):
                    try checkStream(stream, media: nil, direction: .playback)
                case .overflow(let stream, _):
                    try checkStream(stream, media: nil, direction: .capture)
                case .sourceLost(let stream), .sourceRestored(let stream), .formatChange(let stream),
                     .captureStopped(let stream, _):
                    try checkStream(stream, media: nil, direction: nil)
                case .clockRestart, .sampleJump, .locate, .loopWrap:
                    break
                }
            case .dispatch(let record):
                try checkStream(record.stream, media: nil, direction: nil)
            case .midiCapture(let record):
                try checkStream(record.stream, media: .midi, direction: .capture)
                earlierCaptures.insert(record.stream)
            case .take(let record):
                try checkStream(record.stream, media: .audio, direction: .capture)
                for segment in record.segments {
                    try checkSampleClockGeneration(segment.sampleClock)
                    try checkEarlierAnchor(segment.sampleClock, generation: segment.generation)
                }
            case .export(let record):
                for stream in record.streams {
                    try checkStream(stream, media: .midi, direction: .capture)
                }
                guard record.streams.contains(where: { earlierCaptures.contains($0) }) else {
                    throw .exportWithoutEarlierCapture(record.exportID)
                }
                try checkSampleClockGeneration(record.origin.sampleClock)
                try checkEarlierAnchor(record.origin.sampleClock, generation: record.origin.generation)
            case .smfExport(let record):
                for stream in record.streams {
                    try checkStream(stream, media: .midi, direction: .capture)
                }
                guard record.streams.contains(where: { earlierCaptures.contains($0) }) else {
                    throw .exportWithoutEarlierCapture(record.exportID)
                }
            }
        }
    }
    // swiftlint:enable cyclomatic_complexity

    private func checkInitialGenerations(declaredClocks: Set<ClockID>) throws(TraceDocumentV1Refusal) {
        let musicalClock = clocks.musicalClock.rawValue
        let orderedCounters = initialGenerations.generations.keys.sorted {
            $0.description.utf8.lexicographicallyPrecedes($1.description.utf8)
        }
        for key in orderedCounters {
            switch key.kind {
            case .sampleClock:
                guard declaredClocks.contains(where: { $0.rawValue == key.subject.rawValue }) else {
                    throw .undeclaredSampleClockCounter(key)
                }
            case .transport, .musicalMap:
                guard key.subject.rawValue == musicalClock else { throw .undeclaredMusicalClockCounter(key) }
            case .source, .context, .cancelScope:
                continue
            }
        }
    }

    private func checkTriggerRequirements(
        _ record: TriggerV1Record,
        action: ActionV1Record
    ) throws(TraceDocumentV1Refusal) {
        let primaryClock = clocks.sample[0].clockID
        let primaryClockKey = GenerationKey(.sampleClock, primaryClock)
        guard record.requires[primaryClockKey] != nil else {
            throw .missingTriggerPrimaryClockRequirement(record.triggerID)
        }
        guard record.requires.keys.contains(where: { $0.kind == .context }) else {
            throw .missingTriggerContextRequirement(record.triggerID)
        }

        let target = record.target ?? action.quantize
        let needsTransport: Bool
        if case .nextBoundary = action.policy.latePolicy {
            needsTransport = true
        } else {
            needsTransport = target.isMusical
        }
        if needsTransport {
            let transportKey = GenerationKey(.transport, clocks.musicalClock)
            guard record.requires[transportKey] != nil else {
                throw .missingTriggerTransportRequirement(record.triggerID)
            }
        }
    }

    private static let coverageValues: Set<String> = [
        "clockRestart", "lateCue", "retroactiveCue", "seek", "loop", "tempoMutation", "sourceLoss",
        "noStaleReplay", "cancellation", "readiness", "prefetch", "ordering", "capture", "fixedRateDefault",
        "timeStretchPolicy", "midi1InUmp", "midi2Native", "smfExportLossy", "smfExportLossless"
    ]

    private static func validExampleID(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard bytes.count >= 7,
              bytes[0...2].elementsEqual(Array("ex.".utf8)),
              bytes[3...4].allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }),
              bytes[5] == UInt8(ascii: "-") else { return false }
        return bytes[6...].allSatisfy {
            (UInt8(ascii: "a")...UInt8(ascii: "z")).contains($0)
                || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0)
                || $0 == UInt8(ascii: "-")
        }
    }

    private init(
        exampleId: String,
        title: String,
        covers: [String],
        clocks: ClocksV1Record,
        initialGenerations: InitialGenerationsV1Record,
        timeline: TimelineV1Record,
        notes: [String]?,
        adapterCapabilities: AdapterCapabilities?,
        streams: StreamsV1Record?,
        actions: ActionsV1Record?,
        extensions: [String: JSONValue]?
    ) {
        self.exampleId = exampleId
        self.title = title
        self.covers = covers
        self.clocks = clocks
        self.initialGenerations = initialGenerations
        self.timeline = timeline
        self.notes = notes
        self.adapterCapabilities = adapterCapabilities
        self.streams = streams
        self.actions = actions
        self.extensions = extensions
    }
}

/// Why a media contract v1 root document cannot be assembled. Checks run in this order: root schema fields;
/// initial-generation counters in UTF-8 key order; initially-ready time-stretch actions in declaration order; then
/// timeline references in caller order (each entry's references in schema/checker order). Triggers require the
/// checker's dependency keys; take segments and native export origins require an earlier matching anchor; exports
/// require an earlier capture from at least one listed stream. Replay and state-transition rules remain with the
/// checker.
enum TraceDocumentV1Refusal: Error, Hashable, Sendable {
    case invalidExampleID(String)
    case emptyTitle
    case emptyCovers
    case invalidCoverage(index: Int, value: String)
    case emptyNote(index: Int)
    case undeclaredSampleClockCounter(GenerationKey)
    case undeclaredMusicalClockCounter(GenerationKey)
    case undeclaredClock(ClockID)
    case undeclaredGenerationCounter(GenerationKey)
    case undeclaredAction(ActionID)
    case undeclaredStream(StreamID)
    case incompatibleStream(StreamID, media: StreamsV1Record.Media?, direction: StreamsV1Record.Direction?)
    case missingTriggerPrimaryClockRequirement(TriggerID)
    case missingTriggerContextRequirement(TriggerID)
    case missingTriggerTransportRequirement(TriggerID)
    case exportWithoutEarlierCapture(ExportID)
    case outcomeWithoutEarlierTrigger(TriggerID)
    case sampleGenerationWithoutEarlierAnchor(sampleClock: ClockID, generation: Generation)
    case timeStretchCapabilityRequired(ActionID)
}

extension TraceDocumentV1: Encodable {
    private enum CodingKeys: String, CodingKey {
        case contract, version, exampleId, title, covers, clocks, initialGenerations, timeline
        case notes, adapterCapabilities, streams, actions, extensions
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.contract, forKey: .contract)
        try container.encode(Self.version, forKey: .version)
        try container.encode(exampleId, forKey: .exampleId)
        try container.encode(title, forKey: .title)
        try container.encode(covers, forKey: .covers)
        try container.encode(clocks, forKey: .clocks)
        try container.encode(initialGenerations, forKey: .initialGenerations)
        try container.encode(timeline, forKey: .timeline)
        try container.encodeIfPresent(notes, forKey: .notes)
        try container.encodeIfPresent(adapterCapabilities, forKey: .adapterCapabilities)
        try container.encodeIfPresent(streams, forKey: .streams)
        try container.encodeIfPresent(actions, forKey: .actions)
        try container.encodeIfPresent(extensions, forKey: .extensions)
    }
}
