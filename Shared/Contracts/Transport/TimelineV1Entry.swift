//
//  TimelineV1Entry.swift
//  FluxKlang
//
//  One element of the media contract v1 trace's `timeline` array (#84 TRC1): a built record of one of the ten kinds
//  in the schema's `timeline.items` `oneOf`. A closed enum, so a new kind is a compile error until it is handled.
//

/// A built record of one timeline kind. The payloads are immutable and carry their own `seq`. The schema has ten
/// kinds; the `export` kind has two cases, one per format: `.export` is `nativeUmp` and `.smfExport` is `smf`.
enum TimelineV1Entry: Hashable, Sendable {
    case anchor(AnchorV1Record)
    case generation(GenerationV1Record)
    case trigger(TriggerV1Record)
    case outcome(TriggerOutcomeV1Record)
    case readiness(ReadinessV1Record)
    case discontinuity(DiscontinuityV1Record)
    case dispatch(DispatchV1Record)
    case midiCapture(MIDICaptureV1Record)
    case take(RecordingTakeV1Record)
    case export(NativeUMPExportV1Record)
    case smfExport(SMFExportV1Record)

    /// The wrapped record's own `seq`.
    var seq: Int {
        switch self {
        case .anchor(let record): record.seq
        case .generation(let record): record.seq
        case .trigger(let record): record.seq
        case .outcome(let record): record.seq
        case .readiness(let record): record.seq
        case .discontinuity(let record): record.seq
        case .dispatch(let record): record.seq
        case .midiCapture(let record): record.seq
        case .take(let record): record.seq
        case .export(let record): record.seq
        case .smfExport(let record): record.seq
        }
    }

    /// The wrapped record's `kind`, the schema's discriminator.
    var kind: String {
        switch self {
        case .anchor: AnchorV1Record.kind
        case .generation: GenerationV1Record.kind
        case .trigger: TriggerV1Record.kind
        case .outcome: TriggerOutcomeV1Record.kind
        case .readiness: ReadinessV1Record.kind
        case .discontinuity: DiscontinuityV1Record.kind
        case .dispatch: DispatchV1Record.kind
        case .midiCapture: MIDICaptureV1Record.kind
        case .take: RecordingTakeV1Record.kind
        case .export: NativeUMPExportV1Record.kind
        case .smfExport: SMFExportV1Record.kind
        }
    }
}

extension TimelineV1Entry: Encodable {
    // swiftlint:disable cyclomatic_complexity
    /// Writes the payload exactly as its own `encodedJSON()` does.
    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .anchor(let record): try container.encode(record)
        case .generation(let record): try container.encode(record)
        case .trigger(let record): try container.encode(record)
        case .outcome(let record): try container.encode(record)
        case .readiness(let record): try container.encode(record)
        case .discontinuity(let record): try container.encode(record)
        case .dispatch(let record): try container.encode(record)
        case .midiCapture(let record): try container.encode(record)
        case .take(let record): try container.encode(record)
        case .export(let record): try container.encode(record)
        case .smfExport(let record): try container.encode(record)
        }
    }
    // swiftlint:enable cyclomatic_complexity
}
