//
//  LibraryPatchRow.swift
//  FluxKlang
//
//  One patch of the Library "Patches & Variations" section (#99 LIB2; library-inspector.md "Library" mock): its
//  stored label, a status, a variation count and the variations nested under it, in their stored order (the user's
//  order is the data). Variations are read only through `PatchVariationExtension.content(of:)`; a newer or unreadable
//  set lists none and is never looked into. Built only by `LibraryPatchList.make`; storage is `let`. Nothing calls it
//  yet.
//

struct LibraryPatchRow: Hashable, Sendable, Identifiable {
    let id: PatchID
    /// The stored label exactly, or `Unnamed patch` when it has no non-whitespace character.
    let title: String
    let kindText: String
    let status: LibraryPatchStatus
    /// The count of ALL stored variations (a filtered row keeps it), or the status's reason.
    let detailText: String
    let variations: [LibraryVariationRow]
    let actions: [LibraryPatchAction]
    let accessibilityLabel: String

    init(patch: ProjectPatch, prepared: Set<LibraryVariationID>) {
        let status: LibraryPatchStatus
        let listed: [LibraryVariationRow]
        do {
            switch try PatchVariationExtension.content(of: patch) {
            case .absent:
                status = .ready
                listed = []
            case .current(let set):
                status = .ready
                listed = set.variations.map { variation in
                    let id = LibraryVariationID(patch: patch.id, variation: variation.id)
                    return LibraryVariationRow(
                        patch: patch.id, variation: variation, isPrepared: prepared.contains(id)
                    )
                }
            case .future(let version):
                status = .newerVersion(version)
                listed = []
            }
        } catch {
            status = .unreadable(error)
            listed = []
        }
        let title = patch.label.contains { !$0.isWhitespace } ? patch.label : LibraryPatchText.unnamedPatchTitle
        let detail = status.reasonText ?? LibraryPatchText.variationCount(listed.count)
        self.init(
            id: patch.id, title: title, status: status, detailText: detail, variations: listed
        )
    }

    private init(id: PatchID, title: String, status: LibraryPatchStatus, detailText: String,
                 variations: [LibraryVariationRow]) {
        self.id = id
        self.title = title
        kindText = LibraryPatchText.patchKind
        self.status = status
        self.detailText = detailText
        self.variations = variations
        actions = LibraryPatchAction.actions(for: status)
        accessibilityLabel = LibraryPatchText.accessibilityLabel(
            title: title, kindText: LibraryPatchText.patchKind, detailText: detailText
        )
    }

    /// Lowercased title, kind text and detail text; never an id.
    var searchFields: [String] { [title, kindText, detailText].map { $0.lowercased() } }

    /// This row if it matches, or any of its variations does, keeping exactly the variations that match (all of them
    /// when the row itself matches); nil otherwise. The detail text is unchanged.
    func keeping(terms: [String]) -> Self? {
        let fields = searchFields
        let rowMatches = terms.allSatisfy { term in fields.contains { $0.contains(term) } }
        let kept = rowMatches
            ? variations : variations.filter { $0.matches(terms: terms, patchFields: fields) }
        guard rowMatches || !kept.isEmpty else { return nil }
        return Self(id: id, title: title, status: status, detailText: detailText, variations: kept)
    }
}
