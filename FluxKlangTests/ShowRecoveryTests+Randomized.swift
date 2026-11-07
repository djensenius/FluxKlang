import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// SplitMix64, seeded per run; private to this file.
private struct ShowRecoverySplitMix {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }

    /// A number in `0..<bound`.
    mutating func below(_ bound: Int) -> Int { Int(next() % UInt64(bound)) }

    /// True with the given probability, in percent.
    mutating func chance(_ percent: Int) -> Bool { below(100) < percent }
}

/// A chart as the model sees it: an index into `RecoveryWorld.assets` and an optional page.
private struct RecoveryModelChart: Hashable {
    let asset: Int
    let page: Int?
}

/// A song index into `RecoveryWorld.songs` and a part index into `RecoveryWorld.parts`; `nil` is the song's chart.
private struct RecoveryModelAddress: Hashable {
    let song: Int
    let part: Int?
}

/// Part `number` of a song has the ID `RecoveryWorld.parts[number]`.
private struct RecoveryModelSong {
    var chart: RecoveryModelChart?
    var parts: [RecoveryModelChart?]
}

private enum RecoveryModelDecision {
    case relinkAsset(from: Int, to: Int)
    case relinkTarget(RecoveryModelAddress, RecoveryModelChart)
    case clearAsset(Int)
    case clearTarget(RecoveryModelAddress)
}

private enum RecoveryModelReason {
    case notMissing(Int)
    case noSuchTarget(RecoveryModelAddress)
    case unavailable(RecoveryModelChart, ChartMissingReason)
}

/// The recovery rules again over flat indices: no dictionaries, no per-song rebuilds, one pass per decision.
private struct RecoveryModel {
    var songs: [RecoveryModelSong]
    private(set) var relinked = 0
    private(set) var cleared = 0

    init(songs: [RecoveryModelSong]) { self.songs = songs }

    func chart(at address: RecoveryModelAddress) -> RecoveryModelChart? {
        guard songs.indices.contains(address.song) else { return nil }
        guard let part = address.part else { return songs[address.song].chart }
        guard songs[address.song].parts.indices.contains(part) else { return nil }
        return songs[address.song].parts[part]
    }

    /// Every address holding a chart, in document order: a song's chart, then its parts' charts.
    var addresses: [RecoveryModelAddress] {
        var result: [RecoveryModelAddress] = []
        for (index, song) in songs.enumerated() {
            if song.chart != nil { result.append(RecoveryModelAddress(song: index, part: nil)) }
            for (number, held) in song.parts.enumerated() where held != nil {
                result.append(RecoveryModelAddress(song: index, part: number))
            }
        }
        return result
    }

    /// The addresses whose chart the catalog cannot show, optionally only those of one asset.
    func missingAddresses(of asset: Int? = nil) -> [RecoveryModelAddress] {
        addresses.filter { address in
            guard let held = chart(at: address), RecoveryWorld.missingReason(held.asset) != nil else { return false }
            return asset == nil || held.asset == asset
        }
    }

    /// The refusal the rules prescribe for `decision`, or `nil` once it is applied. A refusal changes nothing.
    mutating func apply(_ decision: RecoveryModelDecision) -> RecoveryModelReason? {
        switch decision {
        case let .relinkAsset(from, replacement): relinkAsset(from: from, to: replacement)
        case let .relinkTarget(address, chart): relinkTarget(address, to: chart)
        case let .clearAsset(asset): clearAsset(asset)
        case let .clearTarget(address): clearTarget(address)
        }
    }

    private mutating func relinkAsset(from asset: Int, to replacement: Int) -> RecoveryModelReason? {
        let slots = missingAddresses(of: asset)
        guard !slots.isEmpty else { return .notMissing(asset) }
        if let why = RecoveryWorld.missingReason(replacement) {
            return .unavailable(RecoveryModelChart(asset: replacement, page: nil), why)
        }
        for slot in slots {
            store(RecoveryModelChart(asset: replacement, page: chart(at: slot)?.page), at: slot)
        }
        relinked += slots.count
        return nil
    }

