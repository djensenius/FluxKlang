//
//  LibraryRigCounts.swift
//  FluxKlang
//
//  How many of a rig's saved devices (required or not) fall in each matcher outcome (#99 LIB3). Every outcome is
//  counted exactly once, so `total` is the rig's device count. Pure values. Nothing calls it yet.
//

struct LibraryRigCounts: Hashable, Sendable {
    let matched: Int
    let renumbered: Int
    let ambiguous: Int
    /// Devices never observed, plus devices whose UID is only on a descriptor with `missing` presence.
    let missing: Int
    /// Devices whose UID is only on descriptors with `stale` presence (and none with `missing`).
    let stale: Int

    var total: Int { matched + renumbered + ambiguous + missing + stale }

    init(rows: [RigDeviceMatch]) {
        var matched = 0
        var renumbered = 0
        var ambiguous = 0
        var missing = 0
        var stale = 0
        for row in rows {
            switch row.outcome {
            case .matched: matched += 1
            case .renumbered: renumbered += 1
            case .ambiguous: ambiguous += 1
            case .missing, .absentPresence(.missing): missing += 1
            case .absentPresence(.stale): stale += 1
            }
        }
        self.matched = matched
        self.renumbered = renumbered
        self.ambiguous = ambiguous
        self.missing = missing
        self.stale = stale
    }
}
