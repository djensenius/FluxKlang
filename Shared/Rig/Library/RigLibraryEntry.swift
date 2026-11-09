//
//  RigLibraryEntry.swift
//  FluxKlang
//
//  One named rig in the library. The name is the user's label, kept verbatim
//  (no trimming, no case folding, no normalisation) and compared only by
//  unicode scalars. The rig id, not the name, is the identity.
//

import Foundation

/// A named saved rig. The memberwise initializer builds an entry without validation, as `RigSavedRig` does;
/// `RigLibrary.make` re-validates every entry it is given.
struct RigLibraryEntry: Hashable, Sendable {
    /// Compared and hashed by unicode scalars. `RigUID` is the repository's scalar-compare string key; here it
    /// keys a rig name, not a device UID.
    let name: RigUID
    let rig: RigSavedRig

    var id: RigProfileID { rig.id }

    /// A rig name is at most this many UTF-8 bytes (the longest a `RigProfileID` may be).
    static let nameBytes = RigProfileID.maximumLength

    /// Refuses, in this order: a name over `nameBytes` UTF-8 bytes (`nameTooLong`), a blank name (`blankName`),
    /// then the rig (`RigSavedRig.validate`, wrapped as `.rig`).
    static func make(name: String, rig: RigSavedRig) throws(RigLibraryRefusal) -> RigLibraryEntry {
        try checkName(name)
        try RigLibraryRefusal.wrapping { () throws(RigIdentityRefusal) in try rig.validate() }
        return RigLibraryEntry(name: RigUID(name), rig: rig)
    }

    /// The name rule alone. The byte count is checked first, which bounds the whitespace scan.
    static func checkName(_ name: String) throws(RigLibraryRefusal) {
        let bytes = name.utf8.count
        guard bytes <= nameBytes else { throw .nameTooLong(bytes) }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw .blankName }
    }
}
