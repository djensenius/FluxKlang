//
//  ClockStamps.swift
//  FluxKlang
//
//  The G-MEDIA v1 control-plane values: distinct sample, host
//  and musical stamps, generation keys and the IDs that must be unique. Host
//  stamps are transient runtime data and deliberately not Codable (M13).
//  String identities are not RT-safe. RuntimeVocabulary.swift supplies the
//  fixed-size kernel counterparts required by media-contract.md §3.
//

import Foundation

enum ClockTag: ContractIDTag {}
typealias ClockID = ContractID<ClockTag>
enum StreamTag: ContractIDTag {}
typealias StreamID = ContractID<StreamTag>
enum TriggerTag: ContractIDTag {}
typealias TriggerID = ContractID<TriggerTag>
enum TakeTag: ContractIDTag {}
typealias TakeID = ContractID<TakeTag>
enum ExportTag: ContractIDTag {}
typealias ExportID = ContractID<ExportTag>
/// The subject of a generation counter: a clock, stream, context or cancel scope.
enum GenerationSubjectTag: ContractIDTag {}
typealias GenerationSubject = ContractID<GenerationSubjectTag>

/// Fixed ticks per quarter note for musical time (G-MEDIA §2).
enum MusicalTime {
    static let ticksPerQuarter: Int64 = 15_360
}

/// A frame on one sample clock generation.
struct SampleStamp: Hashable, Sendable, Codable {
    let clock: ClockID
    let generation: Generation
    let frame: Int64
}

/// Monotonic host ticks. Transient: never persisted (M13).
struct HostStamp: Hashable, Sendable, BitwiseCopyable {
    let ticks: UInt64
}

/// The process-wide host timebase: nanoseconds per tick is `numer / denom`.
struct HostTimebase: Hashable, Sendable, BitwiseCopyable {
    let numer: UInt32
    let denom: UInt32
}

/// A position in musical time, valid only for its transport generation.
struct MusicalStamp: Hashable, Sendable, Codable {
    let transport: Generation
    let musicalMap: Generation
    let ticks: Int64
    let loopIteration: UInt32
}

/// One simultaneous observation of the clocks (G-MEDIA §2, §5.2).
struct ClockAnchor: Hashable, Sendable {
    let sample: SampleStamp
    let host: HostStamp
    var musical: MusicalStamp?
}

/// The generation counter kinds of G-MEDIA §5.1.
enum GenerationKind: String, Codable, Sendable, CaseIterable, BitwiseCopyable {
    case sampleClock, transport, musicalMap, source, context, cancelScope
}

/// A counter, keyed `kind/subject` (for example `transport/mus.main`).
struct GenerationKey: Hashable, Sendable, Codable, CustomStringConvertible {
    let kind: GenerationKind
    let subject: GenerationSubject

    init(kind: GenerationKind, subject: GenerationSubject) {
        self.kind = kind
        self.subject = subject
    }

    /// The counter of any contract ID; all IDs share one alphabet.
    init(_ kind: GenerationKind, _ id: ContractID<some ContractIDTag>) {
        guard let subject = GenerationSubject(rawValue: id.rawValue) else {
            preconditionFailure("Contract IDs share one alphabet")
        }
        self.init(kind: kind, subject: subject)
    }

    var description: String { "\(kind.rawValue)/\(subject.rawValue)" }
}

/// A trigger's dependency on the exact value of one counter.
struct GenerationRequirement: Hashable, Sendable {
    let key: GenerationKey
    let generation: Generation
}
