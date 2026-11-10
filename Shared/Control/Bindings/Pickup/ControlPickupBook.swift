/// One binding of a `ControlPickupBook` and its runtime pickup state.
struct ControlPickupBookEntry: Hashable, Sendable {
    let binding: ControlBinding
    fileprivate(set) var state: PickupState

    fileprivate init(binding: ControlBinding, state: PickupState) {
        self.binding = binding
        self.state = state
    }
}

/// The runtime pickup table of a bounded bank of bindings (#87). It owns the table that the dispatchers take
/// and return, keeps it sorted by the UTF-8 bytes of the binding id, and moves a state only the ways the existing
/// pickup code already defines: `ControlRecord.initialPickupState` and `ControlRecord.hostChanged`, plus the
/// loss and return of a controller. It resolves no input, reads no host truth, writes no parameter and never
/// moves a target; the takeover decision stays in `ControlRecord.resolve`, which the book never calls.
///
/// The book is a plain value: nothing calls it yet, it subscribes to nothing, and `sourceLost` and `sourceSeen`
/// are commands that a future host sends. It allocates (a Dictionary, a Set), so it belongs to the control thread.
struct ControlPickupBook: Hashable, Sendable {
    /// The most bindings one book holds: the cap both dispatchers enforce on a binding list.
    static let maximumBindings = ControlBindingLimit.maximumBindings
    /// The most targets one `hostChanged` call may name: the parameter catalog's own value cap.
    static let maximumChangedTargets = 4096

    /// Sorted by the UTF-8 bytes of the binding id, distinct, at most `maximumBindings`.
    private(set) var entries: [ControlPickupBookEntry]

    init() {
        entries = []
    }

    var count: Int { entries.count }

    /// The table `ControlLocalDispatch.admit` takes. A Dictionary has no order.
    var states: [BindingID: PickupState] {
        var table: [BindingID: PickupState] = [:]
        table.reserveCapacity(entries.count)
        for entry in entries { table[entry.binding.id] = entry.state }
        return table
    }

    /// Bindings that wait to pick up, ascending by id bytes.
    var waitingBindings: [BindingID] {
        var found: [BindingID] = []
        for entry in entries {
            if case .waiting = entry.state { found.append(entry.binding.id) }
        }
        return found
    }

    /// Bindings whose controller was lost, ascending by id bytes.
    var unavailableBindings: [BindingID] {
        var found: [BindingID] = []
        for entry in entries {
            if case .unavailable = entry.state { found.append(entry.binding.id) }
        }
        return found
    }

    func state(of id: BindingID) -> PickupState? {
        let place = slot(of: id)
        guard place.found else { return nil }
        return entries[place.index].state
    }

    /// Adds a binding in its initial state. A repeated id is refused before a full book; nothing is evicted.
    mutating func add(_ binding: ControlBinding) throws(ControlPickupBookRefusal) {
        let place = slot(of: binding.id)
        guard !place.found else { throw .duplicateBinding(binding.id) }
        guard entries.count < Self.maximumBindings else { throw .bookFull(limit: Self.maximumBindings) }
        let entry = ControlPickupBookEntry(binding: binding, state: binding.initialPickupState)
        entries.insert(entry, at: place.index)
    }

    /// Removes a binding. Adding it again restarts it in its initial state, which is how an edited binding enters.
    mutating func remove(_ id: BindingID) throws(ControlPickupBookRefusal) {
        let place = slot(of: id)
        guard place.found else { throw .bindingMissing(id) }
        entries.remove(at: place.index)
    }

    /// Stores the new states a dispatcher reported, all or nothing. The ids are checked in ascending byte order
    /// and the first failure refuses the whole call (see `ControlPickupBookRefusal`).
    mutating func record(_ updates: [BindingID: PickupState]) throws(ControlPickupBookRefusal) {
        guard updates.count <= Self.maximumBindings else { throw .tooManyUpdates(updates.count) }
        let writes = try plannedWrites(updates)
        for write in writes { entries[write.index].state = write.state }
    }

    /// Steps every binding that writes one of `targets` through `ControlRecord.hostChanged` and returns, in
    /// ascending id order, the bindings whose state changed. A target that no binding writes is ignored.
    @discardableResult
    mutating func hostChanged(targets: [ParameterID]) throws(ControlPickupBookRefusal) -> [BindingID] {
        guard targets.count <= Self.maximumChangedTargets else { throw .tooManyTargets(targets.count) }
        return stepEntries(writing: Set(targets))
    }

