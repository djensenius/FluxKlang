//
//  MIDIClockSourceJitter.swift
//  FluxKlang
//
//  One source's arrival jitter as the arbiter's status reports it. Built when the status is read, never per message.
//

/// The jitter of one source's last clock stamps, judged by the summary's maximum-deviation verdict.
enum MIDIClockSourceJitter: Equatable, Sendable {
    /// Fewer than two stamps are held, so no interval exists yet.
    case collecting(stamps: Int)
    case measured(MIDIClockJitterSummary, MIDIClockJitterVerdict)
    /// The summary refused the window. Not exercised: window sizes are 2...1024, the percentile is validated and equal
    /// or increasing stamps are accepted, so no input reaches it; it exists so no failure is swallowed.
    case refused(MIDIClockJitterRefusal)

    static func report(window: MIDIClockStampWindow, watch: MIDIClockJitterWatch) -> Self {
        let stamps = window.stamps
        guard stamps.count >= MIDIClockJitterSummary.minimumStamps else { return .collecting(stamps: stamps.count) }
        do throws(MIDIClockJitterRefusal) {
            let summary = try MIDIClockJitterSummary.make(stamps: stamps, nominal: watch.nominal,
                                                          percentile: watch.percentile)
            return .measured(summary, summary.verdict(watch.tolerance))
        } catch {
            return .refused(error)
        }
    }
}
