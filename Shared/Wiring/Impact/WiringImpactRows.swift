//
//  WiringImpactRows.swift
//  FluxKlang
//
//  The review rows one gesture adds, cancels or revises (#101 WPV1). The two review diffs are keyed once each by
//  (kind, sortID bytes) and compared by key, so no step scans rows against rows.
//

/// What a gesture does to one review row of the draft.
enum WiringImpactEffect: Int, Hashable, Sendable {
    /// The row is new: the gesture adds it.
    case added
    /// The row existed and the gesture removes it (a restore, a move back to the base position, a removed draft add).
    case cancelled
    /// The row exists before and after with different content; `previous` is the earlier row.
    case revised
}

/// One changed review row. Built only by `WiringImpactRowDelta.rows(before:after:)`.
struct WiringImpactRow: Hashable, Sendable {
    let effect: WiringImpactEffect
    /// The row as it reads after the gesture (`added`, `revised`) or as it read before it (`cancelled`).
    let change: WiringReviewChange
    /// The row as it read before the gesture; non-nil only for `revised`.
    let previous: WiringReviewChange?

    fileprivate init(effect: WiringImpactEffect, change: WiringReviewChange, previous: WiringReviewChange? = nil) {
        self.effect = effect
        self.change = change
        self.previous = previous
    }
}

/// The row delta between the review rows before and after a gesture.
enum WiringImpactRowDelta {
    private struct RowKey: Hashable {
        let kind: WiringReviewChangeKind
        let id: [UInt8]
    }

    private struct KeyedRow {
        let key: RowKey
        let row: WiringImpactRow
    }

    /// Rows only after are `added`, rows only before are `cancelled`, rows on both sides whose changeable content
    /// differs are `revised`, the others are left out. Sorted once by (kind in heading order, ID bytes). A row
    /// repeated under one key on one side counts once (the first); the review diff never repeats one. The review
    /// rows are not compared with `==`: a NaN in a node, an edge or a position makes a row unequal to itself, so the
    /// same row on both sides would read as revised (see `isUnchanged`).
    static func rows(before: [WiringReviewChange], after: [WiringReviewChange]) -> [WiringImpactRow] {
        let earlier = indexed(before)
        let later = indexed(after)
        var keyed: [KeyedRow] = []
        keyed.reserveCapacity(earlier.count + later.count)
        for (key, change) in later {
            guard let old = earlier[key] else {
                keyed.append(KeyedRow(key: key, row: WiringImpactRow(effect: .added, change: change)))
                continue
            }
            if !isUnchanged(old, change) {
                keyed.append(KeyedRow(key: key, row: WiringImpactRow(effect: .revised, change: change, previous: old)))
            }
        }
        for (key, change) in earlier where later[key] == nil {
            keyed.append(KeyedRow(key: key, row: WiringImpactRow(effect: .cancelled, change: change)))
        }
        keyed.sort(by: precedes)
        return keyed.map(\.row)
    }

    /// Whether two rows under one key are the same row. Invariant of the review diff: both diffs are built from the
    /// fixed active graph and one draft, and a gesture changes only node positions, so removed rows and added edge
    /// rows under one key are the same record on both sides, and an added or moved node row differs only by its
    /// positions. Those are compared NaN-stably (`==` or both NaN, so +0.0 equals -0.0).
    private static func isUnchanged(_ old: WiringReviewChange, _ new: WiringReviewChange) -> Bool {
        switch (old, new) {
        case (.addedNode(let first), .addedNode(let second)):
            return sameNumbers(first.position, second.position)
        case (.movedNode(_, let oldFrom, let oldTo), .movedNode(_, let newFrom, let newTo)):
            return sameNumbers(oldFrom, newFrom) && sameNumbers(oldTo, newTo)
        case (.removedNode, .removedNode), (.addedEdge, .addedEdge), (.removedEdge, .removedEdge):
            return true
        case _:
            return false
        }
    }

    private static func sameNumbers(_ first: GraphPoint?, _ second: GraphPoint?) -> Bool {
        guard let first, let second else { return first == nil && second == nil }
        return sameNumber(first.x, second.x) && sameNumber(first.y, second.y)
            && sameBag(first.extensions, second.extensions) && sameBag(first.unknownFields, second.unknownFields)
    }

    private static func sameNumber(_ first: Double, _ second: Double) -> Bool {
        first == second || (first.isNaN && second.isNaN)
    }

    private static func sameBag(_ first: [String: JSONValue]?, _ second: [String: JSONValue]?) -> Bool {
        guard let first, let second else { return first == nil && second == nil }
        guard first.count == second.count else { return false }
        return first.allSatisfy { key, value in second[key].map { sameValue(value, $0) } ?? false }
    }

    private static func sameValue(_ first: JSONValue, _ second: JSONValue) -> Bool {
        switch (first, second) {
        case (.double(let left), .double(let right)):
            return sameNumber(left, right)
        case (.array(let left), .array(let right)):
            return left.count == right.count && zip(left, right).allSatisfy { sameValue($0, $1) }
        case (.object(let left), .object(let right)):
            return sameBag(left, right)
        case _:
            return first == second
        }
    }

    private static func indexed(_ changes: [WiringReviewChange]) -> [RowKey: WiringReviewChange] {
        var byKey: [RowKey: WiringReviewChange] = [:]
        byKey.reserveCapacity(changes.count)
        for change in changes {
            let key = RowKey(kind: change.kind, id: Array(change.sortID.utf8))
            if byKey[key] == nil { byKey[key] = change }
        }
        return byKey
    }

    private static func precedes(_ first: KeyedRow, _ second: KeyedRow) -> Bool {
        if first.key.kind.rawValue != second.key.kind.rawValue {
            return first.key.kind.rawValue < second.key.kind.rawValue
        }
        return first.key.id.lexicographicallyPrecedes(second.key.id)
    }
}
