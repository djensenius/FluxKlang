//
//  SpatialGainRamp.swift
//  FluxKlang
//
//  Linear plan-to-plan gain ramps (#115 M1). Control-rate math only: M1 does
//  not run per-block ramps on the audio thread (that is M2).
//

import Foundation

/// A linear ramp from `from` to `to` over `frames` frames (`0…48,000`).
///
/// Each gain moves linearly in amplitude and never leaves the interval between
/// its endpoints. Linear amplitude interpolation between two unit-power rows
/// dips in power mid-ramp (e.g. to 0.5, −3 dB, halfway between two disjoint
/// speakers); it never rises above the larger endpoint. A 0-frame ramp jumps to
/// `to` immediately.
///
/// Both plans must have identical row identities and identical ordered output
/// columns (`speakerIDs`). A layout reorder or membership change, even at the
/// same speaker count, is refused with `.columnMismatch` rather than ramping one
/// speaker's gain toward another's (an unintended pan); it needs a fresh plan
/// (a jump). An ID-aligned ramp across layout changes is an M2 follow-up.
///
/// Pure value math at control rate: not for the audio thread (building plans
/// allocates). Both plans come only from `SpatialRenderer`, whose plans always
/// have `rowSources.count × speakerIDs.count` gains, so equal rows and columns
/// imply equal gain counts.
struct SpatialGainRamp: Hashable, Sendable {
    static let frameRange: ClosedRange<Int> = 0...48_000

    let from: SpatialRenderPlan
    let to: SpatialRenderPlan
    let frames: Int

    init(from: SpatialRenderPlan, to: SpatialRenderPlan, frames: Int) throws(SpatialRenderError) {
        guard Self.frameRange.contains(frames) else { throw .invalidRampFrames(frames) }
        guard from.speakerCount == to.speakerCount, from.rowSources == to.rowSources else {
            throw .shapeMismatch
        }
        guard from.speakerIDs == to.speakerIDs else { throw .columnMismatch }
        self.from = from
        self.to = to
        self.frames = frames
    }

    /// The gain at `frame`: `from` before frame 0, `to` from `frames` on (so a
    /// 0-frame ramp at any frame ≥ 0 is `to`), linear in between. The guards run
    /// before the division, whose divisor is then always ≥ 1, so no frame yields
    /// a NaN or infinity.
    func gain(row: Int, speaker: Int, frame: Int) -> Double {
        let start = from.gain(row: row, speaker: speaker)
        let end = to.gain(row: row, speaker: speaker)
        guard frame >= 0 else { return start }
        guard frame < frames else { return end }
        let fraction = Double(frame) / Double(frames)
        let value = start + (end - start) * fraction
        return min(max(value, min(start, end)), max(start, end))
    }
}
