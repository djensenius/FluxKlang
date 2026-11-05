//
//  SpatialRenderPlan.swift
//  FluxKlang
//
//  The control-rate spatial render planner (#115 M1): neutral DBAP law, then
//  post-law masks (mute/solo/loss), optional capped renormalisation, then the
//  applied attenuate-only calibration trim. M1 is a pure planner evaluated off
//  the audio thread; it allocates and is NOT called from a render callback. The
//  allocation-free execution path (and device-channel mapping) is M2.
//

import Foundation

/// Everything one plan depends on. `calibration` is a single applied snapshot
/// (`SpatialCalibrationStage.applied`); pending calibration is never an input.
struct SpatialRenderRequest: Hashable, Sendable {
    let layout: SpatialLayout
    let placements: [SpatialSourcePlacement]
    let masks: SpatialMaskSet
    let calibration: SpatialCalibrationSet
    let rolloff: Double
    /// Routes present on this host; `nil` skips route-loss evaluation.
    let availableRoutes: Set<RouteID>?
    let sampleRate: Double

    init(
        layout: SpatialLayout,
        placements: [SpatialSourcePlacement],
        masks: SpatialMaskSet = .none,
        calibration: SpatialCalibrationSet = .empty,
        rolloff: Double = NeutralDBAP.defaultRolloff,
        availableRoutes: Set<RouteID>? = nil,
        sampleRate: Double = 48_000
    ) {
        self.layout = layout
        self.placements = placements
        self.masks = masks
        self.calibration = calibration
        self.rolloff = rolloff
        self.availableRoutes = availableRoutes
        self.sampleRate = sampleRate
    }
}

/// A gain matrix plus per-speaker delays. Rows are placements in request order,
/// each expanded to its channels in order; columns (outputs) are
/// `layout.speakers` in order. Every gain is finite and in `0…1`.
///
/// Pure value; built off the audio thread (it allocates), never on it. Only
/// `SpatialRenderer` (this file) can construct a plan, so its shape and gain
/// bounds always hold.
struct SpatialRenderPlan: Hashable, Sendable {
    /// The output columns: `layout.speakers` IDs in layout order.
    let speakerIDs: [SpeakerID]
    /// The source of each row (a stereo source contributes two consecutive rows).
    let rowSources: [SpatialSourceID]
    /// Row-major, `rowSources.count × speakerCount`.
    let gains: [Double]
    /// Per speaker, aligned with `layout.speakers`.
    let delayFrames: [Int]
    /// The generation of the calibration snapshot this plan used.
    let calibrationGeneration: Int

    fileprivate init(speakerIDs: [SpeakerID], rowSources: [SpatialSourceID], gains: [Double], delayFrames: [Int],
                     calibrationGeneration: Int) {
        self.speakerIDs = speakerIDs
        self.rowSources = rowSources
        self.gains = gains
        self.delayFrames = delayFrames
        self.calibrationGeneration = calibrationGeneration
    }

    var speakerCount: Int { speakerIDs.count }
    var rowCount: Int { rowSources.count }

    func gain(row: Int, speaker: Int) -> Double {
        gains[row * speakerCount + speaker]
    }

    func row(_ row: Int) -> [Double] {
        Array(gains[(row * speakerCount)..<((row + 1) * speakerCount)])
    }
}

/// Builds `SpatialRenderPlan`s from a request: law, masks, capped opt-in
/// renormalisation, then trim. Pure and deterministic (no clocks, randomness or
/// I/O). Control rate only: it allocates, so it is not for the audio thread.
enum SpatialRenderer {
    static let maximumSources = LegacySpatialImportResult.maximumSources
    /// Ceiling on opt-in survivor renormalisation: ×2 (+6.02 dB).
    static let maximumRenormalizationBoost = 2.0

