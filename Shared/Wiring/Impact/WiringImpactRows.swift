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

    /// Rows only after are `added`, rows only before are `cancelled`, rows on both sides with different content are
    /// `revised`, equal rows are left out. Sorted once by (kind in heading order, ID bytes). A row repeated under
    /// one key on one side counts once (the first); the review diff never repeats one.
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
            if old != change {
                keyed.append(KeyedRow(key: key, row: WiringImpactRow(effect: .revised, change: change, previous: old)))
            }
        }
        for (key, change) in earlier where later[key] == nil {
            keyed.append(KeyedRow(key: key, row: WiringImpactRow(effect: .cancelled, change: change)))
        }
        keyed.sort(by: precedes)
        return keyed.map(\.row)
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
