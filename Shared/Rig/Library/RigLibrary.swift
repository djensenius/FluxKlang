//
//  RigLibrary.swift
//  FluxKlang
//
//  The user's set of named saved rigs and an optional explicit selection, as
//  a pure value. Nothing here reads a device, a route or a file, and nothing
//  activates a rig: `selected` records a choice the user made and is never
//  inferred from observed devices (`RigSelection.choose` decides what matches).
//

/// At most `RigIdentityLimits.rigs` named rigs, ordered by rig id (UTF-8 bytes), and the selected rig id.
/// The only constructors are `make` and `empty`, so a library that exists has passed `make`.
struct RigLibrary: Hashable, Sendable {
    let entries: [RigLibraryEntry]
    /// The rig the user chose, or nil. It is always the id of one of `entries`.
    let selected: RigProfileID?

    fileprivate init(entries: [RigLibraryEntry], selected: RigProfileID?) {
        self.entries = entries
        self.selected = selected
    }

    static let empty = RigLibrary(entries: [], selected: nil)

    /// Refuses, in this order, each step over the whole input: more than `RigIdentityLimits.rigs` entries
    /// (`.rig(.tooManyRigs)`, on the count alone), a repeated rig id (`.rig(.duplicateRig)`, the smallest), each
    /// entry in ascending id order (its name rule, then its rig's `validate`), a repeated name
    /// (`duplicateName`, the later holder in ascending id order), a selection that names no entry
    /// (`unknownSelection`). Empty entries with no selection are legal.
    static func make(entries: [RigLibraryEntry],
                     selected: RigProfileID?) throws(RigLibraryRefusal) -> RigLibrary {
        try checkCount(entries)
        let sorted = entries.sorted { $0.id.rawValue.utf8.lexicographicallyPrecedes($1.id.rawValue.utf8) }
        try checkIDs(sorted)
        try checkEntries(sorted)
        try checkNames(sorted)
        try checkSelection(selected, in: sorted)
        return RigLibrary(entries: sorted, selected: selected)
    }

    /// The rigs, in id order, ready for `RigSelection.choose`. The library holds at most
    /// `RigIdentityLimits.rigs` of them, so `choose` cannot refuse their count.
    var savedRigs: [RigSavedRig] { entries.map(\.rig) }

    /// The entry with this rig id, if any.
    func entry(for id: RigProfileID) -> RigLibraryEntry? {
        entries.first { $0.id == id }
    }

    private static func checkCount(_ entries: [RigLibraryEntry]) throws(RigLibraryRefusal) {
        guard entries.count <= RigIdentityLimits.rigs else {
            throw .rig(.tooManyRigs(count: entries.count, maximum: RigIdentityLimits.rigs))
        }
    }

    private static func checkIDs(_ sorted: [RigLibraryEntry]) throws(RigLibraryRefusal) {
        for (earlier, later) in zip(sorted, sorted.dropFirst()) where earlier.id == later.id {
            throw .rig(.duplicateRig(earlier.id))
        }
    }

    private static func checkEntries(_ sorted: [RigLibraryEntry]) throws(RigLibraryRefusal) {
        for entry in sorted {
            try RigLibraryEntry.checkName(entry.name.text)
            try RigLibraryRefusal.wrapping { () throws(RigIdentityRefusal) in try entry.rig.validate() }
        }
    }

    private static func checkNames(_ sorted: [RigLibraryEntry]) throws(RigLibraryRefusal) {
        var holders: [RigUID: RigProfileID] = [:]
        for entry in sorted {
            if holders[entry.name] != nil { throw .duplicateName(entry.id) }
            holders[entry.name] = entry.id
        }
    }

    private static func checkSelection(_ selected: RigProfileID?,
                                       in sorted: [RigLibraryEntry]) throws(RigLibraryRefusal) {
        guard let selected else { return }
        let ids = Set(sorted.map(\.id))
        guard ids.contains(selected) else { throw .unknownSelection(selected) }
    }
}
