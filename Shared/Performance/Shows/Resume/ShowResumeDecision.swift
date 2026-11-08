//
//  ShowResumeDecision.swift
//  FluxKlang
//
//  What the show may do with a saved position after a relaunch or a library edit (#106).
//  A decision is a value: nothing here moves a cursor. Only `exact` may be applied without the operator;
//  a `confirm` is applied through its `jump` after the operator accepts it, and a `blocked` has no jump.
//

/// Why a proposal differs from the saved position. Where there is a payload, it is the saved ID that no longer
/// resolves.
enum ShowResumeBasis: Equatable, Sendable {
    /// The saved part is not in the song (or the song has no parts at all).
    case partMissing(SongPartID)
    /// The saved position had no part and the song now has parts.
    case partsAdded
    /// The saved entry is gone; its next neighbour is proposed.
    case entryMissingNext(SetlistEntryID)
    /// The saved entry and its next neighbour are gone; its previous neighbour is proposed.
    case entryMissingPrevious(SetlistEntryID)
    /// The saved entry and both neighbours are gone; the entry at the saved index, clamped to the last, is proposed.
    case entryMissingOrdinal(SetlistEntryID)
}

/// Why nothing can be resumed.
enum ShowResumeBlock: Equatable, Sendable {
    case setlistRemoved(SetlistID)
    case setlistEmpty(SetlistID)
    /// The saved entry exists but plays another song than the point recorded, or the library has no such song.
    case songChanged(SetlistEntryID)
}

/// A nearby target for the operator to confirm. `target` is where `jump` lands on a cursor made on `target.setlist`
/// (a cursor applies a jump to its own setlist). The planner makes `jump` and `target` agree; a hand-built value
/// need not.
struct ShowResumeProposal: Equatable, Sendable {
    let target: ShowPosition
    let jump: ShowNavigationCommand
    let basis: ShowResumeBasis
}

enum ShowResumeDecision: Equatable, Sendable {
    /// The saved target still exists and means the same thing; `jump` lands at `target` on a cursor made on
    /// `target.setlist`.
    case exact(target: ShowPosition, jump: ShowNavigationCommand)
    case confirm(ShowResumeProposal)
    case blocked(ShowResumeBlock)

    /// False only for `exact`.
    var needsOperator: Bool {
        switch self {
        case .exact: false
        case .confirm, .blocked: true
        }
    }

    /// The command a cursor accepts to take this decision; `nil` for `blocked`.
    var jumpCommand: ShowNavigationCommand? {
        switch self {
        case let .exact(_, jump): jump
        case let .confirm(proposal): proposal.jump
        case .blocked: nil
        }
    }

    /// Where the jump lands; `nil` for `blocked`.
    var target: ShowPosition? {
        switch self {
        case let .exact(target, _): target
        case let .confirm(proposal): proposal.target
        case .blocked: nil
        }
    }
}

/// A point that cannot be captured or is not well formed. A refusal yields no decision.
enum ShowResumeRefusal: Error, Equatable, Sendable {
    case cursorNotPositioned
    case cursorNotCurrent(ShowCursorStatus)
    case ordinalOutOfRange(Int)
    /// The previous or the next entry is the saved entry itself.
    case neighbourIsEntry
    /// The previous and the next entry are the same entry.
    case neighboursEqual
}
