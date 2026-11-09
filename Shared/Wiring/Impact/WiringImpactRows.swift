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
    /// positions. Those are compared NaN-stably (`==` or both NaN, so +0.0 equals -0.0). The removed-node,
    /// added-edge and removed-edge arms return true without comparing content for that reason: a gesture that ever
    /// rewrites such a record under one key must also be compared here.
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

    /// Compares two optional extension bags through `sameValue`; nil equals only nil.
    private static func sameBag(_ first: [String: JSONValue]?, _ second: [String: JSONValue]?) -> Bool {
        guard let first, let second else { return first == nil && second == nil }
        return sameValue(.object(first), .object(second))
    }

    /// NaN-stable equality of two JSON values: doubles by `sameNumber` (in `sameLeaf`), arrays by count then
    /// element by element, objects by count then key by key, any other pair by `==`. It walks an explicit stack
    /// of pairs, because a value built in memory has no nesting limit (only a decoded one is held to 512 levels)
    /// and recursion could exhaust the call stack. `DraftEditFold.nonFiniteNumber(in:)` walks an explicit stack
    /// for the same reason. Each pair is visited once. This hardens this comparator alone: `JSONValue`'s own `==`
    /// and `hash(into:)`, and releasing a very deep value, still recurse.
    private static func sameValue(_ first: JSONValue, _ second: JSONValue) -> Bool {
        var pending: [(JSONValue, JSONValue)] = [(first, second)]
        while let (left, right) = pending.popLast() {
            switch (left, right) {
            case (.array(let lhs), .array(let rhs)):
                guard lhs.count == rhs.count else { return false }
                pending.append(contentsOf: zip(lhs, rhs).map { ($0, $1) })
            case (.object(let lhs), .object(let rhs)):
                guard lhs.count == rhs.count else { return false }
                for (key, value) in lhs {
                    guard let other = rhs[key] else { return false }
                    pending.append((value, other))
                }
            case _:
                if !sameLeaf(left, right) { return false }
            }
        }
        return true
    }

    private static func sameLeaf(_ first: JSONValue, _ second: JSONValue) -> Bool {
        if case .double(let lhs) = first, case .double(let rhs) = second { return sameNumber(lhs, rhs) }
        return first == second
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
