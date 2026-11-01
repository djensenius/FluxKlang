//
//  ClockMaps.swift
//  FluxKlang
//
//  Exact conversions between the G-MEDIA clock domains (media-contract.md §5.2).
//  Values never convert implicitly (M1): every conversion goes through an anchor
//  whose generations are current, in exact integer arithmetic, rounding half-up
//  (`floor(x + ½)`) only at the final frame or tick.
//

import Foundation

/// Exact v1 media rates; deliberately not a restriction on generic device capabilities.
enum MediaNominalRate {
    static func isValid(_ rate: Int) -> Bool {
        switch rate {
        case 44_100, 48_000, 88_200, 96_000, 176_400, 192_000: true
        default: false
        }
    }
}

/// Why a clock conversion or musical map is not valid.
enum ClockMapError: Error, Equatable, Sendable {
    case staleSampleGeneration
    case staleTransport
    case noMusicalAnchor
    case invalidRate(Int)
    case invalidTimebase
    case invalidMap
    case invalidLoop(startTicks: Int64, endTicks: Int64)
    case overflow
}

enum ExactMath {
    static let nanosPerSecond: Int128 = 1_000_000_000
    static let microsPerSecond: Int128 = 1_000_000

    static func floorDiv(_ num: Int128, _ den: Int128) -> Int128 {
        let quotient = num / den
        return (num % den != 0 && (num < 0) != (den < 0)) ? quotient - 1 : quotient
    }

    static func ceilDiv(_ num: Int128, _ den: Int128) -> Int128 {
        -floorDiv(-num, den)
    }

    /// `floor(num / den + ½)` for `den > 0`.
    static func roundHalfUp(_ num: Int128, _ den: Int128) -> Int128 {
        floorDiv(2 * num + den, 2 * den)
    }

    static func int64(_ value: Int128) throws(ClockMapError) -> Int64 {
        guard let result = Int64(exactly: value) else { throw .overflow }
        return result
    }
}

/// Host ticks to frames on one sample clock generation.
struct SampleClockMap: Hashable, Sendable {
    let anchor: ClockAnchor
    let nominalRate: Int
    let timebase: HostTimebase

    init(anchor: ClockAnchor, nominalRate: Int, timebase: HostTimebase) throws(ClockMapError) {
        guard MediaNominalRate.isValid(nominalRate) else { throw .invalidRate(nominalRate) }
        guard timebase.numer > 0, timebase.denom > 0 else { throw .invalidTimebase }
        self.anchor = anchor
        self.nominalRate = nominalRate
        self.timebase = timebase
    }

    /// Frames elapsed between the anchor and `host`, as a numerator over `denominator`.
    private func elapsed(to host: HostStamp) -> Int128 {
        (Int128(host.ticks) - Int128(anchor.host.ticks)) * Int128(timebase.numer) * Int128(nominalRate)
    }

    private var denominator: Int128 { Int128(timebase.denom) * ExactMath.nanosPerSecond }

    /// The frame at `host`, valid only while the anchor's generation is `current`.
    func frame(atHost host: HostStamp, current: Generation) throws(ClockMapError) -> Int64 {
        guard anchor.sample.generation == current else { throw .staleSampleGeneration }
        return try ExactMath.int64(Int128(anchor.sample.frame) + ExactMath.roundHalfUp(elapsed(to: host), denominator))
    }

    /// Whether `candidate` is a valid later anchor of this generation: it does not
    /// precede this one and agrees with the frame predicted at the nominal rate
    /// within `(rate + span) / 1000` frames (§5.2). Use the generation's first
    /// anchor, or a clock restart point (§5.3 step 4), as `self`.
    func agrees(_ candidate: ClockAnchor) -> Bool {
        guard candidate.sample.clock == anchor.sample.clock,
              candidate.sample.generation == anchor.sample.generation,
              candidate.host.ticks >= anchor.host.ticks,
              candidate.sample.frame >= anchor.sample.frame else { return false }
        let predicted = elapsed(to: candidate.host)
        let difference = (Int128(candidate.sample.frame) - Int128(anchor.sample.frame)) * denominator - predicted
        return difference.magnitude <= (Int128(nominalRate) * denominator + predicted).magnitude / 1000
    }
}

/// One tempo segment, starting at `atTicks`.
struct TempoSegmentFields: ControlFields {
    static let knownKeys: Set<String> = ["atTicks", "microsPerQuarter"]
    let atTicks: Int64
    let microsPerQuarter: Int64

    func validate() throws {
        guard atTicks >= 0, (60_000...3_000_000).contains(microsPerQuarter) else {
            throw ClockMapError.invalidMap
        }
    }
}
typealias TempoSegment = ControlRecord<TempoSegmentFields>

extension ControlRecord where Fields == TempoSegmentFields {
    init(atTicks: Int64, microsPerQuarter: Int64) throws {
        try self.init(.init(atTicks: atTicks, microsPerQuarter: microsPerQuarter))
    }
}

/// The tempo map of one musical clock at one revision (G-MEDIA §2, §5.6).
struct MusicalMap: Hashable, Sendable {
    let clock: ClockID
    let revision: Generation
    let segments: [TempoSegment]

    /// Segments start at tick 0, strictly increase and have positive tempos.
    init(clock: ClockID, revision: Generation, segments: [TempoSegment]) throws(ClockMapError) {
        guard segments.count <= 4096, segments.first?.atTicks == 0,
              zip(segments, segments.dropFirst()).allSatisfy({ $0.atTicks < $1.atTicks }) else {
            throw .invalidMap
        }
        self.clock = clock
        self.revision = revision
        self.segments = segments
    }
}