    private mutating func relinkTarget(_ address: RecoveryModelAddress,
                                       to replacement: RecoveryModelChart) -> RecoveryModelReason? {
        if let problem = selectionRefusal(address) { return problem }
        if let why = RecoveryWorld.missingReason(replacement.asset) { return .unavailable(replacement, why) }
        store(replacement, at: address)
        relinked += 1
        return nil
    }

    private mutating func clearAsset(_ asset: Int) -> RecoveryModelReason? {
        let slots = missingAddresses(of: asset)
        guard !slots.isEmpty else { return .notMissing(asset) }
        for slot in slots { store(nil, at: slot) }
        cleared += slots.count
        return nil
    }

    private mutating func clearTarget(_ address: RecoveryModelAddress) -> RecoveryModelReason? {
        if let problem = selectionRefusal(address) { return problem }
        store(nil, at: address)
        cleared += 1
        return nil
    }

    /// The refusal for an address that is not a missing chart: it holds no chart, or one that is available.
    private func selectionRefusal(_ address: RecoveryModelAddress) -> RecoveryModelReason? {
        guard let held = chart(at: address) else { return .noSuchTarget(address) }
        return RecoveryWorld.missingReason(held.asset) == nil ? .notMissing(held.asset) : nil
    }

    private mutating func store(_ value: RecoveryModelChart?, at address: RecoveryModelAddress) {
        guard let part = address.part else {
            songs[address.song].chart = value
            return
        }
        songs[address.song].parts[part] = value
    }

    /// The worklist the rules prescribe: missing charts grouped by asset in order of each asset's first occurrence.
    func digests() throws -> [ShowRecoveryDigest] {
        var order: [Int] = []
        for address in missingAddresses() {
            guard let held = chart(at: address), !order.contains(held.asset) else { continue }
            order.append(held.asset)
        }
        var result: [ShowRecoveryDigest] = []
        for asset in order {
            guard let why = RecoveryWorld.missingReason(asset) else { continue }
            var entries: [ShowRecoveryDigest.Entry] = []
            for address in missingAddresses(of: asset) {
                guard let held = chart(at: address) else { continue }
                let reference = try RecoveryWorld.reference(held)
                entries.append(ShowRecoveryDigest.Entry(target: RecoveryWorld.target(address), chart: reference))
            }
            result.append(ShowRecoveryDigest(asset: RecoveryWorld.assets[asset], reason: why, entries: entries))
        }
        return result
    }

    /// The library this state stands for: every song plays once, in order, in the setlist `set.main`.
    func library() throws -> ShowLibrary {
        var built: [ShowSong] = []
        var entries: [SetlistEntry] = []
        for (index, song) in songs.enumerated() {
            var parts: [SongPart] = []
            for (number, held) in song.parts.enumerated() {
                let links = try ShowRecoveryTestFixture.makeLinks(chart: RecoveryWorld.optionalReference(held))
                parts.append(try SongPart.make(id: RecoveryWorld.parts[number], title: "Part", links: links))
            }
            let chart = try RecoveryWorld.optionalReference(song.chart)
            built.append(try ShowSong.make(id: RecoveryWorld.songs[index], title: "Song", parts: parts, chart: chart))
            entries.append(try ShowRecoveryTestFixture.entry(index + 1, RecoveryWorld.songs[index]))
        }
        let main = try ShowSetlist.make(id: ShowRecoveryTestFixture.mainList, title: "Main", entries: entries)
        return try ShowLibrary.make(songs: built, setlists: [main])
    }
}

/// The first refused decision of a generated batch.
private struct RecoveryModelRefusal {
    let index: Int
    let reason: RecoveryModelReason
}

private struct RecoveryModelBatch {
    let decisions: [RecoveryModelDecision]
    let refusal: RecoveryModelRefusal?
    /// The model after every decision before the refusal, or after all of them when none was refused.
    let after: RecoveryModel

