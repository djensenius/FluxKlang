//
//  RigSelection.swift
//  FluxKlang
//
//  Chooses among several saved rigs by how they match the observed devices.
//  A rig is eligible only when its mode is `full`. Several eligible rigs are
//  an ambiguity, never resolved by name, recency or position. Nothing here
//  activates a rig, a route or a tone.
//

/// Which saved rig the observed devices select.
enum RigChoice: Hashable, Sendable {
    /// Exactly one rig is `full`.
    case selected(RigProfileID)
    /// Two or more rigs are `full`; the ids are sorted and none is picked.
    case ambiguous([RigProfileID])
    /// No rig is `full` (or there are no rigs): use manual/remote control or review the partial reports.
    case none
}

/// The choice and every rig's report, sorted by rig id.
struct RigSelectionResult: Hashable, Sendable {
    let choice: RigChoice
    private(set) var reports: [RigMatchReport]

    fileprivate init(choice: RigChoice, reports: [RigMatchReport]) {
        self.choice = choice
        self.reports = reports
    }
}

enum RigSelection {
    /// Refuses, in this order: `tooManyRigs`, `tooManyObserved`, `duplicateObservedDevice`, `duplicateRig`, then
    /// each rig in ascending id order (`RigSavedRig.validate`). Empty lists are legal.
    static func choose(rigs: [RigSavedRig], observed: [DeviceDescriptor]) throws(RigIdentityRefusal)
        -> RigSelectionResult {
        guard rigs.count <= RigIdentityLimits.rigs else {
            throw .tooManyRigs(count: rigs.count, maximum: RigIdentityLimits.rigs)
        }
        let index = try RigObservedIndex.make(observed)
        let sorted = rigs.sorted { $0.id < $1.id }
        for (earlier, later) in zip(sorted, sorted.dropFirst()) where earlier.id == later.id {
            throw .duplicateRig(earlier.id)
        }
        for rig in sorted { try rig.validate() }
        let reports = sorted.map { RigIdentityMatcher.report(for: $0, index: index) }
        let full = reports.filter { $0.mode == .full }.map(\.rig)
        guard let first = full.first else { return RigSelectionResult(choice: .none, reports: reports) }
        let choice: RigChoice = full.count == 1 ? .selected(first) : .ambiguous(full)
        return RigSelectionResult(choice: choice, reports: reports)
    }
}
