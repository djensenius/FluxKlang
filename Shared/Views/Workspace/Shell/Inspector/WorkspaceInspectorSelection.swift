//
//  WorkspaceInspectorSelection.swift
//  FluxKlang
//
//  What the workspace inspector's header says about the window's selection (#99 INS1): the empty prompt, one
//  item's title and state, or a count for a multiple selection ("Removed in rev N" and "Not in active rev N"
//  included). Graph items only. `draftOnly` and `activeRevision` are caller inputs. Nothing calls it yet.
//

enum WorkspaceInspectorContent: Equatable, Sendable {
    case empty
    case single(WorkspaceInspectorRow)
    case multiple([WorkspaceInspectorRow])
}

struct WorkspaceInspectorSelection: Equatable, Sendable {
    let content: WorkspaceInspectorContent

    private init(content: WorkspaceInspectorContent) {
        self.content = content
    }

    /// Rows in selection order; empty for `.empty`.
    var rows: [WorkspaceInspectorRow] {
        switch content {
        case .empty: []
        case let .single(row): [row]
        case let .multiple(rows): rows
        }
    }

    var headline: String {
        switch content {
        case .empty: WorkspaceInspectorText.emptyPrompt
        case let .single(row): row.title
        case let .multiple(rows): WorkspaceInspectorText.count(rows.count)
        }
    }

    var announcement: String {
        switch content {
        case .empty: WorkspaceInspectorText.emptyPrompt
        case let .single(row): row.accessibilityLabel
        case let .multiple(rows): WorkspaceInspectorText.count(rows.count)
        }
    }

    /// `draftOnly` holds the items that exist in the draft but not in the active revision; `activeRevision` is the
    /// number "Not in active rev N" names. A removed entry stays removed even when its item is in `draftOnly`.
    static func make(
        selection: [WorkspaceSelectionEntry],
        draftOnly: Set<WorkspaceItemRef>,
        activeRevision: ContractRevision?
    ) throws(WorkspaceInspectorRefusal) -> WorkspaceInspectorSelection {
        let maximum = WorkspaceNavigationState.maxSelection
        guard selection.count <= maximum else { throw .selectionLimitExceeded(maximum: maximum) }

        var seen = Set<WorkspaceItemRef>()
        for entry in selection where !seen.insert(entry.item).inserted {
            throw .duplicateSelectionItem(entry.item)
        }

        var rows: [WorkspaceInspectorRow] = []
        rows.reserveCapacity(selection.count)
        for entry in selection {
            switch entry {
            case let .removed(item, revision):
                rows.append(WorkspaceInspectorRow(item: item, state: .removed(revision: revision)))
            case let .live(item) where draftOnly.contains(item):
                guard let activeRevision else { throw .draftItemWithoutActiveRevision(item) }
                rows.append(WorkspaceInspectorRow(item: item, state: .draftOnly(activeRevision: activeRevision)))
            case let .live(item):
                rows.append(WorkspaceInspectorRow(item: item, state: .active))
            }
        }

        switch rows.count {
        case 0: return WorkspaceInspectorSelection(content: .empty)
        case 1: return WorkspaceInspectorSelection(content: .single(rows[0]))
        default: return WorkspaceInspectorSelection(content: .multiple(rows))
        }
    }
}
