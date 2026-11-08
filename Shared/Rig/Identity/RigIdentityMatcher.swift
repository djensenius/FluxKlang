//
//  RigIdentityMatcher.swift
//  FluxKlang
//
//  Matches a saved rig's expected devices against the observed descriptors by
//  UID and derives the operating mode. The report carries identities only: it
//  holds no route, no tone and no capability grant, and mode never activates
//  anything. No clock, no CoreAudio, no persistence.
//

/// What became of one saved device.
enum RigMatchOutcome: Hashable, Sendable {
    /// Exactly one present descriptor has the UID, under the saved `DeviceID`.
    case matched(DeviceID)
    /// Exactly one present descriptor has the UID, under another `DeviceID`. Reported, never silently adopted.
    case renumbered(from: DeviceID, to: DeviceID)
    /// Two or more present descriptors share the UID; the ids are sorted and none is picked.
    case ambiguous([DeviceID])
    /// The UID is only on descriptors that are not present.
    case absentPresence(RigAbsentPresence)
    /// No observed descriptor has the UID.
    case missing

    var isMatched: Bool {
        switch self {
        case .matched, .renumbered: true
        case .ambiguous, .absentPresence, .missing: false
        }
    }
}

/// Why a UID that was seen is not usable: `missing` outranks `stale` when both kinds carry the UID.
enum RigAbsentPresence: Hashable, Sendable {
    case missing, stale
}

/// How much of the rig is usable.
enum RigOperatingMode: Hashable, Sendable {
    /// Every required device is matched (also a rig with no required device).
    case full
    /// Some, not all, required devices are matched; the payload lists the saved ids of the others, sorted.
    case partial(missing: [DeviceID])
    /// No required device is matched: the operator uses manual or remote control.
    case manualRemote
}

/// One saved device and its outcome.
struct RigDeviceMatch: Hashable, Sendable {
    let saved: RigSavedDevice
    let outcome: RigMatchOutcome

    fileprivate init(saved: RigSavedDevice, outcome: RigMatchOutcome) {
        self.saved = saved
        self.outcome = outcome
    }
}

/// The result of matching one rig. Rows are sorted by the saved raw `DeviceID`.
struct RigMatchReport: Hashable, Sendable {
    let rig: RigProfileID
    private(set) var rows: [RigDeviceMatch]
    let mode: RigOperatingMode

    fileprivate init(rig: RigProfileID, rows: [RigDeviceMatch], mode: RigOperatingMode) {
        self.rig = rig
        self.rows = rows
        self.mode = mode
    }
}

/// The observed descriptors indexed by UID. Built only by `make`, which refuses an oversized or repeating list.
struct RigObservedIndex: Sendable {
    fileprivate struct Entry: Sendable {
        let id: DeviceID
        let presence: DevicePresence
    }

    fileprivate let entries: [RigUID: [Entry]]

    /// Refuses more than `RigIdentityLimits.observed` descriptors (`tooManyObserved`), then a repeated
    /// `DeviceID` (`duplicateObservedDevice`, the smallest). An empty list is legal.
    static func make(_ observed: [DeviceDescriptor]) throws(RigIdentityRefusal) -> RigObservedIndex {
        guard observed.count <= RigIdentityLimits.observed else {
            throw .tooManyObserved(count: observed.count, maximum: RigIdentityLimits.observed)
        }
        let ids = observed.map(\.id).sorted()
        for (earlier, later) in zip(ids, ids.dropFirst()) where earlier == later {
            throw .duplicateObservedDevice(earlier)
        }
        var entries: [RigUID: [Entry]] = [:]
        // The evidence test only accepts: a descriptor without UID evidence cannot be built, so no input rejects.
        for descriptor in observed where !descriptor.identity.evidence.isDisjoint(with: [.deviceUID, .endpointUID]) {
            entries[RigUID(descriptor.identity.uid), default: []]
                .append(Entry(id: descriptor.id, presence: descriptor.presence))
        }
        return RigObservedIndex(entries: entries)
    }
}

enum RigIdentityMatcher {
    /// Matches `rig` against `observed`. Refuses, in this order: the observed list (`tooManyObserved`,
    /// `duplicateObservedDevice`), then the rig (`RigSavedRig.validate`, which also covers hand-built rigs).
    static func match(rig: RigSavedRig, observed: [DeviceDescriptor]) throws(RigIdentityRefusal) -> RigMatchReport {
        let index = try RigObservedIndex.make(observed)
        try rig.validate()
        return report(for: rig, index: index)
    }

    /// The report for a rig that is already validated. Rows and every id list are sorted by raw id.
    static func report(for rig: RigSavedRig, index: RigObservedIndex) -> RigMatchReport {
        let rows = rig.devices.sorted { $0.id < $1.id }.map { RigDeviceMatch(saved: $0, outcome: outcome($0, index)) }
        return RigMatchReport(rig: rig.id, rows: rows, mode: mode(of: rows))
    }

    private static func outcome(_ saved: RigSavedDevice, _ index: RigObservedIndex) -> RigMatchOutcome {
        let entries = index.entries[RigUID(saved.uid)] ?? []
        let present = entries.filter { $0.presence == .present }.map(\.id).sorted()
        if present.count >= 2 { return .ambiguous(present) }
        if let only = present.first { return only == saved.id ? .matched(only) : .renumbered(from: saved.id, to: only) }
        if entries.contains(where: { absence(of: $0.presence) == .missing }) { return .absentPresence(.missing) }
        if entries.contains(where: { absence(of: $0.presence) == .stale }) { return .absentPresence(.stale) }
        return .missing
    }

    private static func absence(of presence: DevicePresence) -> RigAbsentPresence? {
        switch presence {
        case .present: nil
        case .missing: .missing
        case .stale: .stale
        }
    }

    private static func mode(of rows: [RigDeviceMatch]) -> RigOperatingMode {
        let required = rows.filter(\.saved.required)
        guard !required.isEmpty else { return .full }
        let unmatched = required.filter { !$0.outcome.isMatched }.map(\.saved.id)
        if unmatched.count == required.count { return .manualRemote }
        return unmatched.isEmpty ? .full : .partial(missing: unmatched)
    }
}
