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
    static func gains(
        source: NeutralPoint,
        layout: SpatialLayout,
        rolloff: Double = defaultRolloff,
        blur: Double = SpatialSourcePlacement.defaultBlur
    ) throws(SpatialLayoutError) -> [Double] {
        guard rolloff.isFinite, rolloffRange.contains(rolloff) else { throw .invalidRolloff }
        guard blur.isFinite, blur > 0 else { throw .invalidBlur }
        let exponent = rolloff / 6.0
        let weights = layout.speakers.map { speaker -> Double in
            guard speaker.participatesInPanning else { return 0 }
            let distance = max(hypot(source.x - speaker.position.x, source.y - speaker.position.y), blur)
            return 1.0 / pow(distance, exponent)
        }
        let power = (weights.reduce(0) { $0 + $1 * $1 }).squareRoot()
        guard power > 0, power.isFinite else { return weights.map { _ in 0 } }
        return weights.map { $0 / power }
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
