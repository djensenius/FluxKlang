import SwiftUI

/// The Library's Plugins and Patches & Variations sections (#99 WSV1; library-inspector.md "Library"), drawn from
/// `LibraryPluginList` and `LibraryPatchList` with a search field. The app has no incompatibility judgment and no
/// prepared-variation set, so the lists are built with their defaults. Nothing here is invented: with no scanner the
/// plug-in section shows the never-scanned row, and a project with no patches shows none.
struct LibrarySectionView: View {
    let patches: [ProjectPatch]
    let catalog: PluginCatalog
    @State private var query = ""

    private var isSearching: Bool { query.contains { !$0.isWhitespace } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(LibrarySectionText.library).font(.headline).accessibilityAddTraits(.isHeader)
            TextField(LibrarySectionText.searchPrompt, text: $query)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .accessibilityLabel(LibrarySectionText.searchLabel)
            plugins
            patchSection
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Plugins

    @ViewBuilder private var plugins: some View {
        let list = LibraryPluginList.make(catalog: catalog).filtered(by: query)
        heading(LibrarySectionText.pluginsHeading)
        ForEach(list.rows) { row in LibraryPluginRowView(row: row) }
        if let scanRow = list.scanRow { LibraryPluginRowView(scanRow: scanRow) }
        if isSearching, list.rows.isEmpty, list.scanRow == nil { line(LibrarySectionText.noMatches) }
    }

    // MARK: Patches

    @ViewBuilder private var patchSection: some View {
        heading(LibrarySectionText.patchesHeading)
        switch patchList() {
        case .success(let list):
            let shown = list.filtered(by: query)
            ForEach(shown.rows) { row in LibraryPatchRowView(row: row) }
            if shown.rows.isEmpty {
                line(isSearching && !list.rows.isEmpty ? LibrarySectionText.noMatches : LibrarySectionText.noPatches)
            }
        case .failure(let refusal):
            line(LibrarySectionText.patchesUnavailable(refusal))
        }
    }

    private func patchList() -> Result<LibraryPatchList, LibraryPatchListRefusal> {
        do { return .success(try LibraryPatchList.make(patches: patches)) } catch { return .failure(error) }
    }

    private func heading(_ text: String) -> some View {
        Text(text).font(.subheadline.bold()).accessibilityAddTraits(.isHeader)
    }

    private func line(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
    }
}
