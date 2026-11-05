//
//  SpatialPositionDescription.swift
//  FluxKlang
//
//  Spoken words-plus-numbers descriptions of neutral positions (#116 PL1).
//  Positions are always spoken as words plus numbers, never only coordinates.
//

/// Describes a neutral position for VoiceOver and other spoken output.
///
/// - Axes follow `SpatialLayout`: x grows to the right (−1 far left, +1 far
///   right) and y grows to the front (+1 far in front, −1 far behind), as in
///   the legacy import `y′ = 1 − 2y` where legacy y grew toward the rear.
/// - Bands (owner ruling), by absolute value on each axis: below 0.05 is
///   "centre"; below 0.35 "slightly"; below 0.75 plain; 0.75 and above "far".
///   Each edge belongs to the outer band, so 0.05 is already "slightly". The
///   band is chosen from the printed hundredths, so the words always agree
///   with the numbers: 0.0499 prints "0.05" and is "slightly".
/// - Words: x says "slightly right of centre", "right of centre", "far right"
///   (left alike); y says "slightly in front", "in front", "far in front"
///   (behind alike).
/// - Numbers: two decimals, `value × 100` rounded half away from zero, with a
///   leading "-" for negatives and never "-0.00".
/// - Format: "<x words>, <y words>; x <x>, y <y>", for example
///   "slightly right of centre, in front; x 0.10, y 0.60", or
///   "centre; x 0.00, y 0.00" when both axes are centre.
enum SpatialPositionDescription {
    enum Band: Hashable, Sendable, CaseIterable {
        case centre
        case slight
        case plain
        case far
    }

    /// Band edges in hundredths: 0.05, 0.35 and 0.75.
    static let slightEdge = 5
    static let plainEdge = 35
    static let farEdge = 75

    /// A finite value in hundredths, rounded half away from zero, as printed.
    static func hundredths(_ value: Double) -> Int {
        Int((value * 100).rounded(.toNearestOrAwayFromZero))
    }

    /// The band of a finite axis value, from its printed hundredths.
    static func band(_ value: Double) -> Band {
        let magnitude = hundredths(value).magnitude
        if magnitude < slightEdge { return .centre }
        if magnitude < plainEdge { return .slight }
        if magnitude < farEdge { return .plain }
        return .far
    }

    /// Words for a finite x: "centre", "slightly left of centre", "right of centre", "far left"...
    static func words(forX value: Double) -> String {
        let side = value < 0 ? "left" : "right"
        switch band(value) {
        case .centre: return "centre"
        case .slight: return "slightly \(side) of centre"
        case .plain: return "\(side) of centre"
        case .far: return "far \(side)"
        }
    }

    /// Words for a finite y: "centre", "slightly in front", "behind", "far in front"...
    static func words(forY value: Double) -> String {
        let side = value < 0 ? "behind" : "in front"
        switch band(value) {
        case .centre: return "centre"
        case .slight: return "slightly \(side)"
        case .plain: return side
        case .far: return "far \(side)"
        }
    }

    /// Both axes in words: "slightly right of centre, in front", or "centre" when both are centre.
    static func words(_ point: NeutralPoint) -> String {
        guard band(point.x) != .centre || band(point.y) != .centre else { return "centre" }
        return "\(words(forX: point.x)), \(words(forY: point.y))"
    }

    /// A finite value in `−1…1` with two decimals: "0.10", "-0.35", "1.00".
    static func number(_ value: Double) -> String {
        let scaled = hundredths(value)
        let magnitude = scaled.magnitude
        let fraction = magnitude % 100
        let sign = scaled < 0 ? "-" : ""
        return "\(sign)\(magnitude / 100).\(fraction < 10 ? "0" : "")\(fraction)"
    }

    /// "slightly right of centre, in front; x 0.10, y 0.60".
    static func describe(_ point: NeutralPoint) -> String {
        "\(words(point)); x \(number(point.x)), y \(number(point.y))"
    }

    /// The source element: its name (or ID), the position words, then the
    /// numbers, with width for a stereo source only (a mono source has none):
    /// "Soft Synth, slightly right of centre, in front; x 0.10, y 0.60, width 0.50".
    static func describe(_ placement: SpatialSourcePlacement) -> String {
        let name = placement.name ?? placement.sourceID.rawValue
        let point = placement.position
        let width = placement.channelCount == 2 ? ", width \(number(placement.width))" : ""
        return "\(name), \(words(point)); x \(number(point.x)), y \(number(point.y))\(width)"
    }

    /// The spoken value of one adjustable element: "slightly right of centre, 0.10"
    /// for X, "in front, 0.60" for Y and "0.50" for Width. Nil for Width on a
    /// mono source, which has no width: `describe(_:)` omits it and the UI hides it.
    static func value(of axis: SpatialEditAxis, in placement: SpatialSourcePlacement) -> String? {
        switch axis {
        case .x: "\(words(forX: placement.position.x)), \(number(placement.position.x))"
        case .y: "\(words(forY: placement.position.y)), \(number(placement.position.y))"
        case .width: placement.channelCount == 2 ? number(placement.width) : nil
        }
    }
}
