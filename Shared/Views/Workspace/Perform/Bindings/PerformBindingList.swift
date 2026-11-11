//
//  PerformBindingList.swift
//  FluxKlang
//
//  The perform "Bindings..." list as a value (#102 PBL1): one row per binding of a pickup book, with its control,
//  device and presence, target, group, pickup mode and state and controller feedback, and the one text that both the
//  row and a cell's "Show binding" action read. No view, device, clock or I/O. A row holds no hardware position and
//  no signal, so moving a fader can change only the pickup state it shows. Nothing calls it yet.
//

/// One binding as the list shows it. Built only by `PerformBindingList.make`; storage is `let`.
struct PerformBindingRow: Hashable, Sendable {
    let binding: BindingID
    let source: ControlSourceID
    /// The caller's label for the source, or the source id itself when the caller gives none.
    let control: String
    /// The origin of a canonical MIDI source id; nil when the source id is not one (presence `unjudged`).
    let device: ControlSourceOrigin?
    let presence: PerformBindingPresence
    let target: ParameterID
    /// The one binding group whose members include this binding, or nil.
    let group: BindingGroupID?
    /// Nil for a relative binding, which carries no mode and never waits.
    let pickupMode: PickupMode?
    let pickupStatus: PerformBindingPickupStatus
    let feedback: PerformBindingFeedback
    /// The one text of the row; a cell's "Show binding" action reads it unchanged. Five parts joined by ". ":
    /// "<control> on <device token, or unknown device>: <presence>", "Target <target id>", "Group <group id>" or
    /// "No group", "<pickup mode>: <pickup state>", and the feedback words.
    let showBindingText: String

    fileprivate init(
        entry: ControlPickupBookEntry, status: ControlSourceAvailabilityStatus, group: BindingGroupID?,
        control: String, feedbackDialects: [ControlSourceOrigin: ControlIntakeDialect]
    ) {
        let bound = entry.binding
        let device = try? ControlFeedbackMIDI1SourceParser.parse(bound.source).origin
        let presence = Self.presence(of: entry.state, status: status)
        let pickupStatus = Self.pickupStatus(of: entry.state, presence: presence)
        let feedback = Self.feedback(of: bound, device: device, presence: presence, dialects: feedbackDialects)
        let mode = bound.pickup?.performText ?? PerformBindingPickupStatus.relativeModeText
        binding = bound.id
        source = bound.source
        self.control = control
        self.device = device
        self.presence = presence
        target = bound.target
        self.group = group
        pickupMode = bound.pickup
        self.pickupStatus = pickupStatus
        self.feedback = feedback
        showBindingText = [
            "\(control) on \(device?.token ?? "unknown device"): \(presence.rawValue)",
            "Target \(bound.target.rawValue)",
            group.map { "Group \($0.rawValue)" } ?? "No group",
            "\(mode): \(pickupStatus.rawValue)",
            feedback.rawValue
        ].joined(separator: ". ")
    }

    /// Rows with a group come first, ascending by group id bytes, and rows with no group follow. Ties go by control
    /// text bytes, then by binding id bytes. Binding ids are distinct in a book, so the order is total. Every
    /// comparison is on UTF-8 bytes, never `String` order, which treats canonically equivalent text as equal.
    fileprivate static func precedes(_ lhs: Self, _ rhs: Self) -> Bool {
        switch (lhs.group, rhs.group) {
        case (.some, .none):
            return true
        case (.none, .some):
            return false
        case (.some(let left), .some(let right)) where !left.rawValue.sameBytes(right.rawValue):
            return left.rawValue.bytesPrecede(right.rawValue)
        case (.some, .some), (.none, .none):
            break
        }
        if !lhs.control.sameBytes(rhs.control) { return lhs.control.bytesPrecede(rhs.control) }
        return lhs.binding.rawValue.bytesPrecede(rhs.binding.rawValue)
    }

    /// Stale when the book holds the binding unavailable, whatever the report says, or when the report says the
    /// origin is absent. Otherwise the report decides.
    private static func presence(
        of state: PickupState, status: ControlSourceAvailabilityStatus
    ) -> PerformBindingPresence {
        guard state != .unavailable else { return .stale }
        switch status {
        case .available: return .live
        case .sourceAbsent: return .stale
        case .notMIDISource, .malformedSource: return .unjudged
        }
    }

    /// A stale row reads `unavailable` even while the book still holds engaged or waiting (the report says
    /// `sourceAbsent` before the host calls `sourceLost`). This is deliberately conservative; see
    /// `PerformBindingPickupStatus`.
    private static func pickupStatus(
        of state: PickupState, presence: PerformBindingPresence
    ) -> PerformBindingPickupStatus {
        guard presence != .stale else { return .unavailable }
        switch state {
        case .engaged: return .engaged
        case .waiting: return .waiting
        case .unavailable: return .unavailable
        }
    }

    private static func feedback(
        of binding: ControlBinding, device: ControlSourceOrigin?, presence: PerformBindingPresence,
        dialects: [ControlSourceOrigin: ControlIntakeDialect]
    ) -> PerformBindingFeedback {
        guard presence != .stale else { return .controllerStale }
        guard presence == .live, let device, let dialect = dialects[device], encodes(binding, dialect: dialect) else {
            return .unsupportedByDevice
        }
        return .sends
    }

    /// Whether the MIDI 1 feedback encoder, the only path that turns feedback into bytes, can address this control
    /// under `dialect`. The probe position 0 always gives step 0, so the answer depends on the source, the profile and
    /// the dialect only.
    private static func encodes(_ binding: ControlBinding, dialect: ControlIntakeDialect) -> Bool {
        do {
            let probe = try ControlFeedbackMessage(
                binding: binding.id, source: binding.source, position: 0, reason: .refresh
            )
            _ = try ControlFeedbackMIDI1Encoder.encode(probe, profile: binding.profile, dialect: dialect)
            return true
        } catch {
            return false
        }
    }
}

