//
//  WorkspaceStatusShowReadiness.swift
//  FluxKlang
//
//  The show readiness verdict as one optional line beside the six status segments (#99, slice SRS1). The
//  input is three counts; the line is validated and worded here. It is not a segment: it is never announced
//  and never a focus stop. Integer-only: no floating point, no locale, no Foundation.
//

/// The readiness of the setlist about to start, as three counts. A plain carrier: the projection validates it.
struct WorkspaceStatusShowReadiness: Hashable, Sendable {
    /// Setlist entries.
    let entryCount: Int
    /// Entries with at least one blocker.
    let blockedEntryCount: Int
    /// Set-level blockers (an empty setlist, unresolved links). Unresolved links count once, not per link.
    let setBlockerCount: Int

    init(entryCount: Int, blockedEntryCount: Int, setBlockerCount: Int) {
        self.entryCount = entryCount
        self.blockedEntryCount = blockedEntryCount
        self.setBlockerCount = setBlockerCount
    }

    /// The one place a `ShowReadinessVerdict` is read for the strip.
    init(verdict: ShowReadinessVerdict) {
        entryCount = verdict.entries.count
        blockedEntryCount = verdict.entries.filter { !$0.isReady }.count
        setBlockerCount = verdict.setBlockers.count
    }
}

/// The validated show readiness line. Only `make(_:)` builds one.
struct WorkspaceStatusShowReadinessLine: Hashable, Sendable {
    /// "Show ready (5 entries)" or "Show not ready: 2 of 5 entries blocked".
    let text: String
    /// The full sentence: "Show readiness: " followed by `text`.
    let label: String
    /// `.normal` when nothing blocks the show, else `.attention`. `.error` is not used by this slice.
    let severity: WorkspaceStatusSeverity

    var glyphName: String { severity.glyphName }

    private init(text: String, label: String, severity: WorkspaceStatusSeverity) {
        self.text = text
        self.label = label
        self.severity = severity
    }

    /// Refuses, in this order: an entry count, a blocked count, a set blocker count outside
    /// `0...WorkspaceStatusInputs.maximumCount`; then more blocked entries than entries. Nothing is clamped.
    static func make(_ readiness: WorkspaceStatusShowReadiness) throws(WorkspaceStatusRefusal) -> Self {
        let entries = readiness.entryCount
        let blocked = readiness.blockedEntryCount
        let setBlockers = readiness.setBlockerCount
        try WorkspaceStatusInputs.validate(count: entries, field: .showReadinessEntries)
        try WorkspaceStatusInputs.validate(count: blocked, field: .showReadinessBlockedEntries)
        try WorkspaceStatusInputs.validate(count: setBlockers, field: .showReadinessSetBlockers)
        guard blocked <= entries else { throw .blockedEntriesExceedEntries(blocked: blocked, entries: entries) }
        let problems = problemWords(entries: entries, blocked: blocked, setBlockers: setBlockers)
        let text: String
        let severity: WorkspaceStatusSeverity
        if problems.isEmpty {
            text = "Show ready (\(entries) \(entries == 1 ? "entry" : "entries"))"
            severity = .normal
        } else {
            text = "Show not ready: " + problems.joined(separator: ", ")
            severity = .attention
        }
        return Self(text: text, label: "Show readiness: " + text, severity: severity)
    }

    /// The pieces of "not ready", in the fixed order: no entries, blocked entries, set blockers.
    private static func problemWords(entries: Int, blocked: Int, setBlockers: Int) -> [String] {
        var words: [String] = []
        if entries == 0 { words.append("no entries") }
        if blocked > 0 { words.append("\(blocked) of \(entries) \(entries == 1 ? "entry" : "entries") blocked") }
        if setBlockers > 0 { words.append("\(setBlockers) setlist \(setBlockers == 1 ? "blocker" : "blockers")") }
        return words
    }
}