/// An active loop `[startTicks, endTicks)` (§5.5); `startTicks < endTicks`.
struct LoopRange: Hashable, Sendable, Codable {
    let startTicks: Int64
    let endTicks: Int64
    var unknownFields: [String: JSONValue] = [:]

    init(startTicks: Int64, endTicks: Int64) throws(ClockMapError) {
        guard startTicks >= 0, startTicks < endTicks else {
            throw .invalidLoop(startTicks: startTicks, endTicks: endTicks)
        }
        self.startTicks = startTicks
        self.endTicks = endTicks
    }

    /// v1: musical targets must resolve inside `[startTicks, endTicks]`.
    func admits(ticks: Int64) -> Bool {
        (startTicks...endTicks).contains(ticks)
    }

    init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: DynamicCodingKey.self)
        try self.init(startTicks: fields.decode(Int64.self, forKey: DynamicCodingKey("startTicks")),
                      endTicks: fields.decode(Int64.self, forKey: DynamicCodingKey("endTicks")))
        unknownFields = try ExtensionFields.decode(from: decoder, knownKeys: ["startTicks", "endTicks"])
    }

    func encode(to encoder: any Encoder) throws {
        var fields = encoder.container(keyedBy: DynamicCodingKey.self)
        try fields.encode(startTicks, forKey: DynamicCodingKey("startTicks"))
        try fields.encode(endTicks, forKey: DynamicCodingKey("endTicks"))
        try ExtensionFields.encode(unknownFields, to: encoder, knownKeys: ["startTicks", "endTicks"])
    }
}

/// Musical ticks to frames and back through a musical anchor of the current
/// transport generation and the current map. Offsets are kept in units of
/// `1 / (ticksPerQuarter · 10⁶)` frames, so every segment shares one denominator.
struct MusicalClockMap: Hashable, Sendable {
    let anchor: ClockAnchor
    let musical: MusicalStamp
    let map: MusicalMap
    let nominalRate: Int

    init(anchor: ClockAnchor, map: MusicalMap, nominalRate: Int,
         currentSample: Generation, currentTransport: Generation) throws(ClockMapError) {
        guard let musical = anchor.musical else { throw .noMusicalAnchor }
        guard anchor.sample.generation == currentSample else { throw .staleSampleGeneration }
        guard musical.transport == currentTransport else { throw .staleTransport }
        guard MediaNominalRate.isValid(nominalRate) else { throw .invalidRate(nominalRate) }
        self.anchor = anchor
        self.musical = musical
        self.map = map
        self.nominalRate = nominalRate
    }

    private static let unitsPerFrame = Int128(MusicalTime.ticksPerQuarter) * ExactMath.microsPerSecond

    private func cost(_ index: Int) -> Int128 {
        Int128(map.segments[index].microsPerQuarter) * Int128(nominalRate)
    }

    private func segmentIndex(containing ticks: Int64) -> Int {
        map.segments.lastIndex { $0.atTicks <= ticks } ?? 0
    }

    /// Units between `start` and `end` ticks (negative when `end < start`).
    private func units(from start: Int64, to end: Int64) -> Int128 {
        if end < start { return -units(from: end, to: start) }
        var total: Int128 = 0
        var position = start
        var index = segmentIndex(containing: start)
        while position < end {
            let next = index + 1 < map.segments.count ? min(map.segments[index + 1].atTicks, end) : end
            total += (Int128(next) - Int128(position)) * cost(index)
            position = next
            index += 1
        }
        return total
    }

    /// The frame of `ticks`, rounded half-up.
    func frame(atTicks ticks: Int64) throws(ClockMapError) -> Int64 {
        let offset = units(from: musical.ticks, to: ticks)
        return try ExactMath.int64(Int128(anchor.sample.frame) + ExactMath.roundHalfUp(offset, Self.unitsPerFrame))
    }

    /// The exact tick position of `frame` as `numerator / denominator` (the inverse of `frame(atTicks:)`).
    func exactTicks(atFrame frame: Int64) -> (numerator: Int128, denominator: Int128) {
        var remaining = (Int128(frame) - Int128(anchor.sample.frame)) * Self.unitsPerFrame
        var position = musical.ticks
        var index = segmentIndex(containing: position)
        if remaining >= 0 {
            while index + 1 < map.segments.count {
                let span = (Int128(map.segments[index + 1].atTicks) - Int128(position)) * cost(index)
                guard remaining >= span else { break }
                remaining -= span
                position = map.segments[index + 1].atTicks
                index += 1
            }
            return (Int128(position) * cost(index) + remaining, cost(index))
        }
        remaining = -remaining
        while index > 0 || map.segments[index].atTicks < position {
            if map.segments[index].atTicks == position { index -= 1; continue }
            let span = (Int128(position) - Int128(map.segments[index].atTicks)) * cost(index)
            guard remaining > span, index > 0 else { break }
            remaining -= span
            position = map.segments[index].atTicks
            index -= 1
        }
        return (Int128(position) * cost(index) - remaining, cost(index))
    }

    /// The tick of `frame`, rounded half-up.
    func ticks(atFrame frame: Int64) throws(ClockMapError) -> Int64 {
        let exact = exactTicks(atFrame: frame)
        return try ExactMath.int64(ExactMath.roundHalfUp(exact.numerator, exact.denominator))
    }

    /// The first `grid` boundary at or after `frame` (`grid > 0`).
    func boundary(atOrAfterFrame frame: Int64, grid: Int64) throws(ClockMapError) -> Int64 {
        guard grid > 0 else { throw .invalidMap }
        let exact = exactTicks(atFrame: frame)
        return try ExactMath.int64(
            ExactMath.ceilDiv(exact.numerator, exact.denominator * Int128(grid)) * Int128(grid)
        )
    }
}
