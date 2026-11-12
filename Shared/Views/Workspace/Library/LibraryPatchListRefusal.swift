//
//  LibraryPatchListRefusal.swift
//  FluxKlang
//
//  Why `LibraryPatchList.make` refuses its input (#99 LIB2). A project document already refuses duplicate patch
//  IDs, so this only guards a caller that passes patches from elsewhere. Used by `LibrarySectionView`.
//

enum LibraryPatchListRefusal: Error, Hashable, Sendable {
    /// The first patch, in input order, whose id repeats an earlier one.
    case duplicatePatch(PatchID)
}
