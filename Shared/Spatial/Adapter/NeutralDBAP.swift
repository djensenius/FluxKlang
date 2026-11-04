//
//  NeutralDBAP.swift
//  FluxKlang
//
//  The legacy DBAP law (`SpatialPanner.gains`) evaluated in the neutral plane.
//  Because the legacy → neutral transform scales every distance by the same
//  factor and the gains are power-normalised, the default law is unchanged when
//  the blur is scaled with it (0.15 → 0.30).
//

import Foundation

enum NeutralDBAP {
    /// Default attenuation rolloff in dB per doubling of distance (legacy value).
    static let defaultRolloff: Double = 6
    /// Accepted rolloff. Legacy has no rolloff UI; the model always uses 6 and
    /// treats negatives as 0, so this keeps legacy's non-negative domain and
    /// bounds it at 24 dB per doubling (four times the default).
    static let rolloffRange: ClosedRange<Double> = 0...24

    /// Per-speaker amplitude gains (`0…1`) aligned with `layout.speakers`,
    /// normalised to constant power over the participating speakers only;
    /// non-participating speakers get exactly 0 (as legacy routing drops
    /// non-bus speakers). Empty for no speakers, all zero when none participate.
    ///
    /// The legacy law is `wᵢ = 1 / max(dᵢ, blur)^a` with `a = rolloff / 6`.
    /// Power normalisation is scale-invariant, so each weight is evaluated
    /// relative to the nearest participating speaker, `(dmin / dᵢ)^a`: the largest
    /// weight is exactly 1, the others lie in `0…1`, and the power lies in
    /// `1…√64`, so no intermediate square can overflow or underflow to silence.
    static func gains(
        source: NeutralPoint,
        layout: SpatialLayout,
        rolloff: Double = defaultRolloff,
        blur: Double = SpatialSourcePlacement.defaultBlur
    ) throws(SpatialLayoutError) -> [Double] {
        guard rolloff.isFinite, rolloffRange.contains(rolloff) else { throw .invalidRolloff }
        try SpatialSourcePlacement.validate(blur: blur)
        let exponent = rolloff / 6.0
        let distances = layout.speakers.map { speaker -> Double? in
            guard speaker.participatesInPanning else { return nil }
            return max(hypot(source.x - speaker.position.x, source.y - speaker.position.y), blur)
        }
        let weights = relativeWeights(distances: distances, exponent: exponent)
        let power = (weights.reduce(0) { $0 + $1 * $1 }).squareRoot()
        guard power > 0 else { return weights }
        return weights.map { $0 / power }
    }

    /// `(dmin / dᵢ)^exponent` for each positive distance (`nil` → 0). The nearest
    /// weight is exactly 1 and every other lies in `0…1`, whatever the distance
    /// magnitudes, so the later sum of squares cannot overflow or vanish.
    static func relativeWeights(distances: [Double?], exponent: Double) -> [Double] {
        guard let nearest = distances.compactMap(\.self).min() else { return distances.map { _ in 0 } }
        return distances.map { distance -> Double in
            guard let distance else { return 0 }
            return pow(nearest / distance, exponent)
        }
    }

    /// Gains for `placement` using its own blur: one gain array per channel.
    static func gains(
        placement: SpatialSourcePlacement,
        layout: SpatialLayout,
        rolloff: Double = defaultRolloff
    ) throws(SpatialLayoutError) -> [[Double]] {
        var result: [[Double]] = []
        for position in placement.channelPositions() {
            result.append(try gains(source: position, layout: layout, rolloff: rolloff, blur: placement.blur))
        }
        return result
    }
}
