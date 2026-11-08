//
//  MIDIClockJitterWatch.swift
//  FluxKlang
//
//  What the leader arbiter needs to report each source's arrival jitter: the expected pulse interval, the tolerance a
//  window is judged against, the percentile the summary carries and how many stamps a source's window holds. The
//  watch is report only: it changes no decision of the arbiter.
//

/// A validated jitter-reporting setup, built only by `make`. One watch applies to every source of an arbiter.
struct MIDIClockJitterWatch: Equatable, Sendable {
    /// The window sizes a watch accepts: the summary's own minimum and maximum.
    static let windowStampsRange = MIDIClockJitterSummary.minimumStamps...MIDIClockJitterSummary.maximumStamps

    var nominal: MIDIClockJitterNominal { storedNominal }
    var tolerance: MIDIClockJitterTolerance { storedTolerance }
    /// The nearest-rank percentile (1...100) carried in each report's summary; it plays no part in the verdict.
    var percentile: Int { storedPercentile }
    /// The most stamps one source's window holds.
    var windowStamps: Int { storedWindowStamps }

    private let storedNominal: MIDIClockJitterNominal
    private let storedTolerance: MIDIClockJitterTolerance
    private let storedPercentile: Int
    private let storedWindowStamps: Int

    private init(nominal: MIDIClockJitterNominal, tolerance: MIDIClockJitterTolerance, percentile: Int,
                 windowStamps: Int) {
        storedNominal = nominal
        storedTolerance = tolerance
        storedPercentile = percentile
        storedWindowStamps = windowStamps
    }

    /// Refusals are checked in the summary's order: too many stamps, too few stamps, then the percentile.
    static func make(nominal: MIDIClockJitterNominal, tolerance: MIDIClockJitterTolerance, percentile: Int,
                     windowStamps: Int) throws(MIDIClockJitterRefusal) -> Self {
        guard windowStamps <= MIDIClockJitterSummary.maximumStamps else { throw .tooManyStamps(windowStamps) }
        guard windowStamps >= MIDIClockJitterSummary.minimumStamps else { throw .tooFewStamps(windowStamps) }
        guard MIDIClockJitterSummary.percentileRange.contains(percentile) else {
            throw .percentileOutOfRange(percentile)
        }
        return Self(nominal: nominal, tolerance: tolerance, percentile: percentile, windowStamps: windowStamps)
    }
}
