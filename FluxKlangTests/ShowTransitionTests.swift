import Foundation
import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

/// Patches `pat.keys` (verse, chorus) and `pat.pad`; action sets `as.ready` (act.0), `as.cold` (act.1 ready,
/// act.2 preparing) and `as.orphan` (a member the project lacks). Song A: a1 keys/verse + as.ready + its own
/// available chart, a2 keys/chorus + as.cold, a3 pad; A's song chart is stale. Song B: b1 keys/base + as.orphan,
/// b2 an unknown patch and action set, b3 keys with an unknown variation, b4 nothing. Song C has no parts and an
/// available song chart. Setlist `set.main` plays e1 A, e2 B, e3 C.
enum ShowTransitionTestFixture {
    static let keys = PatchID(validated: "pat.keys")
    static let pad = PatchID(validated: "pat.pad")
    static let gonePatch = PatchID(validated: "pat.gone")
    static let verse = PatchVariationID(validated: "verse")
    static let chorus = PatchVariationID(validated: "chorus")
    static let goneVariation = PatchVariationID(validated: "var.gone")
    static let gain = ParameterID(validated: "par.gain")
    static let mix = ParameterID(validated: "par.mix")
    static let mode = ParameterID(validated: "par.mode")
    static let readySet = ActionSetID(validated: "as.ready")
    static let coldSet = ActionSetID(validated: "as.cold")
    static let orphanSet = ActionSetID(validated: "as.orphan")
    static let goneSet = ActionSetID(validated: "as.gone")
    static let acts = ["act.0", "act.1", "act.2"].map { ActionID(rawValue: $0)! }
    static let missingAct = ActionID(validated: "act.missing")
    static let chartAsset = AssetID(validated: "ast.chart")
    static let staleAsset = AssetID(validated: "ast.stale")
    static let songA = SongID(validated: "song.a")
    static let songB = SongID(validated: "song.b")
    static let songC = SongID(validated: "song.c")
    static let main = SetlistID(validated: "set.main")
    static let foot = ShowInputSourceID(validated: "src.foot")
    static let source = GenerationKey(kind: .source, subject: GenerationSubject(validated: "source.show"))

    static func value(_ value: Double, _ unit: ParameterUnit) -> ParameterValue {
        ParameterValue(value: value, unit: unit)
    }

    static func table() throws -> PatchParameterTable {
        func descriptor(_ id: ParameterID, _ unit: ParameterUnit, _ range: ClosedRange<Double>) throws
            -> ParameterDescriptor {
            try ParameterDescriptor(.init(
                id: id, unit: unit, lower: range.lowerBound, upper: range.upperBound, defaultValue: range.lowerBound,
                ceiling: nil, curve: unit == .index ? .stepped : .linear, ramp: .step, controlClass: .live,
                verification: .unverified
            ))
        }
        return try PatchParameterTable(ParameterCatalog([
            descriptor(gain, .decibels, -90...10), descriptor(mix, .normalized, 0...1), descriptor(mode, .index, 1...4)
        ]))
    }

    /// verse: gain -6, mix 0.5; chorus: mode 3, gain 0. `withChorus: false` stores verse only.
    static func recallSource(_ id: PatchID, withChorus: Bool = true) throws -> ShowPatchRecallSource {
        let delta = { (parameter: ParameterID, number: Double, unit: ParameterUnit) in
            PatchParameterDelta(parameter: parameter, value: value(number, unit))
        }
        var variations = [PatchVariation(id: verse, label: "Verse",
                                         deltas: [delta(gain, -6, .decibels), delta(mix, 0.5, .normalized)])]
        if withChorus {
            variations.append(PatchVariation(id: chorus, label: "Chorus",
                                             deltas: [delta(mode, 3, .index), delta(gain, 0, .decibels)]))
        }
        let patch = try PatchVariationExtension.write(
            PatchVariationSet(variations: variations),
            to: ProjectPatch(id: id, label: "Patch", graph: GraphID(validated: "graph.main"))
        )
        let table = try table()
        return ShowPatchRecallSource(patch: patch, table: table, baseline: .defaults(table))
    }

