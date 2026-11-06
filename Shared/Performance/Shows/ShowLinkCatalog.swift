//
//  ShowLinkCatalog.swift
//  FluxKlang
//
//  What a show's links may point at, supplied by the caller from the project:
//  patches and their variations (#104), action sets (#107) and assets with
//  available content (#122). Edits refuse links that do not resolve here; a
//  loaded show reports them, keeps them and can be relinked (#106 SH1).
//

struct ShowLinkCatalog: Sendable {
    /// Lookup only; never iterated, so no hash order is observable.
    private let variationsByPatch: [PatchID: Set<PatchVariationID>]
    private let actionSets: Set<ActionSetID>
    private let assetMedia: [AssetID: AssetMedia]
    private let availableContent: Set<AssetID>

    static func make(patches: [(PatchID, [PatchVariationID])] = [], actionSets: PerformanceActionSetLibrary? = nil,
                     assets: [ProjectAsset] = [], availableContent: [AssetID] = []) throws(ShowRefusal)
        -> ShowLinkCatalog {
        let limit = ShowLimits.maximumCatalogAssets
        guard patches.count <= ShowLimits.maximumCatalogPatches else { throw .catalogTooLarge(.patches, patches.count) }
        guard assets.count <= limit else { throw .catalogTooLarge(.assets, assets.count) }
        guard availableContent.count <= limit else { throw .catalogTooLarge(.availableContent, availableContent.count) }
        var variationsByPatch: [PatchID: Set<PatchVariationID>] = [:]
        for (patch, variations) in patches {
            guard variations.count <= PatchVariationLimits.maximumVariations else {
                throw .catalogTooLarge(.variationsPerPatch(patch), variations.count)
            }
            var seen = Set<PatchVariationID>()
            for variation in variations where !seen.insert(variation).inserted {
                throw .duplicateVariation(patch, variation)
            }
            guard variationsByPatch.updateValue(seen, forKey: patch) == nil else { throw .duplicatePatch(patch) }
        }
        var assetMedia: [AssetID: AssetMedia] = [:]
        for asset in assets where assetMedia.updateValue(asset.media, forKey: asset.id) != nil {
            throw .duplicateAsset(asset.id)
        }
        return ShowLinkCatalog(variationsByPatch: variationsByPatch,
                               actionSets: Set(actionSets?.sets.map(\.id) ?? []),
                               assetMedia: assetMedia, availableContent: Set(availableContent))
    }

    func availability(of chart: ChartReference) -> ChartAvailability {
        guard let media = assetMedia[chart.asset] else { return .missing(chart, .notInProject) }
        guard media == .document else { return .missing(chart, .notDocument(media)) }
        guard availableContent.contains(chart.asset) else { return .missing(chart, .contentUnavailable) }
        return .available(chart)
    }

    /// In fixed order: patch, variation, action set, chart. An unknown patch hides its variation.
    func problems(_ links: SongPartLinks) -> [ShowLinkProblem] {
        var problems: [ShowLinkProblem] = []
        if let patch = links.patch {
            if let variations = variationsByPatch[patch] {
                if let variation = links.variation, !variations.contains(variation) {
                    problems.append(.unknownVariation(patch, variation))
                }
            } else {
                problems.append(.unknownPatch(patch))
            }
        }
        if let actionSet = links.actionSet, !actionSets.contains(actionSet) {
            problems.append(.unknownActionSet(actionSet))
        }
        if let chart = links.chart, case let .missing(_, reason) = availability(of: chart) {
            problems.append(.chart(chart, reason))
        }
        return problems
    }

    /// Edit-time check, field by field against `previous` (the stored links; `nil` for a new part): every
    /// reference the edit adds or changes must resolve, in the order patch, variation, action set, chart. An
    /// unchanged loaded broken reference is kept. A variation is changed when it or its patch changes, and one
    /// under a missing patch cannot resolve. Unlike `problems`, nothing is collapsed here.
    func check(_ links: SongPartLinks, replacing previous: SongPartLinks? = nil) throws(ShowRefusal) {
        if let patch = links.patch {
            let patchChanged = patch != previous?.patch
            let variations = variationsByPatch[patch]
            if patchChanged, variations == nil { throw .unknownPatch(patch) }
            if let variation = links.variation, patchChanged || variation != previous?.variation,
               variations?.contains(variation) != true {
                throw .unknownVariation(patch, variation)
            }
        }
        if let actionSet = links.actionSet, actionSet != previous?.actionSet, !actionSets.contains(actionSet) {
            throw .unknownActionSet(actionSet)
        }
        if let chart = links.chart, chart != previous?.chart { try checkChart(chart) }
    }

    /// Refuses a chart reference that is not available.
    func checkChart(_ chart: ChartReference) throws(ShowRefusal) {
        if case let .missing(_, reason) = availability(of: chart) { throw .chartUnavailable(chart, reason) }
    }
}

enum ShowLinkProblem: Hashable, Sendable {
    case unknownPatch(PatchID)
    case unknownVariation(PatchID, PatchVariationID)
    case unknownActionSet(ActionSetID)
    case chart(ChartReference, ChartMissingReason)
}

/// One reported problem; `part == nil` means the song's own chart.
struct ShowLinkIssue: Hashable, Sendable {
    let song: SongID
    let part: SongPartID?
    let problem: ShowLinkProblem
}

/// A navigation target's effective links: the part's links with its chart falling back to the song's.
/// Built only by `ShowLibrary.resolvedLinks(song:part:in:)`.
struct ShowResolvedLinks: Hashable, Sendable {
    private let storedLinks: SongPartLinks
    private let storedChart: ChartAvailability?
    private let storedProblems: [ShowLinkProblem]

    var links: SongPartLinks { storedLinks }
    var chart: ChartAvailability? { storedChart }
    /// Reported, never dropped: `links` still holds every reference.
    var problems: [ShowLinkProblem] { storedProblems }

    fileprivate init(links: SongPartLinks, chart: ChartAvailability?, problems: [ShowLinkProblem]) {
        storedLinks = links
        storedChart = chart
        storedProblems = problems
    }
}

extension ShowSong {
    /// This song's problems in document order: its own chart, then its parts in order.
    func linkIssues(in catalog: ShowLinkCatalog) -> [ShowLinkIssue] {
        var issues: [ShowLinkIssue] = []
        if let chart, case let .missing(_, reason) = catalog.availability(of: chart) {
            issues.append(ShowLinkIssue(song: id, part: nil, problem: .chart(chart, reason)))
        }
        for part in parts {
            issues += catalog.problems(part.links).map { ShowLinkIssue(song: id, part: part.id, problem: $0) }
        }
        return issues
    }
}

extension ShowLibrary {
    /// Load-time report in document order: songs, then each song's chart and its parts in order.
    func linkReport(in catalog: ShowLinkCatalog) -> [ShowLinkIssue] {
        songs.flatMap { $0.linkIssues(in: catalog) }
    }

    /// The part's chart overrides the song's. `part` is looked up in `song`, so a part ID from another song (or
    /// one that no longer exists) is refused with `unknownPart` rather than paired with the wrong song.
    static func resolvedLinks(song: ShowSong, part id: SongPartID?,
                              in catalog: ShowLinkCatalog) throws(ShowRefusal) -> ShowResolvedLinks {
        var own = SongPartLinks.none
        if let id {
            guard let part = song.part(id) else { throw .unknownPart(id) }
            own = part.links
        }
        let links = own.replacingChart(own.chart ?? song.chart)
        return ShowResolvedLinks(links: links, chart: links.chart.map(catalog.availability(of:)),
                                 problems: catalog.problems(links))
    }
}
