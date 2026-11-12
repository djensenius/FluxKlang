//
//  LibraryVariationRow.swift
//  FluxKlang
//
//  One variation under a Library patch row (#99 LIB2; library-inspector.md "Library" mock): its stored label, a delta
//  count and whether the caller has it prepared. Built only by `LibraryPatchRow`; storage is `let`. Nothing calls it
//  yet.
//

/// A variation id is unique only within its patch, so a row is identified by both.
struct LibraryVariationID: Hashable, Sendable {
    let patch: PatchID
    let variation: PatchVariationID
}

struct LibraryVariationRow: Hashable, Sendable, Identifiable {
    let id: LibraryVariationID
    /// The stored label, exactly.
    let title: String
    let kindText: String
    let deltaCount: Int
    let isPrepared: Bool
    let detailText: String
    let actions: [LibraryPatchAction]
    let accessibilityLabel: String

    init(patch: PatchID, variation: PatchVariation, isPrepared: Bool) {
        let detail = LibraryPatchText.deltaCount(variation.deltas.count, isPrepared: isPrepared)
        id = LibraryVariationID(patch: patch, variation: variation.id)
        title = variation.label
        kindText = LibraryPatchText.variationKind
        deltaCount = variation.deltas.count
        self.isPrepared = isPrepared
        detailText = detail
        actions = [.recall]
        accessibilityLabel = LibraryPatchText.accessibilityLabel(
            title: variation.label, kindText: LibraryPatchText.variationKind, detailText: detail
        )
    }

    /// Lowercased title, kind text and detail text; never an id.
    var searchFields: [String] { [title, kindText, detailText].map { $0.lowercased() } }

    /// Whether every term (already lowercased) is a substring of a field of this row or of its patch row.
    func matches(terms: [String], patchFields: [String]) -> Bool {
        let fields = searchFields + patchFields
        return terms.allSatisfy { term in fields.contains { $0.contains(term) } }
    }
}
