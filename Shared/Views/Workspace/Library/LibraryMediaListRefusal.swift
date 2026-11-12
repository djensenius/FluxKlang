//
//  LibraryMediaListRefusal.swift
//  FluxKlang
//
//  Why `LibraryMediaList.make` refuses its input (#99 LIB4). A project document already refuses duplicate asset
//  IDs, so this only guards a caller that passes assets from elsewhere. Nothing calls it yet.
//

enum LibraryMediaListRefusal: Error, Hashable, Sendable {
    /// The first asset, in input order, whose id repeats an earlier one.
    case duplicateAsset(AssetID)
}