/// The perform "Bindings..." list: one row per binding of the caller's pickup book, none dropped or merged, in the
/// order of `PerformBindingRow.precedes`. At most `ControlPickupBook.maximumBindings` rows, the book's own bound.
/// Built only by `make`; storage is `let`.
struct PerformBindingList: Hashable, Sendable {
    /// A group has at least one member and a binding sits in at most one group, so no valid call names more groups
    /// than a book holds bindings.
    static let maximumGroups = ControlBindingLimit.maximumBindings
    /// UTF-8 bytes of a caller's control label: not empty, and no longer than a perform cell's binding label.
    static let controlLabelBytes = 1...PerformCellLimits.bindingLabelBytes.upperBound

    let rows: [PerformBindingRow]

    private init(rows: [PerformBindingRow]) {
        self.rows = rows
    }

    /// The row of `binding`, or nil when the book holds no such binding. A cell's "Show binding" action reads its
    /// `showBindingText`. O(rows).
    func row(for binding: BindingID) -> PerformBindingRow? {
        rows.first { $0.binding.rawValue.sameBytes(binding.rawValue) }
    }

    /// Builds the list, or throws the first failing check in the order of `PerformBindingListRefusal`.
    ///
    /// - `book`: the runtime pickup table the dispatchers use. Its bindings are the rows and its states the pickup
    ///   states, except that a stale row shows `unavailable`.
    /// - `groups`: the binding groups. A row's group is the one group that names its binding.
    /// - `availability`: `ControlSourceAvailability.project` of the book's bindings and the caller's live origins. It
    ///   must list exactly the book's bindings, with the same sources.
    /// - `feedbackDialects`: the origins the caller knows accept controller feedback, each with the dialect its intake
    ///   reads. Device feedback capability is modelled nowhere else, so it is never assumed: an origin that is not
    ///   listed reads "Unsupported by device". Only the origins of the book's sources are read.
    /// - `controlLabels`: the caller's labels by source, for example "Knob 1". A source with no label shows its id.
    ///   Only the labels of the book's sources are read and checked; any other entry is ignored.
    static func make(
        book: ControlPickupBook,
        groups: [ControlBindingGroup],
        availability: ControlSourceAvailabilityReport,
        feedbackDialects: [ControlSourceOrigin: ControlIntakeDialect],
        controlLabels: [ControlSourceID: String]
    ) throws(PerformBindingListRefusal) -> Self {
        guard groups.count <= maximumGroups else { throw .tooManyGroups(groups.count) }
        let entries = book.entries
        let judged = availability.entries
        try requireMatch(entries, judged)
        let owners = try Self.owners(of: groups, in: book)
        var rows: [PerformBindingRow] = []
        rows.reserveCapacity(entries.count)
        for (entry, report) in zip(entries, judged) {
            let control = try Self.control(of: entry.binding.source, labels: controlLabels)
            rows.append(PerformBindingRow(
                entry: entry, status: report.status, group: owners[entry.binding.id], control: control,
                feedbackDialects: feedbackDialects
            ))
        }
        rows.sort(by: PerformBindingRow.precedes)
        return Self(rows: rows)
    }

    /// Both lists are ascending by binding id bytes, so they match position by position.
    private static func requireMatch(
        _ entries: [ControlPickupBookEntry], _ report: [ControlSourceAvailabilityEntry]
    ) throws(PerformBindingListRefusal) {
        guard entries.count == report.count else {
            throw .availabilityCountMismatch(book: entries.count, report: report.count)
        }
        for (entry, judged) in zip(entries, report)
        where !entry.binding.id.rawValue.sameBytes(judged.binding.rawValue)
            || !entry.binding.source.rawValue.sameBytes(judged.source.rawValue) {
            throw .availabilityMismatch(entry.binding.id)
        }
    }

    /// The group of each grouped binding. Groups are walked ascending by id bytes; a repeated id sits next to its twin.
    private static func owners(
        of groups: [ControlBindingGroup], in book: ControlPickupBook
    ) throws(PerformBindingListRefusal) -> [BindingID: BindingGroupID] {
        let sorted = groups.sorted { $0.id.rawValue.bytesPrecede($1.id.rawValue) }
        for (previous, current) in zip(sorted, sorted.dropFirst())
        where previous.id.rawValue.sameBytes(current.id.rawValue) {
            throw .duplicateGroup(current.id)
        }
        for group in sorted {
            for member in group.members where book.state(of: member) == nil {
                throw .unknownGroupMember(group: group.id, member: member)
            }
        }
        var owners: [BindingID: BindingGroupID] = [:]
        for group in sorted {
            for member in group.members {
                guard owners[member] == nil else { throw .bindingInSeveralGroups(member) }
                owners[member] = group.id
            }
        }
        return owners
    }

    private static func control(
        of source: ControlSourceID, labels: [ControlSourceID: String]
    ) throws(PerformBindingListRefusal) -> String {
        guard let label = labels[source] else { return source.rawValue }
        let bytes = label.utf8.count
        guard controlLabelBytes.contains(bytes) else { throw .invalidControlLabel(source, bytes: bytes) }
        return label
    }
}

private extension String {
    func bytesPrecede(_ other: String) -> Bool {
        utf8.lexicographicallyPrecedes(other.utf8)
    }

    func sameBytes(_ other: String) -> Bool {
        utf8.elementsEqual(other.utf8)
    }
}
