//
//  ShowReadinessVerdict.swift
//  FluxKlang
//
//  Whether one setlist is ready to start (#103): one entry per setlist entry with what blocks it, and blockers of the
//  setlist as a whole. Blockers are data, not text. The initializers are file private and `evaluate` is the code in
//  this file that calls them, so a verdict comes from facts that passed the refusal checks.
//

/// What stops one setlist entry from being ready. Action-set blockers come before chart blockers.
enum ShowReadinessBlocker: Equatable, Sendable {
    /// The facts hold no report for this action set.
    case actionSetUnreported(ActionSetID)
    /// The set's report names a state other than ready.
    case actionSetNotReady(ActionSetID, ReadinessState)
    /// The report says ready while one of its members is not ready.
    case actionSetReportInconsistent(ActionSetID)
    /// A chart reference at this address is on the worklist.
    case chartMissing(ShowRecoveryTarget)
    /// The library cannot resolve the entry's song.
    case songNotInLibrary(SongID)
}

/// What stops the setlist as a whole. `emptySetlist` comes before `unresolvedLinks`.
enum ShowReadinessSetBlocker: Equatable, Sendable {
    case emptySetlist
    /// Broken patch, variation and action-set links of the library; they cannot be attributed to an entry.
    case unresolvedLinks(count: Int)
}

struct ShowReadinessEntry: Equatable, Sendable {
    private let storedEntry: SetlistEntryID
    private let storedSong: SongID
    private let storedBlockers: [ShowReadinessBlocker]

    var entry: SetlistEntryID { storedEntry }
    var song: SongID { storedSong }
    /// Action-set blockers in part order, then chart blockers: the song's own chart, then the parts' charts.
    var blockers: [ShowReadinessBlocker] { storedBlockers }
    var isReady: Bool { storedBlockers.isEmpty }

    fileprivate init(entry: SetlistEntryID, song: SongID, blockers: [ShowReadinessBlocker]) {
        storedEntry = entry
        storedSong = song
        storedBlockers = blockers
    }
}

struct ShowReadinessVerdict: Equatable, Sendable {
    private let storedSetlist: SetlistID
    private let storedEntries: [ShowReadinessEntry]
    private let storedSetBlockers: [ShowReadinessSetBlocker]

    var setlist: SetlistID { storedSetlist }
    /// One per setlist entry, in setlist order; a song that appears twice is evaluated twice.
    var entries: [ShowReadinessEntry] { storedEntries }
    var setBlockers: [ShowReadinessSetBlocker] { storedSetBlockers }
    /// No set blocker and no entry blocker. An empty setlist is not ready.
    var isReadyToStart: Bool { storedSetBlockers.isEmpty && storedEntries.allSatisfy { $0.isReady } }

    fileprivate init(setlist: SetlistID, entries: [ShowReadinessEntry], setBlockers: [ShowReadinessSetBlocker]) {
        storedSetlist = setlist
        storedEntries = entries
        storedSetBlockers = setBlockers
    }
}

extension ShowReadinessEvaluator {
    /// Refuses, in this order: more than `maximumReports` reports, an unknown setlist, a repeated report.
    static func evaluate(_ facts: ShowReadinessFacts) throws(ShowReadinessRefusal) -> ShowReadinessVerdict {
        guard facts.reports.count <= maximumReports else { throw .tooManyReports(facts.reports.count) }
        guard let setlist = facts.library.setlist(facts.setlist) else { throw .unknownSetlist(facts.setlist) }
        let reports = try reportsBySet(facts.reports)
        let missing = Set(facts.worklist.groups.flatMap { $0.items.map(\.target) })
        let entries = setlist.entries.map { entry -> ShowReadinessEntry in
            let found = blockers(for: entry.song, in: facts.library, reports: reports, missing: missing)
            return ShowReadinessEntry(entry: entry.id, song: entry.song, blockers: found)
        }
        return ShowReadinessVerdict(setlist: setlist.id, entries: entries,
                                    setBlockers: setBlockers(entryCount: entries.count, worklist: facts.worklist))
    }

    private static func reportsBySet(
        _ reports: [ActionSetReadinessReport]
    ) throws(ShowReadinessRefusal) -> [ActionSetID: ActionSetReadinessReport] {
        var bySet: [ActionSetID: ActionSetReadinessReport] = [:]
        for report in reports {
            let earlier = bySet.updateValue(report, forKey: report.set)
            if earlier != nil { throw .duplicateReport(report.set) }
        }
        return bySet
    }

    private static func setBlockers(entryCount: Int, worklist: ShowRecoveryWorklist) -> [ShowReadinessSetBlocker] {
        var blockers: [ShowReadinessSetBlocker] = []
        if entryCount == 0 { blockers.append(.emptySetlist) }
        if worklist.nonChartProblemCount > 0 {
            blockers.append(.unresolvedLinks(count: worklist.nonChartProblemCount))
        }
        return blockers
    }

    private static func blockers(for songID: SongID, in library: ShowLibrary,
                                 reports: [ActionSetID: ActionSetReadinessReport],
                                 missing: Set<ShowRecoveryTarget>) -> [ShowReadinessBlocker] {
        guard let song = library.song(songID) else { return [.songNotInLibrary(songID)] }
        return actionSetBlockers(of: song, reports: reports) + chartBlockers(of: song, missing: missing)
    }

    private static func actionSetBlockers(of song: ShowSong,
                                          reports: [ActionSetID: ActionSetReadinessReport]) -> [ShowReadinessBlocker] {
        var seen = Set<ActionSetID>()
        var blockers: [ShowReadinessBlocker] = []
        for part in song.parts {
            guard let set = part.links.actionSet, seen.insert(set).inserted else { continue }
            if let blocker = blocker(for: set, reports: reports) { blockers.append(blocker) }
        }
        return blockers
    }

    private static func blocker(for set: ActionSetID,
                                reports: [ActionSetID: ActionSetReadinessReport]) -> ShowReadinessBlocker? {
        guard let report = reports[set] else { return .actionSetUnreported(set) }
        guard report.state == .ready else { return .actionSetNotReady(set, report.state) }
        return report.notReady.isEmpty ? nil : .actionSetReportInconsistent(set)
    }

    private static func chartBlockers(of song: ShowSong, missing: Set<ShowRecoveryTarget>) -> [ShowReadinessBlocker] {
        var slots: [ShowRecoveryTarget] = []
        if song.chart != nil { slots.append(ShowRecoveryTarget(song: song.id, part: nil)) }
        for part in song.parts where part.links.chart != nil {
            slots.append(ShowRecoveryTarget(song: song.id, part: part.id))
        }
        return slots.filter { missing.contains($0) }.map { .chartMissing($0) }
    }
}
