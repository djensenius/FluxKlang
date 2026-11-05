//
//  ShowRefusal.swift
//  FluxKlang
//
//  Typed refusals of the show model and navigation cursor (#106 SH1).
//  A refused call changes nothing.
//

enum ShowRefusal: Error, Hashable, Sendable {
    case invalidTitle
    case tooManySongs(Int)
    case tooManyParts(SongID, Int)
    case tooManySetlists(Int)
    case tooManyEntries(SetlistID, Int)
    case duplicateSong(SongID)
    case duplicatePart(SongID, SongPartID)
    case duplicateSetlist(SetlistID)
    /// Entry IDs are unique across every setlist, so one entry ID names one cursor target.
    case duplicateEntry(SetlistEntryID)
    case unknownSong(SongID)
    case unknownPart(SongPartID)
    case unknownSetlist(SetlistID)
    case unknownEntry(SetlistEntryID)
    /// The first referencing entry in setlist order.
    case songInUse(SongID, SetlistEntryID)
    case markOutOfRange(Int64)
    /// Rehearsal marks must not decrease in part order; names the first part out of order.
    case marksOutOfOrder(SongPartID)
    case invalidChartPage(Int)
    case variationWithoutPatch(PatchVariationID)
    case unknownPatch(PatchID)
    case unknownVariation(PatchID, PatchVariationID)
    case unknownActionSet(ActionSetID)
    case chartUnavailable(ChartReference, ChartMissingReason)
    case duplicatePatch(PatchID)
    case duplicateVariation(PatchID, PatchVariationID)
    case duplicateAsset(AssetID)
    case catalogTooLarge(ShowCatalogBound, Int)
    case bounceOutOfRange(UInt64)
    /// A cursor accepts 1...`ShowLimits.maximumInputSources` distinct sources.
    case inputSourceCountOutOfRange(Int)
    case duplicateInputSource(ShowInputSourceID)
    case unknownInputSource(ShowInputSourceID)
    case atEnd
    case atStart
    case emptySetlist(SetlistID)
    /// A relative command cannot move from a position that no longer exists; only `jump` recovers.
    case cursorTargetRemoved(ShowCursorStatus)
    case positionMismatch(expected: ShowPosition, actual: ShowPosition?)
    case staleSequence(last: UInt64, received: UInt64)
    case ticksWentBackwards(last: UInt64, received: UInt64)
}

/// Which catalog bound `catalogTooLarge` names.
enum ShowCatalogBound: Hashable, Sendable {
    case patches
    case assets
    case availableContent
    case variationsPerPatch(PatchID)
}
