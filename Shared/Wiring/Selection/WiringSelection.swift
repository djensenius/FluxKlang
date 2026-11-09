//
//  WiringSelection.swift
//  FluxKlang
//
//  One selection over a wiring focus order (#101 WSL1): a step moves it one key press, a reconcile keeps it
//  meaningful after a draft edit. The view owns keys and focus; nothing here is edited, sent or activated.
//

/// One keyboard step over the order. There is no wraparound: a step past either end is `unchanged`.
enum WiringSelectionStep: Hashable, Sendable {
    case next
    case previous
    case first
    case last
    case nextSection
    case previousSection
}

/// What one step did. `moved` is returned only when the selection value changed.
enum WiringSelectionMove: Hashable, Sendable {
    case moved(WiringSelection)
    case unchanged(WiringSelection)
}

/// How a reconcile kept or replaced the selection.
enum WiringSelectionOutcome: Hashable, Sendable {
    /// The target is still in the new order (or there was no selection).
    case unchanged
    /// The target is gone; the nearest later stop of its old section that survives is selected.
    case fellBackToFollowing
    /// No later stop survives; the nearest earlier stop of its old section that survives is selected.
    case fellBackToPreceding
    /// No stop of its old section survives; the first stop of the new order is selected.
    case fellBackToFirst
    /// Nothing is selected: the new order is empty, or the target was in neither order.
    case cleared
}

struct WiringSelectionChange: Hashable, Sendable {
    let selection: WiringSelection
    let outcome: WiringSelectionOutcome
}

/// At most one selected stop. It is a value; the stop need not be in any particular order (a selection kept from
/// an earlier order is treated as no selection by `moving`).
struct WiringSelection: Hashable, Sendable {
    private(set) var current: WiringSelectionTarget?

    private init(current: WiringSelectionTarget?) {
        self.current = current
    }

    static let none = WiringSelection(current: nil)

    /// Selects `target`, or nothing when the order has no such stop.
    static func selecting(_ target: WiringSelectionTarget, in order: WiringSelectionOrder) -> WiringSelection {
        order.position(of: target) != nil ? WiringSelection(current: target) : .none
    }

    /// One step. Never throws. An empty order answers `unchanged(.none)`; a selection that is not in the order moves
    /// as no selection does: `next`, `first` select stop 0; `previous`, `last` the last stop; `nextSection` the first
    /// stop of the first non-empty section; `previousSection` the first stop of the last non-empty section.
    func moving(_ step: WiringSelectionStep, in order: WiringSelectionOrder) -> WiringSelectionMove {
        guard order.count > 0 else { return .unchanged(.none) }
        let position = current.flatMap { order.position(of: $0) }
        guard let destination = Self.destination(of: step, from: position, in: order),
              let target = order.target(at: destination) else { return .unchanged(self) }
        let moved = WiringSelection(current: target)
        return moved == self ? .unchanged(self) : .moved(moved)
    }

    private static func destination(
        of step: WiringSelectionStep, from position: Int?, in order: WiringSelectionOrder
    ) -> Int? {
        let last = order.count - 1
        switch step {
        case .first:
            return 0
        case .last:
            return last
        case .next:
            guard let position else { return 0 }
            return position < last ? position + 1 : nil
        case .previous:
            guard let position else { return last }
            return position > 0 ? position - 1 : nil
        case .nextSection:
            return sectionStart(forward: true, from: position, in: order)
        case .previousSection:
            return sectionStart(forward: false, from: position, in: order)
        }
    }

    /// The first stop of the next (or previous) non-empty section after the one holding `position`; from no
    /// position, of the first (or last) non-empty section.
    private static func sectionStart(forward: Bool, from position: Int?, in order: WiringSelectionOrder) -> Int? {
        var sections = Array(WiringSelectionSection.allCases)
        if !forward { sections.reverse() }
        let origin = position.flatMap { order.target(at: $0) }?.section
        var passed = origin == nil
        for section in sections {
            if !passed {
                passed = section == origin
                continue
            }
            let range = order.range(of: section)
            if !range.isEmpty { return range.lowerBound }
        }
        return nil
    }

    /// The selection after the order changed from `old` to `new`. A target still in `new` is kept. A removed target
    /// falls to the nearest following surviving stop of its OLD section, else the nearest preceding one, else the
    /// first stop of `new`, else nothing. A target that was in neither order is cleared, never moved to the first
    /// stop. Stops that exist only in `new` are never candidates. One scan of the old section, O(1) per stop.
    func reconciled(from old: WiringSelectionOrder, to new: WiringSelectionOrder) -> WiringSelectionChange {
        guard let target = current else { return WiringSelectionChange(selection: self, outcome: .unchanged) }
        if new.position(of: target) != nil { return WiringSelectionChange(selection: self, outcome: .unchanged) }
        guard let oldPosition = old.position(of: target) else {
            return WiringSelectionChange(selection: .none, outcome: .cleared)
        }
        let range = old.range(of: target.section)
        if let stop = Self.survivor(in: old, kept: new, positions: (oldPosition + 1)..<range.upperBound) {
            return WiringSelectionChange(selection: WiringSelection(current: stop), outcome: .fellBackToFollowing)
        }
        if let stop = Self.survivor(in: old, kept: new, positions: range.lowerBound..<oldPosition, reversed: true) {
            return WiringSelectionChange(selection: WiringSelection(current: stop), outcome: .fellBackToPreceding)
        }
        guard let first = new.target(at: 0) else { return WiringSelectionChange(selection: .none, outcome: .cleared) }
        return WiringSelectionChange(selection: WiringSelection(current: first), outcome: .fellBackToFirst)
    }

    /// The first stop of `old` at `positions` (scanned from the far end when `reversed`) that `kept` also has.
    private static func survivor(
        in old: WiringSelectionOrder, kept: WiringSelectionOrder, positions: Range<Int>, reversed: Bool = false
    ) -> WiringSelectionTarget? {
        var position = reversed ? positions.upperBound - 1 : positions.lowerBound
        while position >= positions.lowerBound, position < positions.upperBound {
            if let stop = old.target(at: position), kept.position(of: stop) != nil { return stop }
            position += reversed ? -1 : 1
        }
        return nil
    }

    /// "<label>, <position> of <count>" with a 1-based position, or nil with no selection, a selection the order
    /// lacks, or a target the graph lacks. `graph` is the graph the order was built from.
    func announcement(in order: WiringSelectionOrder, graph: GraphDocument) -> String? {
        guard let target = current, let position = order.position(of: target),
              let text = WiringSelectionOrder.label(of: target, in: graph) else { return nil }
        return "\(text), \(position + 1) of \(order.count)"
    }
}
