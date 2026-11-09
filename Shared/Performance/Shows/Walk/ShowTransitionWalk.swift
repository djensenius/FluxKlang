//
//  ShowTransitionWalk.swift
//  FluxKlang
//
//  Walks one setlist front to back with a private real `ShowCursor` and plans the opening stop and each consecutive
//  stop pair with the SH2 planner (#106 STW1). It judges nothing: it plays, arms and recalls nothing and reads no
//  time source. It belongs to the control thread and pre-show work: it allocates, and the planner may decode
//  variation JSON on a run. No production code calls it yet.
//

enum ShowTransitionWalk {
    /// The stop cap: 256 entries x 8 parts. A setlist over it is refused whole, not truncated. The contract maximum
    /// is 256 x 64 = 16_384 stops.
    static let maximumStops = 2_048
    private static let source = ShowInputSourceID(validated: "src.walk")

    /// One row per stop of the setlist: row 0 is the opening stop (no predecessor) and each later row the stop a
    /// `.nextPart` press reaches. `startingWith` is the patch assumed loaded before the opening stop. Pass `nil` when
    /// nothing is known to be loaded: a linked patch then needs a structural activation review, which loads nothing,
    /// so no row of that walk has a loaded patch. The stop count is checked before any cursor or planner work.
    static func digest(of id: SetlistID, in library: ShowLibrary, catalog: ShowLinkCatalog,
                       context: ShowTransitionContext,
                       startingWith loaded: ShowActivePatch?) throws(ShowTransitionWalkRefusal)
        -> ShowTransitionWalkDigest {
        guard let setlist = library.setlist(id) else { throw .unknownSetlist(id) }
        let count = stopCount(of: setlist, in: library)
        guard count <= maximumStops else { throw .tooManyStops(count) }
        guard count > 0 else { return ShowTransitionWalkDigest(setlist: id, rows: [], plannerRuns: 0) }
        var cursor = try makeCursor(id, in: library)
        var walk = ShowTransitionWalkState(context: context, loaded: loaded)
        walk.rows.reserveCapacity(count)
        let first = try opening(cursor, id: id, in: library, catalog: catalog)
        walk.record(first)
        for step in 1..<count {
            let stop = try advance(&cursor, step: step, in: library, catalog: catalog)
            walk.record(stop)
        }
        return ShowTransitionWalkDigest(setlist: id, rows: walk.rows, plannerRuns: walk.runs)
    }

    /// The stops the presses reach: one per part of a song with parts, one for a song without parts.
    private static func stopCount(of setlist: ShowSetlist, in library: ShowLibrary) -> Int {
        var perSong: [SongID: Int] = [:]
        perSong.reserveCapacity(library.songs.count)
        for song in library.songs { perSong[song.id] = max(1, song.parts.count) }
        var total = 0
        for entry in setlist.entries { total += perSong[entry.song] ?? 1 }
        return total
    }

    private static func makeCursor(_ id: SetlistID, in library: ShowLibrary) throws(ShowTransitionWalkRefusal)
        -> ShowCursor {
        do throws(ShowRefusal) {
            return try ShowCursor.make(setlist: id, bounceTicks: 0, sources: [source], in: library)
        } catch {
            throw .showRefused(error)
        }
    }

    private static func opening(_ cursor: ShowCursor, id: SetlistID, in library: ShowLibrary,
                                catalog: ShowLinkCatalog) throws(ShowTransitionWalkRefusal) -> ShowStop {
        do throws(ShowRefusal) {
            guard let stop = try cursor.currentStop(in: library, catalog: catalog) else {
                throw ShowRefusal.emptySetlist(id)
            }
            return stop
        } catch {
            throw .showRefused(error)
        }
    }

    /// Press `step` is its own sequence number (1, 2, ...), so no press repeats one; tick 0 with a zero bounce window
    /// leaves nothing to bounce.
    private static func advance(_ cursor: inout ShowCursor, step: Int, in library: ShowLibrary,
                                catalog: ShowLinkCatalog) throws(ShowTransitionWalkRefusal) -> ShowStop {
        let press = ShowNavigationInput(.nextPart, source: source, sequence: UInt64(step), tick: 0)
        let result: ShowNavigationResult
        do throws(ShowRefusal) {
            result = try cursor.navigate(press, in: library, catalog: catalog)
        } catch {
            throw .showRefused(error)
        }
        switch result {
        case let .moved(stop): return stop
        case let .ignored(reason): throw .inputIgnored(reason)
        }
    }
}

/// The rows so far, the patch assumed loaded, and a memo from (links, loaded patch) to the planner's outcome. The
/// planner reads the target's links, the loaded patch and the constant context, so a repeated key reuses the
/// outcome. The memo is a lookup table and is not iterated.
private struct ShowTransitionWalkState {
    struct Key: Hashable {
        let links: ShowResolvedLinks
        let active: ShowActivePatch?
    }

    struct Outcome {
        let blocks: [ShowTransitionBlock]
        let next: ShowActivePatch?
    }

    let context: ShowTransitionContext
    var loaded: ShowActivePatch?
    var previous: ShowStop?
    var rows: [ShowTransitionWalkRow] = []
    var memo: [Key: Outcome] = [:]
    var runs = 0

    mutating func record(_ stop: ShowStop) {
        let before = loaded
        let result = outcome(for: stop, active: before)
        rows.append(ShowTransitionWalkRow(from: previous.map { ShowStopReference($0) },
                                          to: ShowStopReference(stop), loaded: before, blocks: result.blocks))
        loaded = result.next
        previous = stop
    }

    private mutating func outcome(for stop: ShowStop, active: ShowActivePatch?) -> Outcome {
        let key = Key(links: stop.links, active: active)
        if let cached = memo[key] { return cached }
        let plan = ShowTransitionPlanner.plan(from: previous, to: stop, active: active, in: context)
        let made = Outcome(blocks: plan.blocks, next: Self.next(after: plan, keeping: active))
        memo[key] = made
        runs += 1
        return made
    }

    /// A planned recall changes the loaded patch; a blocked or unlinked patch step leaves it as it was.
    private static func next(after plan: ShowTransitionPlan, keeping active: ShowActivePatch?) -> ShowActivePatch? {
        guard let recall = plan.patch.planned else { return active }
        return ShowActivePatch(patch: recall.patch, variation: recall.to)
    }
}
