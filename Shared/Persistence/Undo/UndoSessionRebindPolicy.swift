//
//  UndoSessionRebindPolicy.swift
//  FluxKlang
//
//  Decides what may happen to an undo session's stacks when its document is restored, replaced or cleared. Pure
//  functions over values: nothing is mutated, saved or applied here.
//

/// Plans and confirms undo-session rebinds. No stack survives a rebind: every kind discards the whole undo stack
/// and the whole redo stack, because a history is bound to its base and is never replayed onto another.
///
/// `plan` refuses in this order, first match wins:
/// 1. the reason is not 1...64 UTF-8 bytes;
/// 2. the claimed binding differs from the session's: draft, graph, revision, then content;
/// 3. a `restore`, or a `replace` of a session with unsaved edits, has no checkpoint record, or one whose reason is
///    not `preRestore`, whose revision is not the session's, or whose digest and byte count are not the session's;
/// 4. the target graph differs from the session's, or the target revision is not greater than the session's.
/// A `clear` skips steps 3 and 4. A record supplied when none is needed is not looked at.
///
/// Limits of the record check: it compares the record with the session's bound saved revision and content
/// fingerprint only. The snapshot holds no fingerprint of the unsaved edits, so a matching record passes even though
/// it need not contain them, and the policy cannot show that unsaved edits are kept. A `CheckpointRecord` carries no
/// draft or graph id, so a record of another draft with the same revision and content is accepted; the caller must
/// hand over the record of this draft.
enum UndoSessionRebindPolicy {
    static func plan(
        _ session: UndoSessionSnapshot,
        _ request: UndoRebindRequest
    ) throws(UndoRebindRefusal) -> UndoRebindPlan {
        let reasonBytes = request.reason.utf8.count
        guard UndoRebindRequest.reasonByteRange.contains(reasonBytes) else { throw .reasonBytes(reasonBytes) }
        try requireSameBinding(expected: session.binding, found: request.claimed)
        let newBinding = try reboundBinding(session, request)
        return UndoRebindPlan(
            kind: request.trigger.kind,
            newBinding: newBinding,
            undo: .discarded(count: session.undoCount),
            redo: .discarded(count: session.redoCount),
            redoable: false,
            reason: request.reason,
            ticket: UndoRebindTicket(session: session, request: request)
        )
    }

    /// Re-checks the session against the one the ticket was issued for, then recomputes the plan from the stored
    /// session and request. The binding is compared first (draft, graph, revision, content), then the depth, both
    /// stack counts and the unsaved flag; any difference refuses. Nothing is cached and nothing expires by time.
    static func confirm(
        _ ticket: UndoRebindTicket,
        against session: UndoSessionSnapshot
    ) throws(UndoRebindRefusal) -> UndoRebindPlan {
        let stored = ticket.session
        try requireSameBinding(expected: stored.binding, found: session.binding)
        guard stored.depth == session.depth,
              stored.undoCount == session.undoCount,
              stored.redoCount == session.redoCount,
              stored.hasUnsavedEdits == session.hasUnsavedEdits else {
            throw .staleTicket
        }
        return try plan(stored, ticket.request)
    }

    private static func requireSameBinding(
        expected: UndoSessionBinding,
        found: UndoSessionBinding
    ) throws(UndoRebindRefusal) {
        guard expected.draft == found.draft else {
            throw .draftMismatch(expected: expected.draft, found: found.draft)
        }
        guard expected.graph == found.graph else {
            throw .graphMismatch(expected: expected.graph, found: found.graph)
        }
        guard expected.revision == found.revision else {
            throw .revisionMismatch(expected: expected.revision, found: found.revision)
        }
        guard expected.content.isSameContent(as: found.content) else {
            throw .contentMismatch(expected.revision)
        }
    }

    private static func reboundBinding(
        _ session: UndoSessionSnapshot,
        _ request: UndoRebindRequest
    ) throws(UndoRebindRefusal) -> UndoSessionBinding {
        switch request.trigger {
        case .clear:
            return session.binding
        case .restore(let target):
            try requireCheckpoint(request.preRestore, describing: session.binding)
            return try retargeted(session.binding, to: target)
        case .replace(let target):
            if session.hasUnsavedEdits {
                try requireCheckpoint(request.preRestore, describing: session.binding)
            }
            return try retargeted(session.binding, to: target)
        }
    }

    private static func requireCheckpoint(
        _ record: CheckpointRecord?,
        describing binding: UndoSessionBinding
    ) throws(UndoRebindRefusal) {
        guard let record else { throw .preRestoreMissing }
        switch record.reason {
        case .preRestore:
            break
        case .manual, .autosave, .preMigration:
            throw .preRestoreWrongReason(record.reason)
        }
        guard record.revision == binding.revision else {
            throw .preRestoreRevisionStale(expected: binding.revision, found: record.revision)
        }
        guard binding.content.isSameContent(as: record) else { throw .preRestoreContentStale }
    }

    private static func retargeted(
        _ binding: UndoSessionBinding,
        to target: UndoRebindTarget
    ) throws(UndoRebindRefusal) -> UndoSessionBinding {
        guard target.graph == binding.graph else {
            throw .targetGraphMismatch(expected: binding.graph, found: target.graph)
        }
        guard target.revision > binding.revision else {
            throw .targetNotNewer(session: binding.revision, target: target.revision)
        }
        return UndoSessionBinding(
            draft: binding.draft,
            graph: binding.graph,
            revision: target.revision,
            content: target.content
        )
    }
}
