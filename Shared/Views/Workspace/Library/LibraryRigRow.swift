//
//  LibraryRigRow.swift
//  FluxKlang
//
//  One row of the Library "Rigs" section (#99 LIB3; library-inspector.md "Library"): the rig's stored name, a kind,
//  a status word and the counts of its saved devices. Built only by `LibraryRigList.make`; storage is `let`. The
//  row has no actions. Nothing calls it yet.
//

/// One saved rig as the list shows it.
struct LibraryRigRow: Hashable, Sendable, Identifiable {
    let id: RigProfileID
    /// The stored name exactly as stored: never trimmed, folded or normalised.
    let title: String
    let kindText: String
    let status: LibraryRigStatus
    let statusText: String
    let counts: LibraryRigCounts
    let detailText: String
    /// True exactly when the library's selection is this rig; never inferred from the devices or the mode.
    let isSelected: Bool
    let selectedText: String?
    let accessibilityLabel: String

    init(entry: RigLibraryEntry, report: RigMatchReport, isSelected: Bool) {
        let title = entry.name.text
        let status = LibraryRigStatus(mode: report.mode)
        let counts = LibraryRigCounts(rows: report.rows)
        let detail = LibraryRigText.detail(counts)
        id = entry.id
        self.title = title
        kindText = LibraryRigText.kind
        self.status = status
        statusText = LibraryRigText.status(status)
        self.counts = counts
        detailText = detail
        self.isSelected = isSelected
        selectedText = isSelected ? LibraryRigText.selected : nil
        accessibilityLabel = LibraryRigText.accessibilityLabel(
            title: title, status: status, detail: detail, isSelected: isSelected
        )
    }

    /// Whether every term (already lowercased) is a substring of the lowercased title, kind, status, detail or
    /// selected text. Never an id, device id, UID or role.
    func matches(terms: [String]) -> Bool {
        let fields = [title, kindText, statusText, detailText, selectedText ?? ""].map { $0.lowercased() }
        return terms.allSatisfy { term in fields.contains { $0.contains(term) } }
    }
}