    /// Builds a plan or refuses with a typed error.
    static func plan(_ request: SpatialRenderRequest) throws(SpatialRenderError) -> SpatialRenderPlan {
        try validate(request)
        let layout = request.layout
        let passes = request.masks.passes(layout: layout, availableRoutes: request.availableRoutes)
        let trims = layout.speakers.map { request.calibration.entry(for: $0.id)?.linearTrim ?? 1 }
        var rowSources: [SpatialSourceID] = []
        var gains: [Double] = []
        for placement in request.placements {
            let channels: [[Double]]
            do {
                channels = try NeutralDBAP.gains(placement: placement, layout: layout, rolloff: request.rolloff)
            } catch {
                throw .layout(error)
            }
            for law in channels {
                rowSources.append(placement.sourceID)
                gains += maskedRow(law: law, passes: passes, trims: trims,
                                   renormalize: request.masks.renormalizeSurvivors)
            }
        }
        var delays: [Int] = []
        for speaker in layout.speakers {
            delays.append(try request.calibration.entry(for: speaker.id)?
                .delayFrames(sampleRate: request.sampleRate) ?? 0)
        }
        return SpatialRenderPlan(speakerIDs: layout.speakers.map(\.id), rowSources: rowSources, gains: gains,
                                 delayFrames: delays, calibrationGeneration: request.calibration.generation)
    }

    /// The plan, or for any refusal an all-zero plan of the request's shape
    /// (no rows when the source count itself is refused) together with the error.
    static func planOrSilence(_ request: SpatialRenderRequest) -> (SpatialRenderPlan, SpatialRenderError?) {
        do {
            return (try plan(request), nil)
        } catch {
            let speakerIDs = request.layout.speakers.map(\.id)
            let speakers = speakerIDs.count
            let rows: [SpatialSourceID] = request.placements.count <= maximumSources
                ? request.placements.flatMap { Array(repeating: $0.sourceID, count: $0.channelCount) }
                : []
            let silent = SpatialRenderPlan(
                speakerIDs: speakerIDs, rowSources: rows, gains: Array(repeating: 0, count: rows.count * speakers),
                delayFrames: Array(repeating: 0, count: speakers),
                calibrationGeneration: request.calibration.generation
            )
            return (silent, error)
        }
    }

    /// The survivor scale for a mute/solo given the survivors' law power `Σg²`:
    /// `1` unless renormalisation is on, else `min(1/√power, maximumRenormalizationBoost)`
    /// (so survivors never exceed unit power), and `1` for zero power.
    static func survivorScale(power: Double, renormalize: Bool) -> Double {
        guard renormalize, power > 0 else { return 1 }
        return min(1 / power.squareRoot(), maximumRenormalizationBoost)
    }

    /// Law → mask → (renormalise over mute/solo survivors only) → loss → trim.
    /// Lost speakers still count as survivors for the scale, so loss only zeroes.
    /// Survivors are rescaled only when a mask removed some law power, so loss
    /// alone or muting a silent speaker never rescales (not even by an ulp).
    /// Each survivor `g ≤ √P`, so `g × scale ≤ 1` and no clamp is needed.
    static func maskedRow(law: [Double], passes: [SpeakerPass], trims: [Double], renormalize: Bool) -> [Double] {
        var survivorPower = 0.0
        var maskedPower = 0.0
        for (gain, pass) in zip(law, passes) {
            if pass == .masked { maskedPower += gain * gain } else { survivorPower += gain * gain }
        }
        let scale = survivorScale(power: survivorPower, renormalize: renormalize && maskedPower > 0)
        return zip(zip(law, passes), trims).map { pair, trim in
            pair.1 == .pass ? pair.0 * scale * trim : 0
        }
    }

    private static func validate(_ request: SpatialRenderRequest) throws(SpatialRenderError) {
        try SpatialSampleRate.validate(request.sampleRate)
        guard request.placements.count <= maximumSources else {
            throw .tooManySources(request.placements.count)
        }
        var seen = Set<SpatialSourceID>()
        for placement in request.placements where !seen.insert(placement.sourceID).inserted {
            throw .duplicateSource(placement.sourceID)
        }
        try request.masks.validate(against: request.layout)
        try request.calibration.validate(against: request.layout)
    }
}
