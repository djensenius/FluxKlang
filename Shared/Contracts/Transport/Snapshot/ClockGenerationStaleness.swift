//
//  ClockGenerationStaleness.swift
//  FluxKlang
//
//  Which of the three clock generations of an observed snapshot differ from the
//  live ones (#108 GU1, slice a). Every differing axis is reported, and
//  `firstStale` names the first in the fixed order sample, transport, musical
//  map: the order `MetronomeGrid.validate`, `MIDIClipPlacement.validate` and
//  the automation renderer check a clock map in. Equality only (M2): an
//  observed generation LOWER than the live one is stale, like a higher one.
//

/// One of the three clock generations of a snapshot.
enum ClockGenerationAxis: Hashable, Sendable {
    case sample
    case transport
    case musicalMap
}

/// The axes on which an observed snapshot differs from the live one; true means that axis differs. At least one is
/// true: a report is made only by `ClockGenerationSnapshot.staleness(of:against:)`, which gives nil for equal ones.
struct ClockGenerationStaleness: Hashable, Sendable {
    let sample: Bool
    let transport: Bool
    let musicalMap: Bool

    fileprivate init?(sample: Bool, transport: Bool, musicalMap: Bool) {
        guard sample || transport || musicalMap else { return nil }
        self.sample = sample
        self.transport = transport
        self.musicalMap = musicalMap
    }

    /// The first differing axis in the order sample, transport, musical map.
    var firstStale: ClockGenerationAxis {
        if sample { return .sample }
        if transport { return .transport }
        return .musicalMap
    }
}

extension ClockGenerationSnapshot {
    /// The axes on which `observed` differs from `live`, or nil when all three generations are equal.
    static func staleness(of observed: ClockGenerationSnapshot,
                          against live: ClockGenerationSnapshot) -> ClockGenerationStaleness? {
        ClockGenerationStaleness(
            sample: observed.sample != live.sample,
            transport: observed.transport != live.transport,
            musicalMap: observed.musicalMap != live.musicalMap
        )
    }
}
