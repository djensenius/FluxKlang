//
//  RigLibraryRefusal.swift
//  FluxKlang
//
//  Why a rig library, or an edit of one, is refused, and whether an accepted
//  edit changed anything. A refusal leaves the input library untouched: every
//  edit takes the library by value and returns a new one.
//

/// Why a rig library or an edit of it is refused.
enum RigLibraryRefusal: Error, Hashable, Sendable {
    /// A rig, an observed list or a rig count is refused by the identity layer; its refusal is reused as is.
    case rig(RigIdentityRefusal)
    /// A rig name is longer than `RigLibraryEntry.nameBytes` UTF-8 bytes; the payload is its byte count.
    case nameTooLong(Int)
    /// A rig name is empty or only whitespace.
    case blankName
    /// The name is already held by another rig; the payload is the rig that holds it (for a whole library, the
    /// later of the two holders in ascending id order).
    case duplicateName(RigProfileID)
    /// No rig of that id is in the library.
    case unknownRig(RigProfileID)
    /// The rig has no device of that id.
    case unknownDevice(rig: RigProfileID, device: DeviceID)
    /// The selected id is not the id of a rig in the library.
    case unknownSelection(RigProfileID)

    /// Runs an identity-layer step and wraps its refusal as `.rig`.
    static func wrapping<Value>(_ body: () throws(RigIdentityRefusal) -> Value) throws(Self) -> Value {
        do throws(RigIdentityRefusal) {
            return try body()
        } catch {
            throw .rig(error)
        }
    }
}

/// Whether an accepted edit changed the library.
enum RigLibraryChange: Hashable, Sendable {
    case changed
    case unchanged
}