    /// Marks every binding of the controller unavailable and returns those that were not already, ascending.
    @discardableResult
    mutating func sourceLost(_ source: ControlSourceID) -> [BindingID] {
        var lost: [BindingID] = []
        for index in entries.indices {
            let entry = entries[index]
            guard Self.sameSource(entry.binding.source, source), entry.state != .unavailable else { continue }
            entries[index].state = .unavailable
            lost.append(entry.binding.id)
        }
        return lost
    }

    /// Returns every unavailable binding of the controller to its initial state, ascending. A catch binding
    /// waits for a fresh position; a binding that was not unavailable is left alone.
    @discardableResult
    mutating func sourceSeen(_ source: ControlSourceID) -> [BindingID] {
        var seen: [BindingID] = []
        for index in entries.indices {
            let entry = entries[index]
            guard Self.sameSource(entry.binding.source, source), entry.state == .unavailable else { continue }
            entries[index].state = entry.binding.initialPickupState
            seen.append(entry.binding.id)
        }
        return seen
    }

    private mutating func stepEntries(writing changed: Set<ParameterID>) -> [BindingID] {
        var moved: [BindingID] = []
        for index in entries.indices {
            let entry = entries[index]
            guard changed.contains(entry.binding.target) else { continue }
            let next = entry.binding.hostChanged(entry.state)
            guard next != entry.state else { continue }
            entries[index].state = next
            moved.append(entry.binding.id)
        }
        return moved
    }

    private func plannedWrites(
        _ updates: [BindingID: PickupState]
    ) throws(ControlPickupBookRefusal) -> [(index: Int, state: PickupState)] {
        let ordered = updates.sorted { Self.precedes($0.key, $1.key) }
        var writes: [(index: Int, state: PickupState)] = []
        writes.reserveCapacity(ordered.count)
        for (id, proposed) in ordered {
            let place = slot(of: id)
            guard place.found else { throw .bindingMissing(id) }
            let entry = entries[place.index]
            if proposed != entry.state { try Self.check(id, proposed, against: entry) }
            writes.append((place.index, proposed))
        }
        return writes
    }

    private static func check(
        _ id: BindingID, _ proposed: PickupState, against entry: ControlPickupBookEntry
    ) throws(ControlPickupBookRefusal) {
        guard entry.state != .unavailable else { throw .bindingUnavailable(id) }
        guard isAllowed(proposed, for: entry.binding) else { throw .stateNotAllowed(id) }
    }

    /// Refuses a waiting jump or relative binding, the unavailable state (only `sourceLost` makes one) and a
    /// remembered position outside 0...1.
    private static func isAllowed(_ state: PickupState, for binding: ControlBinding) -> Bool {
        switch state {
        case .unavailable:
            return false
        case .engaged(let hardware):
            return isValidPosition(hardware)
        case .waiting(let hardware):
            guard binding.pickup == .catch else { return false }
            return isValidPosition(hardware)
        }
    }

    /// NaN and the infinities lie outside the closed range, so no separate finiteness test is needed.
    private static func isValidPosition(_ value: Double?) -> Bool {
        guard let value else { return true }
        return (0...1).contains(value)
    }

    private func slot(of id: BindingID) -> (index: Int, found: Bool) {
        var low = 0
        var high = entries.count
        while low < high {
            let middle = low + (high - low) / 2
            let probe = entries[middle].binding.id
            if Self.precedes(probe, id) {
                low = middle + 1
            } else if Self.sameBytes(probe, id) {
                return (middle, true)
            } else {
                high = middle
            }
        }
        return (low, false)
    }

    private static func precedes(_ lhs: BindingID, _ rhs: BindingID) -> Bool {
        lhs.rawValue.utf8.lexicographicallyPrecedes(rhs.rawValue.utf8)
    }

    private static func sameBytes(_ lhs: BindingID, _ rhs: BindingID) -> Bool {
        lhs.rawValue.utf8.elementsEqual(rhs.rawValue.utf8)
    }

    private static func sameSource(_ lhs: ControlSourceID, _ rhs: ControlSourceID) -> Bool {
        lhs.rawValue.utf8.elementsEqual(rhs.rawValue.utf8)
    }
}
