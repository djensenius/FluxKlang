//
//  ShowRecoveryWorklist.swift
//  FluxKlang
//
//  What a loaded show still lacks (#106 SH4): every missing chart reference, grouped by the missing asset, in a
//  fixed order. A pure report of values: no file access, no URLs, no chart bytes. Broken patch, variation and
//  action-set links are only counted; they are not chart recovery work.
//

/// Where one chart reference lives: the song's own chart (`part == nil`) or one part's chart. An address only;
/// `ShowChartRecovery` refuses an address that holds no chart.
struct ShowRecoveryTarget: Hashable, Sendable {
    let song: SongID
    let part: SongPartID?
}

/// One missing chart reference and where it lives. Built only by `ShowRecoveryWorklist.make`.
struct ShowRecoveryItem: Hashable, Sendable {
    private let storedTarget: ShowRecoveryTarget
    private let storedChart: ChartReference

    var target: ShowRecoveryTarget { storedTarget }
    /// The stored reference, with its own page.
    var chart: ChartReference { storedChart }

    fileprivate init(target: ShowRecoveryTarget, chart: ChartReference) {
        storedTarget = target
        storedChart = chart
    }
}

/// Every missing reference to one asset. Availability depends on the asset alone, never the page, so one group has
/// one reason. Built only by `ShowRecoveryWorklist.make`.
struct ShowRecoveryGroup: Hashable, Sendable {
    private let storedAsset: AssetID
    private let storedReason: ChartMissingReason
    private let storedItems: [ShowRecoveryItem]

    var asset: AssetID { storedAsset }
    var reason: ChartMissingReason { storedReason }
    /// In document order: songs in library order; within a song, its own chart, then its parts in order.
    var items: [ShowRecoveryItem] { storedItems }

    fileprivate init(asset: AssetID, reason: ChartMissingReason, items: [ShowRecoveryItem]) {
        storedAsset = asset
        storedReason = reason
        storedItems = items
    }
}

struct ShowRecoveryWorklist: Hashable, Sendable {
    /// One slot per song chart and part chart of a library at its limits: every song and each of its parts.
    static let maximumTargets = ShowLimits.maximumSongs * (1 + ShowLimits.maximumPartsPerSong)

    private let storedGroups: [ShowRecoveryGroup]
    private let storedNonChartProblemCount: Int

    /// In order of each asset's first missing reference in document order, never alphabetical or hash order.
    var groups: [ShowRecoveryGroup] { storedGroups }
    /// Broken patch, variation and action-set links. `linkReport(in:)` still lists them; recovery leaves them alone.
    var nonChartProblemCount: Int { storedNonChartProblemCount }
    /// No chart is missing. Other link problems do not count as recovery work.
    var isEmpty: Bool { storedGroups.isEmpty }
    var targetCount: Int { storedGroups.reduce(0) { $0 + $1.items.count } }

    private init(groups: [ShowRecoveryGroup], nonChartProblemCount: Int) {
        storedGroups = groups
        storedNonChartProblemCount = nonChartProblemCount
    }

    func group(for asset: AssetID) -> ShowRecoveryGroup? { storedGroups.first { $0.asset == asset } }

    /// Reads `library.linkReport(in:)`, which is already in document order, so the result is deterministic. The
    /// dictionary only maps an asset to its slot in the ordered arrays and is never iterated.
    static func make(library: ShowLibrary, catalog: ShowLinkCatalog) -> ShowRecoveryWorklist {
        var assets: [AssetID] = []
        var reasons: [ChartMissingReason] = []
        var items: [[ShowRecoveryItem]] = []
        var slots: [AssetID: Int] = [:]
        var otherProblems = 0
        for issue in library.linkReport(in: catalog) {
            guard case let .chart(chart, reason) = issue.problem else {
                otherProblems += 1
                continue
            }
            let target = ShowRecoveryTarget(song: issue.song, part: issue.part)
            let item = ShowRecoveryItem(target: target, chart: chart)
            if let slot = slots[chart.asset] {
                items[slot].append(item)
            } else {
                slots[chart.asset] = assets.count
                assets.append(chart.asset)
                reasons.append(reason)
                items.append([item])
            }
        }
        let groups = assets.indices.map { ShowRecoveryGroup(asset: assets[$0], reason: reasons[$0], items: items[$0]) }
        return ShowRecoveryWorklist(groups: groups, nonChartProblemCount: otherProblems)
    }
}