    var appliedCount: Int { refusal?.index ?? decisions.count }
}

/// The names a model refers to by index, the catalog that judges them and the seeded generators.
private enum RecoveryWorld {
    /// `r.0` and `r.1` are usable; `r.2` and `r.7` are documents without content; `r.3` is MIDI and `r.4` audio, both
    /// with content; `r.5` and `r.6` are not in the project.
    static let assets = [
        AssetID(validated: "r.0"), AssetID(validated: "r.1"), AssetID(validated: "r.2"), AssetID(validated: "r.3"),
        AssetID(validated: "r.4"), AssetID(validated: "r.5"), AssetID(validated: "r.6"), AssetID(validated: "r.7")
    ]
    static let songs = [SongID(validated: "song.0"), SongID(validated: "song.1"), SongID(validated: "song.2"),
                        SongID(validated: "song.3")]
    static let parts = [
        SongPartID(validated: "part.0"), SongPartID(validated: "part.1"), SongPartID(validated: "part.2"),
        SongPartID(validated: "part.3"), SongPartID(validated: "part.4"), SongPartID(validated: "part.5")
    ]

    /// Why the catalog cannot show an asset, or `nil` when it can.
    static func missingReason(_ asset: Int) -> ChartMissingReason? {
        switch asset {
        case 0, 1: return nil
        case 2, 7: return .contentUnavailable
        case 3: return .notDocument(.midi)
        case 4: return .notDocument(.audio)
        default: return .notInProject
        }
    }

    private static func listedMedia(of asset: Int) -> AssetMedia? {
        switch asset {
        case 0, 1, 2, 7: return .document
        case 3: return .midi
        case 4: return .audio
        default: return nil
        }
    }

    static func catalog() throws -> ShowLinkCatalog {
        var listed: [ProjectAsset] = []
        for (index, id) in assets.enumerated() {
            guard let media = listedMedia(of: index) else { continue }
            listed.append(ShowRecoveryTestFixture.asset(id, media))
        }
        return try ShowLinkCatalog.make(assets: listed, availableContent: [0, 1, 3, 4].map { assets[$0] })
    }

    static func reference(_ chart: RecoveryModelChart) throws -> ChartReference {
        try ChartReference.make(asset: assets[chart.asset], page: chart.page)
    }

    static func optionalReference(_ chart: RecoveryModelChart?) throws -> ChartReference? {
        guard let chart else { return nil }
        return try reference(chart)
    }

    static func target(_ address: RecoveryModelAddress) -> ShowRecoveryTarget {
        ShowRecoveryTarget(song: songs[address.song], part: address.part.map { parts[$0] })
    }

    static func decision(_ model: RecoveryModelDecision) throws -> ShowRecoveryDecision {
        switch model {
        case let .relinkAsset(source, replacement):
            return .relinkAsset(from: assets[source], to: assets[replacement])
        case let .relinkTarget(address, chart):
            let supplied = try reference(chart)
            return .relinkTarget(target(address), to: supplied)
        case let .clearAsset(asset):
            return .clearAsset(assets[asset])
        case let .clearTarget(address):
            return .clearTarget(target(address))
        }
    }

    static func reason(_ model: RecoveryModelReason) throws -> ShowRecoveryReason {
        switch model {
        case let .notMissing(asset):
            return .notMissing(assets[asset])
        case let .noSuchTarget(address):
            return .noSuchTarget(target(address))
        case let .unavailable(chart, why):
            let supplied = try reference(chart)
            return .show(.chartUnavailable(supplied, why))
        }
    }

    // MARK: - Generators

    // The order in which a generator draws from `random` is part of what a seed means.

    static func randomPage(_ random: inout ShowRecoverySplitMix) -> Int? {
        switch random.below(4) {
        case 0: return nil
        case 1: return 1
        case 2: return ShowLimits.maximumChartPage
        default: return 1 + random.below(ShowLimits.maximumChartPage)
        }
    }

