//
//  MIDIClockJitterSummary.swift
//  FluxKlang
//
//  Integer summary of the arrival jitter of MIDI clock pulses over a bounded window of host stamps. It summarises a
//  window of stamps the caller supplies; it estimates no tempo, arbitrates nothing and reads no clock.
//

/// The statistics of the intervals between consecutive pulse stamps, built only by `make`.
///
/// Deviations are kept scaled: a deviation of `scaled` is `scaled / nominal.pulses` host ticks, so no rounding
/// happens before the caller asks for it. The exact mean interval is `totalTicks / intervalCount`.
struct MIDIClockJitterSummary: Equatable, Sendable {
    /// The most stamps one window holds; one more is refused.
    static let maximumStamps = 1_024
    /// A window needs two stamps to hold one interval.
    static let minimumStamps = 2
    static let percentileRange = 1...100

    /// Intervals in the window: the stamp count minus one.
    var intervalCount: Int { storedFigures.intervalCount }
    var minimumInterval: UInt64 { storedFigures.minimumInterval }
    var maximumInterval: UInt64 { storedFigures.maximumInterval }
    /// The sum of the intervals: the last stamp minus the first.
    var totalTicks: UInt64 { storedFigures.totalTicks }
    /// `totalTicks / intervalCount` rounded toward zero (floor); the exact mean is the pair of those two values.
    var meanFloorTicks: UInt64 { storedFigures.totalTicks / UInt64(storedFigures.intervalCount) }
    /// The largest absolute deviation from nominal, scaled by `nominal.pulses`.
    var maximumDeviationScaled: Int128 { storedFigures.maximumDeviationScaled }
    /// The nearest-rank percentile (1...100) that `percentileDeviationScaled` reports.
    var percentile: Int { storedPercentile }
    /// The nearest-rank percentile of the absolute deviations, scaled by `nominal.pulses`.
    var percentileDeviationScaled: Int128 { storedFigures.percentileDeviationScaled }
    var nominal: MIDIClockJitterNominal { storedNominal }

    private let storedFigures: Figures
    private let storedPercentile: Int
    private let storedNominal: MIDIClockJitterNominal

    private struct Figures: Equatable, Sendable {
        var intervalCount = 0
        var minimumInterval: UInt64 = 0
        var maximumInterval: UInt64 = 0
        var totalTicks: UInt64 = 0
        var maximumDeviationScaled: Int128 = 0
        var percentileDeviationScaled: Int128 = 0
    }

    private init(figures: Figures, percentile: Int, nominal: MIDIClockJitterNominal) {
        storedFigures = figures
        storedPercentile = percentile
        storedNominal = nominal
    }

    /// Refusals are checked in this order, each over the complete input: too many stamps, too few stamps, the
    /// percentile, then the first stamp lower than its predecessor. Equal consecutive stamps are valid.
    static func make(stamps: [HostStamp], nominal: MIDIClockJitterNominal,
                     percentile: Int) throws(MIDIClockJitterRefusal) -> Self {
        guard stamps.count <= maximumStamps else { throw .tooManyStamps(stamps.count) }
        guard stamps.count >= minimumStamps else { throw .tooFewStamps(stamps.count) }
        guard percentileRange.contains(percentile) else { throw .percentileOutOfRange(percentile) }
        for index in 1..<stamps.count where stamps[index].ticks < stamps[index - 1].ticks {
            throw .nonMonotonicStamps(index: index)
        }
        let intervals = zip(stamps, stamps.dropFirst()).map { $1.ticks - $0.ticks }
        var figures = Figures()
        figures.intervalCount = intervals.count
        figures.totalTicks = stamps[stamps.count - 1].ticks - stamps[0].ticks
        figures.minimumInterval = UInt64.max
        for interval in intervals {
            figures.minimumInterval = min(figures.minimumInterval, interval)
            figures.maximumInterval = max(figures.maximumInterval, interval)
        }
        let deviations = intervals.map { abs(Int128($0) * nominal.pulses - nominal.spanTicks) }.sorted()
        let rank = (percentile * deviations.count + 99) / 100
        figures.maximumDeviationScaled = deviations[deviations.count - 1]
        figures.percentileDeviationScaled = deviations[rank - 1]
        return Self(figures: figures, percentile: percentile, nominal: nominal)
    }

    /// Within tolerance when the largest deviation is at most `perMille` thousandths of the nominal interval;
    /// equality is within. The percentile plays no part: one interval outside the tolerance fails the window.
    func verdict(_ tolerance: MIDIClockJitterTolerance) -> MIDIClockJitterVerdict {
        let scaledDeviation = storedFigures.maximumDeviationScaled * 1_000
        let allowance = Int128(tolerance.perMille) * storedNominal.spanTicks
        return scaledDeviation <= allowance ? .withinTolerance : .exceeded
    }
}