    static func actionLibrary() throws -> PerformanceActionSetLibrary {
        try PerformanceActionSetLibrary(sets: [
            PerformanceActionSet(id: readySet, members: [acts[0]]),
            PerformanceActionSet(id: coldSet, members: [acts[1], acts[2]]),
            PerformanceActionSet(id: orphanSet, members: [missingAct])
        ])
    }

    static func actionSource(stale: [ActionID: [GenerationKey]] = [:]) throws -> ShowActionSetSource {
        let ledger = try GenerationLedger(primaryClock: ClockID(validated: "smp.show"), musicalClock: nil,
                                          nominalRate: 48_000, declaring: [source])
        var readiness = ActionReadiness()
        for action in acts { try readiness.transition(action, to: .preparing) }
        try readiness.markReady(acts[0], preparedAgainst: [], ledger: ledger)
        try readiness.markReady(acts[1], preparedAgainst: [], ledger: ledger)
        let policy = try ActionPolicy(media: .state, timePolicy: nil, latePolicy: .drop)
        let actions = acts.map { ProjectMediaAction(id: $0, asset: chartAsset, policy: policy) }
        return try ShowActionSetSource(library: actionLibrary(), actions: actions, readiness: readiness,
                                       ledger: ledger, stale: stale)
    }

    static func context(patches: [PatchID] = [keys, pad], keysWithChorus: Bool = true,
                        actions: ShowActionSetSource?? = .none) throws -> ShowTransitionContext {
        let sources = try patches.map { try recallSource($0, withChorus: $0 != keys || keysWithChorus) }
        return try ShowTransitionContext.make(patches: sources, actionSets: actions ?? actionSource())
    }

    static func catalog() throws -> ShowLinkCatalog {
        let digest = "sha256:" + String(repeating: "a", count: 64)
        return try ShowLinkCatalog.make(
            patches: [(keys, [verse, chorus]), (pad, [])], actionSets: actionLibrary(),
            assets: [chartAsset, staleAsset].map { ProjectAsset(id: $0, label: "Chart", media: .document,
                                                                contentDigest: digest) },
            availableContent: [chartAsset]
        )
    }

    static func part(_ raw: String, _ links: SongPartLinks = .none) throws -> SongPart {
        try SongPart.make(id: SongPartID(rawValue: raw)!, title: "Part \(raw)", links: links)
    }

    static func library(entries: [String] = ["e1", "e2", "e3"]) throws -> ShowLibrary {
        let chart = try ChartReference.make(asset: chartAsset)
        let first = try ShowSong.make(id: songA, title: "A", parts: [
            part("a1", .make(patch: keys, variation: verse, actionSet: readySet, chart: chart)),
            part("a2", .make(patch: keys, variation: chorus, actionSet: coldSet)),
            part("a3", .make(patch: pad))
        ], chart: ChartReference.make(asset: staleAsset, page: 2))
        let second = try ShowSong.make(id: songB, title: "B", parts: [
            part("b1", .make(patch: keys, actionSet: orphanSet)),
            part("b2", .make(patch: gonePatch, actionSet: goneSet)),
            part("b3", .make(patch: keys, variation: goneVariation)),
            part("b4")
        ])
        let third = try ShowSong.make(id: songC, title: "C", chart: chart)
        let songsByEntry = ["e1": songA, "e2": songB, "e3": songC]
        let setlist = try ShowSetlist.make(id: main, title: "Main", entries: entries.map {
            SetlistEntry.make(id: SetlistEntryID(rawValue: $0)!, song: songsByEntry[$0]!)
        })
        return try ShowLibrary.make(songs: [first, second, third], setlists: [setlist])
    }

    /// The stop a fresh cursor reaches by jumping to `entry` (and `part`, else the entry's first part).
    static func stop(_ entry: String, _ part: String? = nil, in library: ShowLibrary? = nil) throws -> ShowStop {
        let library = try library ?? Self.library()
        var cursor = try ShowCursor.make(setlist: main, bounceTicks: 0, sources: [foot], in: library)
        let jump = ShowNavigationInput(.jump(SetlistEntryID(rawValue: entry)!, part.map { SongPartID(rawValue: $0)! }),
                                       source: foot, sequence: 1, tick: 0)
        guard case let .moved(stop) = try cursor.navigate(jump, in: library, catalog: catalog()) else {
            throw ShowRefusal.atStart
        }
        return stop
    }

