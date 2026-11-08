//
//  ShowStageResume.swift
//  FluxKlang
//
//  What the stage display offers for a saved resume point (#106 SRW1). It only offers: nothing here moves a cursor,
//  stores a point or applies the jump. The caller applies `jump` with `ShowCursor.navigate` after the performer
//  accepts, an exact plan included.
//

struct ShowStageResumeOffer: Hashable, Sendable {
    /// The target, built like any other stage line.
    let line: ShowStageLine
    /// The decision's own jump; applied only after the performer accepts.
    let jump: ShowNavigationCommand
    /// `nil` for an exact plan: the saved target still exists unchanged.
    let basis: ShowResumeBasis?
}

enum ShowStageResume: Hashable, Sendable {
    case offer(ShowStageResumeOffer)
    case blocked(ShowResumeBlock)
    /// The planner refused the point; the refusal detail is not kept.
    case invalidPoint

    /// Checks run in this order and the first that applies decides:
    /// 1. no point: `nil`.
    /// 2. the point is for another setlist than the cursor's: `nil`.
    /// 3. the planner refuses the point: `.invalidPoint`.
    /// 4. the plan is blocked: `.blocked`, whatever the cursor state.
    /// 5. the plan's target is the cursor's whole position: `nil`.
    /// 6. otherwise `.offer`.
    static func make(point: ShowResumePoint?, cursor: ShowCursor, library: ShowLibrary,
                     catalog: ShowLinkCatalog) throws(ShowRefusal) -> ShowStageResume? {
        guard let point, point.setlist == cursor.setlist else { return nil }
        let decision: ShowResumeDecision
        do {
            decision = try ShowResumePlanner.plan(point, in: library)
        } catch {
            return .invalidPoint
        }
        switch decision {
        case let .blocked(block):
            return .blocked(block)
        case let .exact(target, jump):
            let aim = Aim(target: target, jump: jump, basis: nil)
            return try offer(aim, cursor: cursor, library: library, catalog: catalog)
        case let .confirm(proposal):
            let aim = Aim(target: proposal.target, jump: proposal.jump, basis: proposal.basis)
            return try offer(aim, cursor: cursor, library: library, catalog: catalog)
        }
    }

    private struct Aim {
        let target: ShowPosition
        let jump: ShowNavigationCommand
        let basis: ShowResumeBasis?
    }

    /// The `.unknownEntry` throw below is unreachable by construction: the planner resolved the setlist in this same
    /// library. If `ShowStageLine.init` throws any refusal, it propagates out of `make`, so the whole projection is
    /// dropped and the refusal is not turned into `.invalidPoint`.
    private static func offer(_ aim: Aim, cursor: ShowCursor, library: ShowLibrary,
                              catalog: ShowLinkCatalog) throws(ShowRefusal) -> ShowStageResume? {
        let target = aim.target
        guard target != cursor.position else { return nil }
        guard let setlist = library.setlist(target.setlist) else { throw .unknownEntry(target.entry) }
        let line = try ShowStageLine(at: target, current: cursor.position?.entry, in: setlist, library: library,
                                     catalog: catalog)
        return .offer(ShowStageResumeOffer(line: line, jump: aim.jump, basis: aim.basis))
    }
}
