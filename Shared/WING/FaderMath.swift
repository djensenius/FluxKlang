//
//  FaderMath.swift
//  FluxKlang
//
//  Conversion between the WING fader law (a normalised float in 0.0...1.0) and
//  decibels. The WING uses the classic X32-family piecewise mapping, where
//  unity gain (0 dB) sits at position 0.75 and the top of travel (+10 dB) at
//  1.0. The lowest representable position (0.0) is treated as "off" (-∞).
//

import Foundation

/// Pure, stateless conversions for the WING fader taper.
///
/// The WING transmits and receives fader positions as a normalised `Float` in
/// the range `0.0...1.0`, which maps non-linearly to decibels via a four-segment
/// piecewise curve. All functions clamp their inputs to the valid range.
enum FaderMath {
    /// Lowest decibel value represented by the fader law (position `0.0`).
    static let minimumDecibels: Float = -90

    /// Highest decibel value represented by the fader law (position `1.0`).
    static let maximumDecibels: Float = 10

    /// Fader position corresponding to unity gain (0 dB).
    static let unityPosition: Float = 0.75

    /// Converts a normalised fader position (`0.0...1.0`) to decibels.
    static func decibels(fromPosition position: Float) -> Float {
        let clamped = position.clamped(to: 0 ... 1)
        switch clamped {
        case 0.5...:
            return clamped * 40 - 30
        case 0.25...:
            return clamped * 80 - 50
        case 0.0625...:
            return clamped * 160 - 70
        default:
            return clamped * 480 - 90
        }
    }

    /// Converts decibels to a normalised fader position (`0.0...1.0`).
    static func position(fromDecibels decibels: Float) -> Float {
        let position: Float
        switch decibels {
        case ..<(-60):
            position = (decibels + 90) / 480
        case ..<(-30):
            position = (decibels + 70) / 160
        case ..<(-10):
            position = (decibels + 50) / 80
        case ...10:
            position = (decibels + 30) / 40
        default:
            position = 1
        }
        return position.clamped(to: 0 ... 1)
    }

    /// Whether a fader position represents "off" (fully attenuated, -∞ dB).
    static func isOff(position: Float) -> Bool {
        position <= 0
    }

    /// A human-readable decibel label, e.g. `"0.0 dB"`, `"-10.0 dB"`, `"-∞ dB"`.
    static func label(forPosition position: Float) -> String {
        isOff(position: position)
            ? "-∞ dB"
            : String(format: "%.1f dB", decibels(fromPosition: position))
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