    static func plan(_ from: ShowStop?, _ to: ShowStop,
                     context: ShowTransitionContext? = nil) throws -> ShowTransitionPlan {
        try ShowTransitionPlanner.plan(from: from, to: to, in: context ?? Self.context())
    }
}

struct ShowTransitionTests {
    typealias Fix = ShowTransitionTestFixture

    @Test
    func samePatchPlansAVariationRecallOfOnlyChangedParameters() throws {
        let plan = try Fix.plan(Fix.stop("e1", "a1"), Fix.stop("e1", "a2"))
        #expect(plan.patch == .planned(PatchRecallPlan(patch: Fix.keys, from: Fix.verse, to: Fix.chorus, changes: [
            PatchParameterChange(parameter: Fix.gain, from: Fix.value(-6, .decibels), to: Fix.value(0, .decibels)),
            PatchParameterChange(parameter: Fix.mix, from: Fix.value(0.5, .normalized), to: Fix.value(0, .normalized)),
            PatchParameterChange(parameter: Fix.mode, from: Fix.value(1, .index), to: Fix.value(3, .index))
        ])))
        let toBase = try Fix.plan(Fix.stop("e1", "a1"), Fix.stop("e2", "b1"))
        #expect(toBase.patch.planned?.from == Fix.verse && toBase.patch.planned?.to == nil)
        #expect(toBase.patch.planned?.changes.map(\.parameter) == [Fix.gain, Fix.mix])
        let again = try Fix.plan(Fix.stop("e1", "a2"), Fix.stop("e1", "a2"))
        #expect(again.patch == .planned(PatchRecallPlan(patch: Fix.keys, from: Fix.chorus, to: Fix.chorus,
                                                        changes: [])))
    }

    @Test
    func anotherPatchIsBlockedForStructuralActivationReview() throws {
        let toPad = try Fix.plan(Fix.stop("e1", "a2"), Fix.stop("e1", "a3"))
        #expect(toPad.patch == .blocked(.requiresStructuralActivationReview(from: Fix.keys, to: Fix.pad)))
        #expect(toPad.blocks.first?.isRecoverable == false)
        let backToKeys = try Fix.plan(Fix.stop("e1", "a3"), Fix.stop("e2", "b1"))
        #expect(backToKeys.patch == .blocked(.requiresStructuralActivationReview(from: Fix.pad, to: Fix.keys)))
        let fromNothing = try Fix.plan(Fix.stop("e2", "b4"), Fix.stop("e1", "a1"))
        #expect(fromNothing.patch == .blocked(.requiresStructuralActivationReview(from: nil, to: Fix.keys)))
        let firstStop = try Fix.plan(nil, Fix.stop("e1", "a1"))
        #expect(firstStop.from == nil)
        #expect(firstStop.patch == .blocked(.requiresStructuralActivationReview(from: nil, to: Fix.keys)))
        let toNoPatch = try Fix.plan(Fix.stop("e1", "a1"), Fix.stop("e2", "b4"))
        #expect(toNoPatch.patch == .unlinked && toNoPatch.actionSet == .unlinked && toNoPatch.chart == .unlinked)
        #expect(toNoPatch.isClear)
    }

    @Test
    func unresolvedLinksAreRecoverableBlocks() throws {
        let gone = try Fix.plan(Fix.stop("e2", "b1"), Fix.stop("e2", "b2"))
        #expect(gone.blocks == [.unresolvedLink(.unknownPatch(Fix.gonePatch)),
                                .unresolvedLink(.unknownActionSet(Fix.goneSet))])
        #expect(gone.blocks.allSatisfy(\.isRecoverable) && !gone.isClear)
        let variation = try Fix.plan(Fix.stop("e2", "b1"), Fix.stop("e2", "b3"))
        #expect(variation.patch == .blocked(.unresolvedLink(.unknownVariation(Fix.keys, Fix.goneVariation))))
        let noSource = try Fix.plan(Fix.stop("e1", "a1"), Fix.stop("e1", "a2"),
                                    context: Fix.context(patches: [Fix.pad]))
        #expect(noSource.patch == .blocked(.unresolvedLink(.unknownPatch(Fix.keys))))
        let refused = try Fix.plan(Fix.stop("e1", "a1"), Fix.stop("e1", "a2"),
                                   context: Fix.context(keysWithChorus: false))
        #expect(refused.patch == .blocked(.patchRecallRefused(Fix.keys, .unknownVariation(Fix.chorus))))
        #expect(refused.patch.block?.isRecoverable == true)
        let orphan = try Fix.plan(Fix.stop("e1", "a1"), Fix.stop("e2", "b1"))
        #expect(orphan.actionSet == .blocked(.actionSetRefused(Fix.orphanSet, .unknownMember(Fix.missingAct))))
        let noSets = try Fix.plan(Fix.stop("e1", "a1"), Fix.stop("e1", "a2"),
                                  context: Fix.context(actions: .some(nil)))
        #expect(noSets.actionSet == .blocked(.actionSetRefused(Fix.coldSet, .unknownSet(Fix.coldSet))))
        #expect(noSets.patch.planned != nil)
    }

    @Test
    func theActionSetIsArmedWithItsReadinessAndNeverRequiredToBeReady() throws {
        let ready = try Fix.plan(Fix.stop("e1", "a2"), Fix.stop("e1", "a1"))
        let report = try #require(ready.actionSet.planned)
        #expect(report.set == Fix.readySet && report.isReady && report.notReady.isEmpty)
        #expect(report.members == [ActionSetMemberStatus(action: Fix.acts[0], state: .ready, reason: nil)])
        let cold = try #require(try Fix.plan(Fix.stop("e1", "a1"), Fix.stop("e1", "a2")).actionSet.planned)
        #expect(cold.set == Fix.coldSet && cold.state == .preparing && !cold.isReady)
        #expect(cold.notReady == [ActionSetMemberStatus(action: Fix.acts[2], state: .preparing, reason: nil)])
        let staleSource = try Fix.actionSource(stale: [Fix.acts[0]: [Fix.source]])
        let stale = try Fix.plan(Fix.stop("e1", "a2"), Fix.stop("e1", "a1"),
                                 context: Fix.context(actions: .some(staleSource)))
        #expect(stale.actionSet.planned?.notReady == [
            ActionSetMemberStatus(action: Fix.acts[0], state: .invalidated, reason: .sourceChanged,
                                  staleRequirements: [Fix.source])
        ])
    }

    @Test
    func theTargetChartIsPlannedWhenAvailableAndBlockedWhenMissing() throws {
        let chart = try ChartReference.make(asset: Fix.chartAsset)
        let stale = try ChartReference.make(asset: Fix.staleAsset, page: 2)
        #expect(try Fix.plan(nil, Fix.stop("e1", "a1")).chart == .planned(chart))
        let fallback = try Fix.plan(Fix.stop("e1", "a1"), Fix.stop("e1", "a2"))
        #expect(fallback.chart == .blocked(.unresolvedLink(.chart(stale, .contentUnavailable))))
        #expect(fallback.blocks == [.unresolvedLink(.chart(stale, .contentUnavailable))] && !fallback.isClear)
        #expect(fallback.chart.block?.isRecoverable == true)
        let songChart = try Fix.plan(Fix.stop("e2", "b4"), Fix.stop("e3"))
        #expect(songChart.to.position.part == nil && songChart.chart == .planned(chart))
        let order = try Fix.plan(Fix.stop("e1", "a1"), Fix.stop("e1", "a3"))
        #expect(order.blocks == [.requiresStructuralActivationReview(from: Fix.keys, to: Fix.pad),
                                 .unresolvedLink(.chart(stale, .contentUnavailable))])
    }

    @Test
    func equalInputsGiveEqualPlansNamedByStableReferences() throws {
        let library = try Fix.library()
        let from = try Fix.stop("e1", "a1", in: library)
        let to = try Fix.stop("e1", "a2", in: library)
        let context = try Fix.context()
        let plan = ShowTransitionPlanner.plan(from: from, to: to, in: context)
        #expect(ShowTransitionPlanner.plan(from: from, to: to, in: context) == plan)
        #expect(try Fix.plan(Fix.stop("e1", "a1"), Fix.stop("e1", "a2")) == plan)
        #expect(plan.from == ShowStopReference(from) && plan.to == ShowStopReference(to))
        #expect(plan.from?.position == ShowPosition(setlist: Fix.main, entry: SetlistEntryID(rawValue: "e1")!,
                                                    part: SongPartID(rawValue: "a1")!))
        #expect(plan.to.song == Fix.songA)
        let reordered = try Fix.library(entries: ["e3", "e2", "e1"])
        #expect(try Fix.plan(Fix.stop("e1", "a1", in: reordered), Fix.stop("e1", "a2", in: reordered)) == plan)

        var cursor = try ShowCursor.make(setlist: Fix.main, bounceTicks: 0, sources: [Fix.foot], in: library)
        let catalog = try Fix.catalog()
        let next = ShowNavigationInput(.nextPart, source: Fix.foot, sequence: 1, tick: 0)
        let first = try #require(try cursor.currentStop(in: library, catalog: catalog))
        guard case let .moved(moved) = try cursor.navigate(next, in: library, catalog: catalog) else {
            Issue.record("not moved")
            return
        }
        #expect(ShowTransitionPlanner.plan(from: first, to: moved, in: context) == plan)
        #expect(try cursor.navigate(next, in: library, catalog: catalog) == .ignored(.duplicateSequence(1)))
        let jump = ShowNavigationInput(.jump(SetlistEntryID(rawValue: "e1")!, SongPartID(rawValue: "a2")!),
                                       source: Fix.foot, sequence: 2, tick: 1)
        guard case let .moved(repeated) = try cursor.navigate(jump, in: library, catalog: catalog) else {
            Issue.record("not moved")
            return
        }
        #expect(ShowTransitionPlanner.plan(from: first, to: repeated, in: context) == plan)
    }

    @Test
    func planningAppliesNothingAndChangesNoInput() throws {
        let source = try Fix.actionSource()
        let context = try Fix.context(actions: .some(source))
        let from = try Fix.stop("e1", "a1")
        let to = try Fix.stop("e1", "a2")
        let keys = try #require(context.patchSource(Fix.keys))
        let plan = ShowTransitionPlanner.plan(from: from, to: to, in: context)
        #expect(plan.patch.planned?.changes.isEmpty == false && plan.actionSet.planned != nil)
        #expect(try from == Fix.stop("e1", "a1") && to == Fix.stop("e1", "a2"))
        let after = try #require(context.actionSets)
        #expect(after.readiness.states == source.readiness.states)
        #expect(after.readiness.reasons == source.readiness.reasons)
        #expect(after.readiness.readyEntry(Fix.acts[0]) == 1 && after.readiness.readyEntry(Fix.acts[1]) == 1)
        #expect(after.readiness.state(Fix.acts[2]) == .preparing)
        #expect(after.ledger.generation(Fix.source) == source.ledger.generation(Fix.source))
        #expect(after.ledger.current == source.ledger.current)
        #expect(context.patchSource(Fix.keys)?.patch == keys.patch)
        #expect(context.patchSource(Fix.keys)?.baseline == keys.baseline)
    }

    @Test
    func contextRefusesDuplicateAndExcessPatchSources() throws {
        let keys = try Fix.recallSource(Fix.keys)
        #expect(throws: ShowRefusal.duplicatePatch(Fix.keys)) {
            try ShowTransitionContext.make(patches: [keys, Fix.recallSource(Fix.pad), keys])
        }
        let table = try Fix.table()
        let sources = (0...ShowLimits.maximumCatalogPatches).map {
            ShowPatchRecallSource(patch: ProjectPatch(id: PatchID(rawValue: "p\($0)")!, label: "P",
                                                      graph: GraphID(validated: "graph.main")),
                                  table: table, baseline: .defaults(table))
        }
        let full = try ShowTransitionContext.make(patches: Array(sources.dropLast()))
        #expect(full.patchSource(PatchID(rawValue: "p4095")!) != nil && full.actionSets == nil)
        #expect(throws: ShowRefusal.catalogTooLarge(.patches, 4_097)) {
            try ShowTransitionContext.make(patches: sources)
        }
    }
}
