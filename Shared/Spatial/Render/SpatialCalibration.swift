//
//  SpatialCalibration.swift
//  FluxKlang
//
//  Per-speaker calibration values (#115 M1): an attenuate-only trim and a
//  bounded delay. Values are relative and uncalibrated (no SPL claim); they are
//  entered or applied from a draft, never measured here.
//

import Foundation

/// Accepted render sample rates; delays convert to frames at one of these.
enum SpatialSampleRate {
    static let range: ClosedRange<Double> = 8_000...384_000

    static func validate(_ rate: Double) throws(SpatialRenderError) {
        guard rate.isFinite, range.contains(rate) else { throw .invalidSampleRate }
    }
}

/// One speaker's trim and delay.
struct SpeakerCalibration: Hashable, Sendable, Codable {
    /// Attenuate-only: calibration can never raise a gain.
    static let trimRange: ClosedRange<Double> = -60...0
    /// Up to 50 ms (about 17 m of path difference).
    static let delayRange: ClosedRange<Double> = 0...0.05

    let speaker: SpeakerID
    let trimDecibels: Double
    let delaySeconds: Double

    init(speaker: SpeakerID, trimDecibels: Double = 0, delaySeconds: Double = 0) throws(SpatialRenderError) {
        guard trimDecibels.isFinite, Self.trimRange.contains(trimDecibels) else { throw .invalidTrim(speaker) }
        guard delaySeconds.isFinite, Self.delayRange.contains(delaySeconds) else { throw .invalidDelay(speaker) }
        self.speaker = speaker
        self.trimDecibels = trimDecibels
        self.delaySeconds = delaySeconds
    }

    /// The trim as a linear factor in `0.001…1`.
    var linearTrim: Double { pow(10, trimDecibels / 20) }

    /// The delay in whole frames at `sampleRate`, rounded half-up
    /// (at most 19,200 frames at 384 kHz).
    func delayFrames(sampleRate: Double) throws(SpatialRenderError) -> Int {
        try SpatialSampleRate.validate(sampleRate)
        return Int((delaySeconds * sampleRate).rounded(.toNearestOrAwayFromZero))
    }

    private enum CodingKeys: String, CodingKey { case speaker, trimDecibels, delaySeconds }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let speaker = try container.decode(SpeakerID.self, forKey: .speaker)
        let trim = try container.decode(Double.self, forKey: .trimDecibels)
        let delay = try container.decode(Double.self, forKey: .delaySeconds)
        do {
            try self.init(speaker: speaker, trimDecibels: trim, delaySeconds: delay)
        } catch {
            throw SpatialRenderDecoding.corrupted(decoder, error)
        }
    }
}

/// A whole calibration: at most one entry per speaker, sorted by speaker ID,
/// with a non-negative generation. Speakers without an entry get 0 dB and no delay.
struct SpatialCalibrationSet: Hashable, Sendable, Codable {
    static let maximumEntries = 64
    static let empty = Self(generation: 0, sorted: [])

    let generation: Int
    let entries: [SpeakerCalibration]

    init(generation: Int = 0, entries: [SpeakerCalibration] = []) throws(SpatialRenderError) {
        guard generation >= 0 else { throw .invalidGeneration(generation) }
        guard entries.count <= Self.maximumEntries else { throw .tooManyCalibrationEntries(entries.count) }
        var seen = Set<SpeakerID>()
        for entry in entries where !seen.insert(entry.speaker).inserted {
            throw .duplicateCalibration(entry.speaker)
        }
        self.init(generation: generation, sorted: entries.sorted { $0.speaker < $1.speaker })
    }

    private init(generation: Int, sorted: [SpeakerCalibration]) {
        self.generation = generation
        self.entries = sorted
    }

    func entry(for speaker: SpeakerID) -> SpeakerCalibration? {
        entries.first { $0.speaker == speaker }
    }

    /// Refuses an entry naming a speaker that is not in `layout`.
    func validate(against layout: SpatialLayout) throws(SpatialRenderError) {
        let known = Set(layout.speakers.map(\.id))
        for entry in entries where !known.contains(entry.speaker) {
            throw .unknownCalibrationSpeaker(entry.speaker)
        }
    }

    private enum CodingKeys: String, CodingKey { case generation, entries }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let generation = try container.decode(Int.self, forKey: .generation)
        let entries = try container.decodeIfPresent([SpeakerCalibration].self, forKey: .entries) ?? []
        do {
            try self.init(generation: generation, entries: entries)
        } catch {
            throw SpatialRenderDecoding.corrupted(decoder, error)
        }
    }
}

/// Applied calibration plus at most one pending set. Only `applied` is ever
/// rendered; a pending set changes nothing until `promote` swaps it in whole,
/// so no plan mixes pending and applied entries.
struct SpatialCalibrationStage: Hashable, Sendable {
    private(set) var applied: SpatialCalibrationSet
    private(set) var pending: SpatialCalibrationSet?

    init(applied: SpatialCalibrationSet = .empty) {
        self.applied = applied
        self.pending = nil
    }

    /// Stages `set` (replacing any pending set). It must be exactly one
    /// generation after `applied`.
    mutating func stage(_ set: SpatialCalibrationSet) throws(SpatialRenderError) {
        let (next, overflow) = applied.generation.addingReportingOverflow(1)
        guard !overflow else { throw .invalidGeneration(set.generation) }
        guard set.generation == next else { throw .staleCalibration(expected: next, found: set.generation) }
        pending = set
    }

    /// Applies the pending set whole, provided it is `expected`.
    mutating func promote(expected: SpatialCalibrationSet) throws(SpatialRenderError) {
        guard let pending else { throw .noPendingCalibration }
        guard pending == expected else { throw .pendingMismatch }
        applied = pending
        self.pending = nil
    }

    mutating func discard() {
        pending = nil
    }
}
