//
//  SpatialPanner.swift
//  FluxKlang
//
//  Distance-Based Amplitude Panning (DBAP) for an arbitrary speaker layout.
//  Given a source position and the speaker positions, it returns a per-speaker
//  amplitude gain, normalised to constant power, and converts those gains into
//  WING bus-send levels in decibels.
//

import CoreGraphics
import Foundation

/// Pure, stateless spatial-panning math. Works for any number of speakers in any
/// arrangement, so it covers stereo, quad and larger arrays equally.
enum SpatialPanner {
    /// Distances closer than this (in unit space) are clamped, so a source sitting
    /// exactly on a speaker doesn't produce an unbounded gain.
    static let spatialBlur: Double = 0.15

    /// Default attenuation rolloff in dB per doubling of distance.
    static let defaultRolloff: Double = 6

    /// Lowest send level emitted for an effectively silent speaker.
    static let silenceFloor: Float = -60

    /// Per-speaker amplitude gains (`0...1`) for a source at `source`, normalised
    /// so the sum of squares is `1` (constant acoustic power). Returns an empty
    /// array when there are no speakers.
    static func gains(
        source: CGPoint,
        speakers: [CGPoint],
        rolloff: Double = defaultRolloff,
        blur: Double = spatialBlur
    ) -> [Double] {
        guard !speakers.isEmpty else { return [] }
        let exponent = max(rolloff, 0) / 6.0
        let weights = speakers.map { speaker -> Double in
            let deltaX = Double(source.x - speaker.x)
            let deltaY = Double(source.y - speaker.y)
            let distance = max(hypot(deltaX, deltaY), blur)
            return 1.0 / pow(distance, exponent)
        }
        let power = (weights.reduce(0) { $0 + $1 * $1 }).squareRoot()
        guard power > 0 else { return speakers.map { _ in 0 } }
        return weights.map { $0 / power }
    }

    /// Converts an amplitude gain (`0...1`) to a WING send level in decibels,
    /// clamped to `floor...0` so the panner never boosts a send above unity.
    static func decibels(forGain gain: Double, floor: Float = silenceFloor) -> Float {
        guard gain > 0.0001 else { return floor }
        let decibels = Float(20 * log10(gain))
        return min(max(decibels, floor), 0)
    }
}