    /// A usable asset `percent` times in 100 (and otherwise any), so healthy and missing charts both occur.
    static func randomAsset(_ random: inout ShowRecoverySplitMix, usable percent: Int) -> Int {
        random.chance(percent) ? random.below(2) : random.below(assets.count)
    }

    static func randomChart(_ random: inout ShowRecoverySplitMix, present percent: Int) -> RecoveryModelChart? {
        guard random.chance(percent) else { return nil }
        let asset = randomAsset(&random, usable: 20)
        return RecoveryModelChart(asset: asset, page: randomPage(&random))
    }

    static func randomModel(_ random: inout ShowRecoverySplitMix) -> RecoveryModel {
        var built: [RecoveryModelSong] = []
        for _ in 0..<(1 + random.below(songs.count)) {
            let chart = randomChart(&random, present: 85)
            var held: [RecoveryModelChart?] = []
            for _ in 0..<random.below(parts.count + 1) { held.append(randomChart(&random, present: 80)) }
            built.append(RecoveryModelSong(chart: chart, parts: held))
        }
        return RecoveryModel(songs: built)
    }

    /// The asset of a missing chart 19 times in 20, when there is one; otherwise any asset.
    static func aimedAsset(_ model: RecoveryModel, _ random: inout ShowRecoverySplitMix) -> Int {
        let missing = model.missingAddresses()
        guard random.chance(95), !missing.isEmpty else { return random.below(assets.count) }
        let address = missing[random.below(missing.count)]
        return model.chart(at: address)?.asset ?? 0
    }

    /// A missing chart's address 19 times in 20, when there is one; otherwise any address, held or not.
    static func aimedAddress(_ model: RecoveryModel, _ random: inout ShowRecoverySplitMix) -> RecoveryModelAddress {
        let missing = model.missingAddresses()
        if random.chance(95), !missing.isEmpty { return missing[random.below(missing.count)] }
        let song = random.below(songs.count)
        return RecoveryModelAddress(song: song, part: random.chance(50) ? nil : random.below(parts.count))
    }

    static func randomDecision(_ model: RecoveryModel,
                               _ random: inout ShowRecoverySplitMix) -> RecoveryModelDecision {
        switch random.below(4) {
        case 0:
            let source = aimedAsset(model, &random)
            return .relinkAsset(from: source, to: randomAsset(&random, usable: 85))
        case 1:
            let address = aimedAddress(model, &random)
            let asset = randomAsset(&random, usable: 85)
            return .relinkTarget(address, RecoveryModelChart(asset: asset, page: randomPage(&random)))
        case 2:
            return .clearAsset(aimedAsset(model, &random))
        default:
            return .clearTarget(aimedAddress(model, &random))
        }
    }

    /// One to six decisions. Decisions are still drawn after the first refusal, which is the one that counts.
    static func randomBatch(from start: RecoveryModel, _ random: inout ShowRecoverySplitMix) -> RecoveryModelBatch {
        var model = start
        var decisions: [RecoveryModelDecision] = []
        var refusal: RecoveryModelRefusal?
        for index in 0..<(1 + random.below(6)) {
            let decision = randomDecision(model, &random)
            decisions.append(decision)
            guard refusal == nil, let reason = model.apply(decision) else { continue }
            refusal = RecoveryModelRefusal(index: index, reason: reason)
        }
        return RecoveryModelBatch(decisions: decisions, refusal: refusal, after: model)
    }
}

/// What the generators reached, so that a comparison with the model cannot pass on a degenerate seed range.
private struct RecoveryTally {
    var accepted = 0
    var refused = 0
    var refusedAfterApplying = 0
    var notMissing = 0
    var noSuchTarget = 0
    var unavailable = 0

