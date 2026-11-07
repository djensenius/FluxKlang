//
//  ShowChartRecovery.swift
//  FluxKlang
//
//  Applies explicit recovery decisions to a show's missing charts (#106 SH4). Decisions run in order and later ones
//  see earlier results. The batch is atomic and bounded, and only chart references change. `apply` lives in
//  `ShowRecoveryOutcome.swift`, the one file that can build an outcome.
//
//  A slot is one chart reference held by a song (`part == nil`) or by one of its parts. It is missing exactly when
//  `ShowLinkCatalog.availability(of:)` says so; that check is never duplicated. Per decision the selection is checked
//  first (`notMissing`, `noSuchTarget`), then the replacement. Recovery never creates a missing slot: a replacement
//  must be available and a clear removes the reference. Clearing a song's chart also removes what its parts inherit
//  from it; the counts count slots, not inheritors.
//

enum ShowChartRecovery {
    /// A bigger batch is refused whole, before any decision is read.
    static let maximumDecisions = 1_024
}

/// The working copy of one batch: the library's songs, replaced in place, never reordered. It is internal, not
/// private, so that `ShowChartRecovery.apply` (in another file) and the access fence can reach it.
/// In-module code can therefore build a batch and apply more than `ShowChartRecovery.maximumDecisions` decisions to
/// it: the bound is enforced by `apply`, not by this type. An outcome still cannot be forged: its initializer is
/// `fileprivate` and this type cannot build one.
struct ShowRecoveryBatch {
    private(set) var songs: [ShowSong]
    private(set) var relinkedCount = 0
    private(set) var clearedCount = 0
    private let catalog: ShowLinkCatalog
    /// Lookup only; never iterated, so no hash order is observable.
    private let positions: [SongID: Int]

    /// One chart reference, the position of its song in `songs`, and where it lives.
    fileprivate struct Slot {
        let position: Int
        let target: ShowRecoveryTarget
        let chart: ChartReference
    }

    init(library: ShowLibrary, catalog: ShowLinkCatalog) {
        var positions: [SongID: Int] = [:]
        for (position, song) in library.songs.enumerated() { positions[song.id] = position }
        songs = library.songs
        self.positions = positions
        self.catalog = catalog
    }

    mutating func apply(_ decision: ShowRecoveryDecision) throws(ShowRecoveryReason) {
        switch decision {
        case let .relinkAsset(source, replacement):
            try relinkAsset(from: source, to: replacement)
        case let .relinkTarget(target, chart):
            try relinkTarget(target, to: chart)
        case let .clearAsset(asset):
            try clearAsset(asset)
        case let .clearTarget(target):
            try clearTarget(target)
        }
    }

    /// Every missing reference to `asset` moves to `replacement` and keeps its own page.
    private mutating func relinkAsset(from asset: AssetID, to replacement: AssetID) throws(ShowRecoveryReason) {
        let held = missingSlots(of: asset)
        guard !held.isEmpty else { throw .notMissing(asset) }
        try requireAvailable(replacement)
        for slot in held {
            try replace(slot, with: Self.makeChart(replacement, page: slot.chart.page))
            relinkedCount += 1
        }
    }

    private mutating func relinkTarget(_ target: ShowRecoveryTarget,
                                       to chart: ChartReference) throws(ShowRecoveryReason) {
        try replace(missingSlot(at: target), with: chart)
        relinkedCount += 1
    }

    private mutating func clearAsset(_ asset: AssetID) throws(ShowRecoveryReason) {
        let held = missingSlots(of: asset)
        guard !held.isEmpty else { throw .notMissing(asset) }
        for slot in held {
            try replace(slot, with: nil)
            clearedCount += 1
        }
    }

    private mutating func clearTarget(_ target: ShowRecoveryTarget) throws(ShowRecoveryReason) {
        try replace(missingSlot(at: target), with: nil)
        clearedCount += 1
    }

    /// The catalog's own check, run once on the page-less replacement so its refusal does not depend on any page.
    private func requireAvailable(_ asset: AssetID) throws(ShowRecoveryReason) {
        do throws(ShowRefusal) {
            try catalog.checkChart(ChartReference.make(asset: asset))
        } catch {
            throw .show(error)
        }
    }

    /// Re-validates the page through the factory.
    private static func makeChart(_ asset: AssetID, page: Int?) throws(ShowRecoveryReason) -> ChartReference {
        do throws(ShowRefusal) {
            return try ChartReference.make(asset: asset, page: page)
        } catch {
            throw .show(error)
        }
    }

    /// `ShowSong.relinkingChart` checks a new chart against the catalog and keeps every other field of the song.
    private mutating func replace(_ slot: Slot, with chart: ChartReference?) throws(ShowRecoveryReason) {
        do throws(ShowRefusal) {
            songs[slot.position] = try songs[slot.position].relinkingChart(chart, part: slot.target.part,
                                                                           in: catalog)
        } catch {
            throw .show(error)
        }
    }

    private func isMissing(_ chart: ChartReference) -> Bool {
        switch catalog.availability(of: chart) {
        case .available: false
        case .missing: true
        }
    }

    /// The currently missing slots that hold `asset`, in document order.
    /// Rescans all slots per call: bounded, but not for the main thread or a large catalog on a latency-critical path.
    private func missingSlots(of asset: AssetID) -> [Slot] {
        var found: [Slot] = []
        for (position, song) in songs.enumerated() {
            let slots = Self.slots(of: song, at: position)
            found += slots.filter { $0.chart.asset == asset && isMissing($0.chart) }
        }
        return found
    }

    /// The slot at `target`, which must hold a chart that is currently missing.
    private func missingSlot(at target: ShowRecoveryTarget) throws(ShowRecoveryReason) -> Slot {
        guard let slot = findSlot(at: target) else { throw .noSuchTarget(target) }
        guard isMissing(slot.chart) else { throw .notMissing(slot.chart.asset) }
        return slot
    }

    private func findSlot(at target: ShowRecoveryTarget) -> Slot? {
        guard let position = positions[target.song] else { return nil }
        return Self.slots(of: songs[position], at: position).first { $0.target == target }
    }

    /// A song's chart references in document order: its own chart, then its parts' in order.
    private static func slots(of song: ShowSong, at position: Int) -> [Slot] {
        var found: [Slot] = []
        if let chart = song.chart {
            let target = ShowRecoveryTarget(song: song.id, part: nil)
            found.append(Slot(position: position, target: target, chart: chart))
        }
        for part in song.parts {
            guard let chart = part.links.chart else { continue }
            let target = ShowRecoveryTarget(song: song.id, part: part.id)
            found.append(Slot(position: position, target: target, chart: chart))
        }
        return found
    }
}
