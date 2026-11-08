//
//  PerformPanelEditor.swift
//  FluxKlang
//
//  Bounded pure edits of a perform panel entry list (#102 PNE1): add, remove, move, regroup and relabel. Each call
//  applies ONE edit and returns the new list with the layout the real `PerformPanelLayout.make` built from it. No view,
//  no gesture, no clock, no hardware.
//

/// Applies one edit to the current entry list.
///
/// Every operation checks, in this order: the entry cap of the INPUT list; the operation's own input; then
/// `PerformPanelLayout.make` (see `PerformPanelEditRefusal`). A target is identified by its `ParameterID`; if the input
/// list holds the same parameter twice, the FIRST occurrence is addressed (the result is still validated, so the layout
/// then refuses what is left). The input array and `context.previous` are values and are never changed, and no entry
/// other than the named one is touched. `.unchanged` is reported only after the layout accepted the list. Work is one
/// scan for the target, one copy and at most one insert and one remove, then the layout; nothing is quadratic here.
enum PerformPanelEditor {
    /// Inserts `entry` so that it ends at `index`, which is `0...entries.count` (`entries.count` appends).
    static func adding(_ entry: PerformPanelEntry, at index: Int, to entries: [PerformPanelEntry],
                       context: PerformPanelEditContext) throws(PerformPanelEditRefusal) -> PerformPanelEdited {
        try checkCap(entries)
        guard index >= 0, index <= entries.count else {
            throw .indexOutOfRange(index: index, largest: entries.count)
        }
        var edited = entries
        edited.insert(entry, at: index)
        return try finish(edited, change: .changed, context: context)
    }

    /// Removes the entry of `parameter`. Removing the last entry gives the empty list, which is a valid panel.
    static func removing(_ parameter: ParameterID, from entries: [PerformPanelEntry],
                         context: PerformPanelEditContext) throws(PerformPanelEditRefusal) -> PerformPanelEdited {
        try checkCap(entries)
        let found = try position(of: parameter, in: entries)
        var edited = entries
        edited.remove(at: found)
        return try finish(edited, change: .changed, context: context)
    }

    /// Moves the entry of `parameter` so that it ends at `index`, which is `0..<entries.count`. The target is checked
    /// before the index. Moving to the current position is `.unchanged`.
    static func moving(_ parameter: ParameterID, to index: Int, in entries: [PerformPanelEntry],
                       context: PerformPanelEditContext) throws(PerformPanelEditRefusal) -> PerformPanelEdited {
        try checkCap(entries)
        let found = try position(of: parameter, in: entries)
        guard index >= 0, index < entries.count else {
            throw .indexOutOfRange(index: index, largest: entries.count - 1)
        }
        guard index != found else { return try finish(entries, change: .unchanged, context: context) }
        var edited = entries
        let moved = edited.remove(at: found)
        edited.insert(moved, at: index)
        return try finish(edited, change: .changed, context: context)
    }

    /// Sets the group of the entry of `parameter`; nil ungroups it. Groups are the same when their utf8 bytes are the
    /// same (nil is the same only as nil), never by `String ==`, so `"\u{E9}"` and `"e\u{301}"` are two groups.
    static func regrouping(_ parameter: ParameterID, to group: String?, in entries: [PerformPanelEntry],
                           context: PerformPanelEditContext) throws(PerformPanelEditRefusal) -> PerformPanelEdited {
        try checkCap(entries)
        let found = try position(of: parameter, in: entries)
        guard !sameGroup(entries[found].group, group) else {
            return try finish(entries, change: .unchanged, context: context)
        }
        var edited = entries
        edited[found].group = group
        return try finish(edited, change: .changed, context: context)
    }

    /// Sets the cell label of the entry of `parameter` and keeps its binding label. Labels are the same when their
    /// utf8 bytes are the same; a label that differs only by canonical equivalence is a different label.
    static func relabeling(_ parameter: ParameterID, to label: String, in entries: [PerformPanelEntry],
                           context: PerformPanelEditContext) throws(PerformPanelEditRefusal) -> PerformPanelEdited {
        try checkCap(entries)
        let found = try position(of: parameter, in: entries)
        guard !entries[found].input.labels.cell.utf8.elementsEqual(label.utf8) else {
            return try finish(entries, change: .unchanged, context: context)
        }
        var edited = entries
        edited[found].input.labels.cell = label
        return try finish(edited, change: .changed, context: context)
    }

    private static func checkCap(_ entries: [PerformPanelEntry]) throws(PerformPanelEditRefusal) {
        guard entries.count <= PerformPanelLimits.maximumEntries else {
            throw .layout(.tooManyEntries(count: entries.count))
        }
    }

    private static func position(of parameter: ParameterID,
                                 in entries: [PerformPanelEntry]) throws(PerformPanelEditRefusal) -> Int {
        guard let found = entries.firstIndex(where: { $0.input.descriptor.fields.id == parameter }) else {
            throw .targetNotFound(parameter)
        }
        return found
    }

    private static func sameGroup(_ current: String?, _ requested: String?) -> Bool {
        switch (current, requested) {
        case (nil, nil): true
        case (nil, .some), (.some, nil): false
        case (.some(let left), .some(let right)): left.utf8.elementsEqual(right.utf8)
        }
    }

    private static func finish(_ edited: [PerformPanelEntry], change: PerformPanelEditChange,
                               context: PerformPanelEditContext) throws(PerformPanelEditRefusal) -> PerformPanelEdited {
        do {
            let layout = try PerformPanelLayout.make(entries: edited, grid: context.grid, width: context.width,
                                                     previous: context.previous)
            return PerformPanelEdited(entries: edited, layout: layout, change: change)
        } catch {
            throw .layout(error)
        }
    }
}