    mutating func record(_ refusal: RecoveryModelRefusal) {
        refused += 1
        if refusal.index > 0 { refusedAfterApplying += 1 }
        switch refusal.reason {
        case .notMissing: notMissing += 1
        case .noSuchTarget: noSuchTarget += 1
        case .unavailable: unavailable += 1
        }
    }
}

extension ShowRecoveryTests {
    @Test
    func theIndependentModelAgreesWithTheCatalogOnEveryAsset() throws {
        let judge = try RecoveryWorld.catalog()
        for asset in RecoveryWorld.assets.indices {
            let chart = try RecoveryWorld.reference(RecoveryModelChart(asset: asset, page: nil))
            if let why = RecoveryWorld.missingReason(asset) {
                #expect(judge.availability(of: chart) == .missing(chart, why), "asset \(asset)")
            } else {
                #expect(judge.availability(of: chart) == .available(chart), "asset \(asset)")
            }
        }
    }

    @Test
    func seededWorklistsMatchAnIndependentOracle() throws {
        let judge = try RecoveryWorld.catalog()
        var withWork = 0
        for seed in UInt64(1)...150 {
            var random = ShowRecoverySplitMix(seed: seed)
            let model = RecoveryWorld.randomModel(&random)
            let library = try model.library()
            let list = ShowRecoveryWorklist.make(library: library, catalog: judge)
            let expected = try model.digests()
            #expect(ShowRecoveryDigest.digests(of: list) == expected, "seed \(seed)")
            #expect(list.targetCount == model.missingAddresses().count, "seed \(seed)")
            #expect(list.nonChartProblemCount == 0, "seed \(seed)")
            #expect(list.isEmpty == expected.isEmpty, "seed \(seed)")
            if !expected.isEmpty { withWork += 1 }
        }
        #expect(withWork >= 130)
    }

    @Test
    func seededBatchesMatchAnIndependentSlotModel() throws {
        let judge = try RecoveryWorld.catalog()
        var tally = RecoveryTally()
        for seed in UInt64(1)...150 { try checkSeededBatch(seed: seed, judge: judge, tally: &tally) }
        #expect(tally.accepted >= 45)
        #expect(tally.refused >= 50)
        #expect(tally.refusedAfterApplying >= 35)
        #expect(tally.notMissing >= 18)
        #expect(tally.noSuchTarget >= 15)
        #expect(tally.unavailable >= 10)
    }

    /// The refusal of the whole batch names the first refused decision; the decisions before it still apply, and
    /// what they leave behind is exactly the model's library, counts and worklist.
    private func checkSeededBatch(seed: UInt64, judge: ShowLinkCatalog, tally: inout RecoveryTally) throws {
        var random = ShowRecoverySplitMix(seed: seed)
        let start = RecoveryWorld.randomModel(&random)
        let batch = RecoveryWorld.randomBatch(from: start, &random)
        let library = try start.library()
        let decisions = try batch.decisions.map { try RecoveryWorld.decision($0) }
        if let expected = batch.refusal {
            let reason = try RecoveryWorld.reason(expected.reason)
            let actual = Fix.refusal(of: decisions, in: library, catalog: judge)
            #expect(actual?.index == expected.index, "seed \(seed)")
            #expect(actual?.reason == reason, "seed \(seed)")
            tally.record(expected)
        } else {
            tally.accepted += 1
        }
        let applied = try ShowChartRecovery.apply(Array(decisions.prefix(batch.appliedCount)), to: library, in: judge)
        let recovered = try batch.after.library()
        let digests = try batch.after.digests()
        #expect(applied.library == recovered, "seed \(seed)")
        #expect(applied.relinkedTargetCount == batch.after.relinked, "seed \(seed)")
        #expect(applied.clearedTargetCount == batch.after.cleared, "seed \(seed)")
        #expect(ShowRecoveryDigest.digests(of: applied.worklist) == digests, "seed \(seed)")
        #expect(applied.worklist.nonChartProblemCount == 0, "seed \(seed)")
    }
}
