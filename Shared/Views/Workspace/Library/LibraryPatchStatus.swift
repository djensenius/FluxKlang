//
//  LibraryPatchStatus.swift
//  FluxKlang
//
//  Whether a patch's variations can be listed (#99 LIB2). Decided only by `PatchVariationExtension.content(of:)`:
//  an absent key or a valid current set is `ready`; a set from a newer version is `newerVersion` and anything the
//  reader throws is `unreadable`, carrying the typed error. Nothing calls it yet.
//

enum LibraryPatchStatus: Hashable, Sendable {
    case ready
    case newerVersion(Int)
    case unreadable(PatchVariationError)

    /// Why variations are not listed and Recall is disabled; nil for a ready patch.
    var reasonText: String? {
        switch self {
        case .ready: nil
        case .newerVersion: LibraryPatchText.newerVersionReason
        case .unreadable: LibraryPatchText.unreadableReason
        }
    }
}
