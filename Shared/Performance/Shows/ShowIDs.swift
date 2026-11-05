//
//  ShowIDs.swift
//  FluxKlang
//
//  Stable identities and bounds for songs, parts and setlists (#106 SH1).
//  Every reference in a show is one of these IDs, never an index.
//

enum SongTag: ContractIDTag {}
typealias SongID = ContractID<SongTag>
enum SongPartTag: ContractIDTag {}
typealias SongPartID = ContractID<SongPartTag>
enum SetlistTag: ContractIDTag {}
typealias SetlistID = ContractID<SetlistTag>
/// One appearance of a song in a setlist; the same song may appear in several entries.
enum SetlistEntryTag: ContractIDTag {}
typealias SetlistEntryID = ContractID<SetlistEntryTag>
/// One stream of navigation presses (a foot controller, the onscreen buttons); each keeps its own sequence.
enum ShowInputSourceTag: ContractIDTag {}
typealias ShowInputSourceID = ContractID<ShowInputSourceTag>

enum ShowLimits {
    static let maximumSongs = 512
    static let maximumPartsPerSong = 64
    static let maximumSetlists = 64
    static let maximumEntriesPerSetlist = 256
    static let maximumChartPage = 9_999
    /// 10,000 bars of 4/4.
    static let maximumMarkTicks: Int64 = 10_000 * 4 * MusicalTime.ticksPerQuarter
    static let maximumCatalogPatches = 4_096
    static let maximumCatalogAssets = 4_096
    /// Caller ticks; 10 s if the caller counts nanoseconds. Zero disables the bounce window.
    static let maximumBounceTicks: UInt64 = 10_000_000_000
    static let maximumInputSources = 8

    /// The #104 label rule: 1…256 UTF-8 bytes, trimmed, no control or separator scalars.
    static func isValidTitle(_ title: String) -> Bool { PatchVariationLimits.isValidLabel(title) }
}

/// Order-preserving edits of ID-addressed arrays. `before: nil` means the end. Unknown IDs are refused through
/// `unknown`, and a refused edit returns nothing, so the caller's value is unchanged.
enum ShowOrdering {
    static func firstDuplicate<Element: Identifiable>(in elements: [Element]) -> Element.ID? {
        var seen = Set<Element.ID>()
        return elements.first { !seen.insert($0.id).inserted }?.id
    }

    static func inserting<Element: Identifiable>(
        _ element: Element, before anchor: Element.ID?, in elements: [Element],
        unknown: (Element.ID) -> ShowRefusal
    ) throws(ShowRefusal) -> [Element] {
        var result = elements
        guard let anchor else {
            result.append(element)
            return result
        }
        guard let position = elements.firstIndex(where: { $0.id == anchor }) else { throw unknown(anchor) }
        result.insert(element, at: position)
        return result
    }

    static func moving<Element: Identifiable>(
        _ id: Element.ID, before anchor: Element.ID?, in elements: [Element],
        unknown: (Element.ID) -> ShowRefusal
    ) throws(ShowRefusal) -> [Element] {
        guard let source = elements.firstIndex(where: { $0.id == id }) else { throw unknown(id) }
        if let anchor, !elements.contains(where: { $0.id == anchor }) { throw unknown(anchor) }
        guard anchor != id else { return elements }
        var result = elements
        let element = result.remove(at: source)
        return try inserting(element, before: anchor, in: result, unknown: unknown)
    }

    static func removing<Element: Identifiable>(
        _ id: Element.ID, from elements: [Element], unknown: (Element.ID) -> ShowRefusal
    ) throws(ShowRefusal) -> [Element] {
        guard let position = elements.firstIndex(where: { $0.id == id }) else { throw unknown(id) }
        var result = elements
        result.remove(at: position)
        return result
    }
}
