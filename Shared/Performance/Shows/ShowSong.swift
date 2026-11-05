//
//  ShowSong.swift
//  FluxKlang
//
//  Songs and their ordered parts (#106 SH1). Each part may carry a rehearsal
//  mark and links to a patch variation (#104), an action set (#107) and a chart.
//  Values are built only through throwing factories; every edit returns a new
//  validated value or throws and leaves the original unchanged.
//

/// A song-relative musical position in `MusicalTime.ticksPerQuarter` ticks. Projection to frames is later work.
struct RehearsalMark: Hashable, Sendable {
    private let storedTicks: Int64
    private let storedLabel: String?

    var ticks: Int64 { storedTicks }
    var label: String? { storedLabel }

    private init(ticks: Int64, label: String?) {
        storedTicks = ticks
        storedLabel = label
    }

    static func make(ticks: Int64, label: String? = nil) throws(ShowRefusal) -> RehearsalMark {
        guard (0...ShowLimits.maximumMarkTicks).contains(ticks) else { throw .markOutOfRange(ticks) }
        if let label, !ShowLimits.isValidTitle(label) { throw .invalidTitle }
        return RehearsalMark(ticks: ticks, label: label)
    }
}

/// What a part links to. Links are references only: nothing here recalls or fires.
struct SongPartLinks: Hashable, Sendable {
    static let none = SongPartLinks(patch: nil, variation: nil, actionSet: nil, chart: nil)

    private let storedPatch: PatchID?
    private let storedVariation: PatchVariationID?
    private let storedActionSet: ActionSetID?
    private let storedChart: ChartReference?

    var patch: PatchID? { storedPatch }
    var variation: PatchVariationID? { storedVariation }
    var actionSet: ActionSetID? { storedActionSet }
    var chart: ChartReference? { storedChart }

    private init(patch: PatchID?, variation: PatchVariationID?, actionSet: ActionSetID?, chart: ChartReference?) {
        storedPatch = patch
        storedVariation = variation
        storedActionSet = actionSet
        storedChart = chart
    }

    static func make(patch: PatchID? = nil, variation: PatchVariationID? = nil, actionSet: ActionSetID? = nil,
                     chart: ChartReference? = nil) throws(ShowRefusal) -> SongPartLinks {
        if let variation, patch == nil { throw .variationWithoutPatch(variation) }
        return SongPartLinks(patch: patch, variation: variation, actionSet: actionSet, chart: chart)
    }

    func replacingChart(_ chart: ChartReference?) -> SongPartLinks {
        SongPartLinks(patch: patch, variation: variation, actionSet: actionSet, chart: chart)
    }
}

struct SongPart: Hashable, Sendable, Identifiable {
    private let storedID: SongPartID
    private let storedTitle: String
    private let storedMark: RehearsalMark?
    private let storedLinks: SongPartLinks

    var id: SongPartID { storedID }
    var title: String { storedTitle }
    var mark: RehearsalMark? { storedMark }
    var links: SongPartLinks { storedLinks }

    private init(id: SongPartID, title: String, mark: RehearsalMark?, links: SongPartLinks) {
        storedID = id
        storedTitle = title
        storedMark = mark
        storedLinks = links
    }

    static func make(id: SongPartID, title: String, mark: RehearsalMark? = nil,
                     links: SongPartLinks = .none) throws(ShowRefusal) -> SongPart {
        guard ShowLimits.isValidTitle(title) else { throw .invalidTitle }
        return SongPart(id: id, title: title, mark: mark, links: links)
    }

    func replacingLinks(_ links: SongPartLinks) -> SongPart {
        SongPart(id: id, title: title, mark: mark, links: links)
    }
}

struct ShowSong: Hashable, Sendable, Identifiable {
    private let storedID: SongID
    private let storedTitle: String
    private let storedParts: [SongPart]
    private let storedChart: ChartReference?

    var id: SongID { storedID }
    var title: String { storedTitle }
    /// In performance order.
    var parts: [SongPart] { storedParts }
    /// The song's chart; a part's own chart overrides it.
    var chart: ChartReference? { storedChart }

    private init(id: SongID, title: String, parts: [SongPart], chart: ChartReference?) {
        storedID = id
        storedTitle = title
        storedParts = parts
        storedChart = chart
    }

    /// Load path: links are not checked against a catalog here (see `ShowLibrary.linkReport(in:)`).
    static func make(id: SongID, title: String, parts: [SongPart] = [],
                     chart: ChartReference? = nil) throws(ShowRefusal) -> ShowSong {
        guard ShowLimits.isValidTitle(title) else { throw .invalidTitle }
        guard parts.count <= ShowLimits.maximumPartsPerSong else { throw .tooManyParts(id, parts.count) }
        if let duplicate = ShowOrdering.firstDuplicate(in: parts) { throw .duplicatePart(id, duplicate) }
        var previous: Int64?
        for part in parts {
            guard let ticks = part.mark?.ticks else { continue }
            if let previous, ticks < previous { throw .marksOutOfOrder(part.id) }
            previous = ticks
        }
        return ShowSong(id: id, title: title, parts: parts, chart: chart)
    }

    func part(_ id: SongPartID) -> SongPart? { parts.first { $0.id == id } }

    /// Edit path: the new part's links must resolve in `catalog`.
    func insertingPart(_ part: SongPart, before anchor: SongPartID? = nil,
                       in catalog: ShowLinkCatalog) throws(ShowRefusal) -> ShowSong {
        try catalog.check(part.links)
        return try rebuilt(ShowOrdering.inserting(part, before: anchor, in: parts, unknown: ShowRefusal.unknownPart))
    }

    func movingPart(_ id: SongPartID, before anchor: SongPartID?) throws(ShowRefusal) -> ShowSong {
        try rebuilt(ShowOrdering.moving(id, before: anchor, in: parts, unknown: ShowRefusal.unknownPart))
    }

    func removingPart(_ id: SongPartID) throws(ShowRefusal) -> ShowSong {
        try rebuilt(ShowOrdering.removing(id, from: parts, unknown: ShowRefusal.unknownPart))
    }

    /// Edit path: only problems the part's current links do not already have are refused.
    func replacingLinks(_ links: SongPartLinks, for id: SongPartID,
                        in catalog: ShowLinkCatalog) throws(ShowRefusal) -> ShowSong {
        guard let index = parts.firstIndex(where: { $0.id == id }) else { throw .unknownPart(id) }
        try catalog.check(links, replacing: parts[index].links)
        var updated = parts
        updated[index] = parts[index].replacingLinks(links)
        return try rebuilt(updated)
    }

    /// Recovers a missing chart: the song's (`part == nil`) or one part's. `nil` clears it; a new reference
    /// must be available in `catalog`.
    func relinkingChart(_ chart: ChartReference?, part id: SongPartID? = nil,
                        in catalog: ShowLinkCatalog) throws(ShowRefusal) -> ShowSong {
        if let chart, case let .missing(_, reason) = catalog.availability(of: chart) {
            throw .chartUnavailable(chart, reason)
        }
        guard let id else { return try Self.make(id: self.id, title: title, parts: parts, chart: chart) }
        guard let index = parts.firstIndex(where: { $0.id == id }) else { throw .unknownPart(id) }
        var updated = parts
        updated[index] = parts[index].replacingLinks(parts[index].links.replacingChart(chart))
        return try rebuilt(updated)
    }

    private func rebuilt(_ parts: [SongPart]) throws(ShowRefusal) -> ShowSong {
        try Self.make(id: id, title: title, parts: parts, chart: chart)
    }
}
