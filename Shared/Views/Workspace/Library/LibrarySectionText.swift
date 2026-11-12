//
//  LibrarySectionText.swift
//  FluxKlang
//
//  The fixed strings of the Library section view (#99 WSV1; library-inspector.md "Library" mock) that the row models
//  do not own: headings, the search field's texts, the empty lines and the patch-list refusal line. English only;
//  none of it is localised yet.
//

enum LibrarySectionText {
    static let library = "Library"
    static let pluginsHeading = "Plugins"
    static let patchesHeading = "Patches & Variations"
    /// The search field's placeholder.
    static let searchPrompt = "Search"
    /// The search field's accessibility label.
    static let searchLabel = "Search the Library"
    static let noPatches = "No patches yet"
    static let noMatches = "Nothing matches the search"

    /// One line for a patch list that could not be built; it names the repeated patch id.
    static func patchesUnavailable(_ refusal: LibraryPatchListRefusal) -> String {
        switch refusal {
        case .duplicatePatch(let id):
            "Patches unavailable: the patch id \(id.rawValue) appears more than once."
        }
    }
}
